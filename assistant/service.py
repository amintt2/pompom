"""Service local Pompom : champ focus (UI Automation) + suggestions de collage + decisions typees.

  python service.py --port 47821 --token SECRET [--gpu|--cpu] [--base multilingual|english] [--mode hybrid|heads] [--parent-pid PID]

API (127.0.0.1 uniquement ; en-tete X-Pompom-Token obligatoire sauf /health) :
  GET  /health                      -> {ok, heads: loading|ready|off|error, backend: directml|cpu, model, mode, focus}
  GET  /focus?after=SEQ&wait=S      -> champ focus courant (attend jusqu'a S s qu'il change apres SEQ)
  POST /suggest {candidates:[...], field?:{...}}  -> {kind, index, confidence, label_fr, ...}
       (sans "field" : utilise le champ focus courant)
  POST /decide {question, options:[...], context?}  -> {answer, confidence, probs, ms}  (choix zero-shot Laya)
  POST /embed {screen?, text?, field?}  -> embeddings L2 (ecran SigLIP / texte Laya) + model_id, dim
       (boucle de retour sur donnees reelles : voir pompom_assist/feedback.py)
  GET  /vision                      -> {enabled, ready, probs:{game,video,work_code,work_docs,browse,chat,other},
                                        top, video_rect:[x,y,w,h]|null, fullscreen, is_watching_video, ts, ...}
  POST /vision/enable {on: bool}    -> active / coupe la vision (opt-in ; captures en memoire uniquement)
  POST /vision/pause {paused: bool} -> pause totale demandee par le jeu (jeu competitif / plein ecran)
  POST /vision/frame                -> une analyse immediate, meme en pause
  (pause automatique, sans capture ni calcul, quand une appli plein ecran autre qu'un navigateur ou un
   lecteur video a le focus)
  POST /shutdown

Decisions : stuntd (encodeur Laya fige + tetes de classification entrainees hors ligne), aucun LLM.
Hors ligne : tout est lu dans models/ (ONNX). PyTorch n est PAS necessaire (seulement dans dev/ pour entrainer).

Vie privee : aucune connexion sortante, aucun fichier ecrit (sauf --log, qui ne contient jamais de texte
copie), le contenu des champs n'est jamais lu, les champs mot de passe sont ignores.
"""

from __future__ import annotations

import argparse
import ctypes
import hmac
import json
import os

os.environ.setdefault("HF_HUB_OFFLINE", "1")  # jamais de reseau : tout est local
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from pompom_assist.decider import Decider  # noqa: E402
from pompom_assist.heads import OnnxHeads, env_threads  # noqa: E402

MAX_BODY = 256 * 1024
MAX_CANDIDATES = 8
MAX_CANDIDATE_CHARS = 4000


class State:
    def __init__(self, args) -> None:
        self.args = args
        self.decider = Decider(None, mode=args.mode)
        self.decider.on_use = self.use_heads
        self.last_use = time.time()
        self.heads_state = "off"
        self.backend = ""
        self.watcher = None
        self.vision = None  # VisionWatcher, seulement quand le reglage "vision" est actif
        self.vision_lock = threading.Lock()
        self.focus_cond = threading.Condition()
        self.started = time.time()
        self.log_file = open(args.log, "a", encoding="utf-8") if args.log else None

    def log(self, msg: str) -> None:
        if self.log_file:
            self.log_file.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
            self.log_file.flush()

    # ------------------------------------------------------------------ modele (stuntd)
    def start_heads(self) -> None:
        """Charge les tetes en arriere-plan (le service repond deja avec les regles pendant ce temps)."""
        if self.args.no_model or self.heads_state in ("loading", "ready"):
            return
        self.heads_state = "loading"
        threading.Thread(target=self._boot, name="heads-boot", daemon=True).start()

    def _boot(self) -> None:
        # Texte : toujours sur CPU. Mesure : DirectML etait plus lent (formes variables -> recompilation)
        # et moins precis (fp16) pour cet encodeur ; la carte graphique est gardee pour la vision.
        t0 = time.time()
        try:
            heads = OnnxHeads(gpu=False, threads=self.args.threads)
            heads.warm()
        except Exception as exc:  # noqa: BLE001
            self.log(f"heads load failed: {exc!r}")
            self.heads_state = "error"
            return
        self.decider.heads = heads
        self.backend = heads.backend
        self.last_use = time.time()
        self.heads_state = "ready"
        self.log(f"heads ready backend={heads.backend} in {time.time() - t0:.2f}s")

    def use_heads(self) -> None:
        """Appele par le Decider a chaque fois qu'il voudrait une tete : recharge si besoin."""
        self.last_use = time.time()
        if self.heads_state in ("off", "unloaded"):
            self.start_heads()

    def _idle_loop(self) -> None:
        # libere ~0,7 Go de RAM quand personne n'a eu besoin du modele depuis un moment
        while True:
            time.sleep(10)
            if (self.args.idle_unload > 0 and self.heads_state == "ready"
                    and time.time() - self.last_use > self.args.idle_unload):
                self.decider.heads = None
                self.heads_state = "unloaded"
                import gc

                gc.collect()
                self.log("heads unloaded (idle)")

    # ------------------------------------------------------------------ focus
    def start_focus(self) -> None:
        if self.args.no_focus or os.name != "nt":
            return
        from pompom_assist.focus_probe import FocusWatcher

        w = FocusWatcher(interval=self.args.focus_interval)
        if self.args.parent_pid:
            w.ignore_pids.add(self.args.parent_pid)  # les fenetres du jeu lui-meme
        orig_run_seq = [0]

        def notifier() -> None:
            while True:
                time.sleep(0.05)
                if w.seq != orig_run_seq[0]:
                    orig_run_seq[0] = w.seq
                    with self.focus_cond:
                        self.focus_cond.notify_all()

        w.start()
        threading.Thread(target=notifier, name="focus-notify", daemon=True).start()
        self.watcher = w

    def focus(self) -> dict:
        return self.watcher.get() if self.watcher else {"seq": 0, "skip": "disabled"}

    def wait_focus(self, after: int, wait: float) -> dict:
        end = time.time() + wait
        with self.focus_cond:
            while True:
                cur = self.focus()
                if cur.get("seq", 0) != after or time.time() >= end:
                    return cur
                self.focus_cond.wait(max(0.01, end - time.time()))

    # ------------------------------------------------------------------ vision (opt-in)
    def set_vision(self, on: bool) -> dict:
        with self.vision_lock:
            if on and self.vision is None:
                from pompom_assist.vision import SiglipEyes, VisionWatcher

                own = {os.getpid()} | ({self.args.parent_pid} if self.args.parent_pid else set())
                gpu, threads = self.args.gpu, self.args.vision_threads
                self.vision = VisionWatcher(lambda: SiglipEyes(gpu=gpu, threads=threads),
                                            motion_interval=self.args.motion_interval,
                                            classify_interval=self.args.vision_interval, own_pids=own)
                self.vision.start()
                self.log("vision on")
            elif not on and self.vision is not None:
                self.vision.stop()
                self.vision = None  # captures et vignettes liberees avec le thread
                self.log("vision off")
        return self.vision_state()

    def vision_state(self) -> dict:
        v = self.vision
        if v is None:
            return {"enabled": False, "ready": False, "probs": {}, "top": "", "video_rect": None,
                    "fullscreen": False, "ts": 0.0}
        st = v.get()
        st.update({"enabled": True, "backend": v.stats.get("backend", ""), "error": v.stats.get("error", "")})
        return st

    def shutdown(self) -> None:
        self.set_vision(False)
        if self.watcher:
            self.watcher.stop()


def make_handler(state: State, token: str, port: int):
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        server_version = "pompom-assist"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args) -> None:  # pas de journal des requetes
            pass

        def _send(self, code: int, obj) -> None:
            data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("content-type", "application/json; charset=utf-8")
            self.send_header("content-length", str(len(data)))
            self.send_header("cache-control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _guard(self, need_token: bool = True) -> bool:
            # anti "DNS rebinding" + pages web : hote local exact, pas d'en-tete Origin, jeton secret
            if self.headers.get("host", "") not in allowed_hosts or self.headers.get("origin"):
                self._send(403, {"error": "forbidden"})
                return False
            if need_token and not hmac.compare_digest(self.headers.get("x-pompom-token", ""), token):
                self._send(401, {"error": "token"})
                return False
            return True

        def _body(self) -> dict | None:
            n = int(self.headers.get("content-length") or 0)
            if n > MAX_BODY:
                self._send(413, {"error": "too_large"})
                return None
            try:
                obj = json.loads(self.rfile.read(n) or b"{}")
            except (ValueError, UnicodeDecodeError):
                self._send(400, {"error": "json"})
                return None
            if not isinstance(obj, dict):
                self._send(400, {"error": "json"})
                return None
            return obj

        def do_GET(self) -> None:  # noqa: N802
            u = urlparse(self.path)
            if u.path == "/health":
                if not self._guard(need_token=False):
                    return
                self._send(200, {"ok": True, "heads": state.heads_state, "backend": state.backend,
                                 "model": "stuntd-heads/laya-multilingual (onnx)", "mode": state.args.mode, "focus": state.watcher is not None,
                                 "uptime": round(time.time() - state.started, 2)})
                return
            if not self._guard():
                return
            if u.path == "/vision":
                self._send(200, state.vision_state())
                return
            if u.path == "/focus":
                q = parse_qs(u.query)
                after = int(q.get("after", ["-1"])[0] or -1)
                wait = min(20.0, float(q.get("wait", ["0"])[0] or 0))
                self._send(200, state.wait_focus(after, wait) if wait > 0 else state.focus())
                return
            self._send(404, {"error": "not_found"})

        def do_POST(self) -> None:  # noqa: N802
            if not self._guard():
                return
            u = urlparse(self.path)
            if u.path == "/shutdown":
                self._send(200, {"ok": True})
                threading.Thread(target=lambda: (state.shutdown(), os._exit(0)), daemon=True).start()
                return
            body = self._body()
            if body is None:
                return
            if u.path == "/vision/enable":
                self._send(200, state.set_vision(bool(body.get("on", True))))
                return
            if u.path == "/vision/pause":  # le jeu sait qu'un jeu competitif / plein ecran a le focus
                v = state.vision
                if v is not None:
                    v.paused_by_client = bool(body.get("paused", True))
                self._send(200, state.vision_state())
                return
            if u.path == "/vision/frame":  # une analyse immediate, meme en pause (integration de jeu)
                v = state.vision
                if v is not None:
                    v.request_frame()
                self._send(200, {"ok": v is not None})
                return
            if u.path == "/suggest":
                cands = [str(c)[:MAX_CANDIDATE_CHARS] for c in (body.get("candidates") or [])][:MAX_CANDIDATES]
                field = body.get("field")
                if not isinstance(field, dict):
                    field = state.focus()
                t0 = time.perf_counter()
                s = state.decider.suggest(field, cands).to_dict()
                s["seq"] = field.get("seq", 0)
                s["total_ms"] = round((time.perf_counter() - t0) * 1000, 2)
                s["heads"] = state.heads_state
                state.log(f"suggest kind={s['kind']} idx={s['index']} conf={s['confidence']} "
                          f"src={s['kind_source']}/{s['pick_source']} ms={s['total_ms']}")
                self._send(200, s)
                return
            if u.path == "/decide":
                opts = [str(o) for o in (body.get("options") or [])][:64]
                if len(opts) < 2 or not body.get("question"):
                    self._send(400, {"error": "need question + >=2 options"})
                    return
                state.use_heads()
                t_wait = time.time()
                while state.decider.heads is None and state.heads_state == "loading" and time.time() - t_wait < 15:
                    time.sleep(0.05)
                try:
                    c = state.decider.choose(str(body["question"]), opts, str(body.get("context", "")))
                except RuntimeError as exc:
                    self._send(503, {"error": str(exc), "heads": state.heads_state})
                    return
                except Exception as exc:  # noqa: BLE001
                    self._send(500, {"error": repr(exc)[:200]})
                    return
                self._send(200, {"answer": c.label, "confidence": round(c.confidence, 3),
                                 "probs": {k: round(v, 3) for k, v in c.probs.items()}, "ms": round(c.ms, 2)})
                return
            if u.path == "/embed":
                from pompom_assist.feedback import handle_embed

                self._send(*handle_embed(state, body))
                return
            self._send(404, {"error": "not_found"})

    return Handler


def watch_parent(pid: int, state: State) -> None:
    """Quitte si le jeu disparait (meme tue brutalement)."""
    if os.name != "nt" or pid <= 0:
        return
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = ctypes.c_void_p
    h = k32.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
    if not h:
        state.shutdown()
        os._exit(0)

    def run() -> None:
        k32.WaitForSingleObject(ctypes.c_void_p(h), 0xFFFFFFFF)
        state.log("parent gone, exiting")
        state.shutdown()
        os._exit(0)

    threading.Thread(target=run, name="parent-watch", daemon=True).start()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=47821)
    ap.add_argument("--token", default=os.environ.get("POMPOM_ASSIST_TOKEN", ""))
    ap.add_argument("--gpu", dest="gpu", action="store_true", default=True)
    ap.add_argument("--cpu", dest="gpu", action="store_false")
    ap.add_argument("--base", "--model", dest="base", default="multilingual",
                    help="(compatibilite) seul le checkpoint Laya multilingual est livre")
    ap.add_argument("--idle-unload", type=float, default=300.0,
                    help="s sans besoin du modele de texte avant de le decharger (0 = jamais)")
    ap.add_argument("--mode", default="hybrid", choices=["hybrid", "heads"])
    ap.add_argument("--threads", type=int, default=env_threads())
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--no-model", action="store_true")
    ap.add_argument("--no-focus", action="store_true")
    ap.add_argument("--vision", action="store_true", help="active la vision des le demarrage")
    ap.add_argument("--vision-interval", type=float, default=3.0, help="s entre deux passages de l'encodeur")
    ap.add_argument("--motion-interval", type=float, default=1.0, help="s entre deux captures (carte de mouvement)")
    ap.add_argument("--vision-threads", type=int, default=2)
    ap.add_argument("--focus-interval", type=float, default=0.25)
    ap.add_argument("--log", default="")
    args = ap.parse_args()
    if not args.token:
        print("--token requis", file=sys.stderr)
        sys.exit(2)
    state = State(args)
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(state, args.token, args.port))
    httpd.daemon_threads = True
    watch_parent(args.parent_pid, state)
    # sous Windows, .venvScriptspython(w).exe est un lanceur qui demarre le vrai Python en processus enfant :
    # si le jeu tue le lanceur (OS.kill), on doit partir aussi.
    watch_parent(os.getppid(), state)
    state.start_focus()
    state.start_heads()
    threading.Thread(target=state._idle_loop, name="idle", daemon=True).start()
    if args.vision:
        state.set_vision(True)
    state.log(f"listening 127.0.0.1:{args.port} base={args.base} mode={args.mode} gpu={args.gpu}")
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        state.shutdown()


if __name__ == "__main__":
    main()
