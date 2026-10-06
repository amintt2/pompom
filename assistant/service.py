"""Service local Pompom : champ focus (UI Automation) + suggestions de collage + decisions typees.

  python service.py --port 47821 --token SECRET [--gpu|--cpu] [--model FICHIER.gguf] [--parent-pid PID]

API (127.0.0.1 uniquement ; en-tete X-Pompom-Token obligatoire sauf /health) :
  GET  /health                      -> {ok, llm: loading|ready|off|error, backend, model, focus}
  GET  /focus?after=SEQ&wait=S      -> champ focus courant (attend jusqu'a S s qu'il change apres SEQ)
  POST /suggest {candidates:[...], field?:{...}}  -> {kind, index, confidence, label_fr, ...}
       (sans "field" : utilise le champ focus courant)
  POST /decide {question, options:[...], context?, system?}  -> {answer, confidence, probs, ms}
  POST /shutdown

Vie privee : aucune connexion sortante, aucun fichier ecrit (sauf --log, qui ne contient jamais de texte
copie), le contenu des champs n'est jamais lu, les champs mot de passe sont ignores.
"""

from __future__ import annotations

import argparse
import ctypes
import hmac
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from pompom_assist.decider import Decider  # noqa: E402
from pompom_assist.llm import DEFAULT_MODEL, LlamaClient, LlamaServer, ServerConfig  # noqa: E402

MAX_BODY = 256 * 1024
MAX_CANDIDATES = 8
MAX_CANDIDATE_CHARS = 4000


class State:
    def __init__(self, args) -> None:
        self.args = args
        self.decider = Decider(None)
        self.server: LlamaServer | None = None
        self.llm_state = "off"
        self.backend = ""
        self.watcher = None
        self.focus_cond = threading.Condition()
        self.started = time.time()
        self.log_file = open(args.log, "a", encoding="utf-8") if args.log else None

    def log(self, msg: str) -> None:
        if self.log_file:
            self.log_file.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
            self.log_file.flush()

    # ------------------------------------------------------------------ modele
    def start_llm(self) -> None:
        if self.args.no_llm:
            return
        threading.Thread(target=self._llm_boot, name="llm-boot", daemon=True).start()

    def _llm_boot(self) -> None:
        self.llm_state = "loading"
        order = [True, False] if self.args.gpu else [False]
        for gpu in order:
            cfg = ServerConfig(model=self.args.model, gpu=gpu, threads=self.args.threads,
                               log_path=self.args.llama_log)
            srv = LlamaServer(cfg)
            t0 = time.time()
            if srv.start() and srv.wait_ready(90):
                client = LlamaClient(srv.base, timeout=self.args.llm_timeout, api_key=srv.api_key)
                try:  # chauffe : met les prefixes des prompts en cache
                    self.decider.llm = client
                    self.decider.suggest({"name": "Rechercher", "process": "chrome.exe", "window_title": "Accueil",
                                          "control_type": "edit"},
                                         ["14 rue des Lilas, 69003 Lyon", "idées cadeau"])
                    self.decider.field_kind({"name": "?", "process": "x.exe", "control_type": "edit"})
                except Exception as exc:  # noqa: BLE001
                    self.log(f"warmup error {exc!r}")
                self.server = srv
                self.backend = srv.backend
                self.llm_state = "ready"
                self.log(f"llm ready backend={srv.backend} in {time.time() - t0:.2f}s")
                return
            self.log(f"llm start failed gpu={gpu}: {srv.error}")
            srv.stop()
            self.decider.llm = None
        self.llm_state = "error"

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

    def shutdown(self) -> None:
        if self.watcher:
            self.watcher.stop()
        if self.server:
            self.server.stop()


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
                self._send(200, {"ok": True, "llm": state.llm_state, "backend": state.backend,
                                 "model": state.args.model, "focus": state.watcher is not None,
                                 "uptime": round(time.time() - state.started, 2)})
                return
            if not self._guard():
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
            if u.path == "/suggest":
                cands = [str(c)[:MAX_CANDIDATE_CHARS] for c in (body.get("candidates") or [])][:MAX_CANDIDATES]
                field = body.get("field")
                if not isinstance(field, dict):
                    field = state.focus()
                t0 = time.perf_counter()
                s = state.decider.suggest(field, cands).to_dict()
                s["seq"] = field.get("seq", 0)
                s["total_ms"] = round((time.perf_counter() - t0) * 1000, 2)
                s["llm"] = state.llm_state
                state.log(f"suggest kind={s['kind']} idx={s['index']} conf={s['confidence']} "
                          f"src={s['kind_source']}/{s['pick_source']} ms={s['total_ms']}")
                self._send(200, s)
                return
            if u.path == "/decide":
                opts = [str(o) for o in (body.get("options") or [])][:64]
                if len(opts) < 2 or not body.get("question"):
                    self._send(400, {"error": "need question + >=2 options"})
                    return
                try:
                    c = state.decider.choose(str(body["question"]), opts, str(body.get("context", "")),
                                             str(body.get("system", "")))
                except RuntimeError as exc:
                    self._send(503, {"error": str(exc), "llm": state.llm_state})
                    return
                except Exception as exc:  # noqa: BLE001
                    self._send(500, {"error": repr(exc)[:200]})
                    return
                self._send(200, {"answer": c.answer, "confidence": round(c.confidence, 3),
                                 "probs": {k: round(v, 3) for k, v in c.probs.items()}, "ms": round(c.latency_ms, 2)})
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
    ap.add_argument("--model", default=os.environ.get("POMPOM_ASSIST_MODEL", DEFAULT_MODEL))
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--no-llm", action="store_true")
    ap.add_argument("--no-focus", action="store_true")
    ap.add_argument("--focus-interval", type=float, default=0.25)
    ap.add_argument("--llm-timeout", type=float, default=3.0)
    ap.add_argument("--log", default="")
    ap.add_argument("--llama-log", default="")
    args = ap.parse_args()
    if not args.token:
        print("--token requis", file=sys.stderr)
        sys.exit(2)
    state = State(args)
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(state, args.token, args.port))
    httpd.daemon_threads = True
    watch_parent(args.parent_pid, state)
    state.start_focus()
    state.start_llm()
    state.log(f"listening 127.0.0.1:{args.port} model={args.model} gpu={args.gpu}")
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        state.shutdown()


if __name__ == "__main__":
    main()
