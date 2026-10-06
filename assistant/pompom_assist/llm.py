"""llama-server local : lancement (Vulkan ou CPU), arret garanti, et decisions typees contraintes.

- Le serveur ecoute UNIQUEMENT sur 127.0.0.1, 3 petits slots (un par type de question, pour garder chaque
  prefixe de prompt en cache ; les requetes sont serialisees : jamais de decodage parallele), contexte court, pas d'interface web,
  pas de cache de prompts en RAM (-cram 0), --poll 0 (pas d'attente active du CPU au repos).
- Il est attache a un Job Object Windows "kill on close" : si le service meurt (meme tue brutalement),
  Windows tue aussi llama-server. Pas de processus orphelin qui garderait le GPU.
- Les decisions passent par une grammaire GBNF : la reponse est TOUJOURS une des etiquettes permises
  (1 a 3 tokens), et la confiance vient des logprobs du premier token.
"""

from __future__ import annotations

import ctypes
import json
import math
import os
import secrets
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from ctypes import wintypes
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LLAMA_DIR = ROOT / "llama"
MODELS_DIR = ROOT / "models"
DEFAULT_MODEL = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"  # meilleur sur le jeu de test ; alternative legere : qwen2.5-0.5b-instruct-q4_k_m.gguf


# --------------------------------------------------------------------------- Job Object (Windows)
class _JobLimits(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
        ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
        ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD),
    ]


class _IoCounters(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint64) for n in ("r", "w", "o", "rb", "wb", "ob")]


class _JobExtLimits(ctypes.Structure):
    _fields_ = [
        ("Basic", _JobLimits), ("Io", _IoCounters), ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


_job_handle = None


def _kill_on_close_job():
    """Job Object partage : tout processus ajoute meurt quand ce service se termine."""
    global _job_handle
    if _job_handle is not None or os.name != "nt":
        return _job_handle
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    h = k32.CreateJobObjectW(None, None)
    if not h:
        return None
    info = _JobExtLimits()
    info.Basic.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    if not k32.SetInformationJobObject(h, 9, ctypes.byref(info), ctypes.sizeof(info)):
        return None
    _job_handle = h
    return h


def _attach(proc: subprocess.Popen) -> bool:
    h = _kill_on_close_job()
    if not h:
        return False
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    return bool(k32.AssignProcessToJobObject(h, int(proc._handle)))  # type: ignore[attr-defined]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# --------------------------------------------------------------------------- serveur
@dataclass
class ServerConfig:
    model: str = DEFAULT_MODEL
    gpu: bool = True
    ctx: int = 1024  # par slot
    slots: int = 3  # 1 slot par sorte de question (kind / pick / generique) : chaque prefixe reste en cache.
    threads: int = 4
    gpu_layers: int = 99  # petit modele : tout tient en VRAM (~0,5 Go)
    batch: int = 64  # petits lots : nos requetes ajoutent ~40 tokens ; divise les tampons (logits 128k x lot)
    port: int = 0
    log_path: str = ""  # "" = rien (vie privee)
    extra: list[str] = field(default_factory=list)


class LlamaServer:
    """Processus llama-server garde charge. start() ne bloque pas ; ready() dit s'il repond."""

    def __init__(self, cfg: ServerConfig) -> None:
        self.cfg = cfg
        self.proc: subprocess.Popen | None = None
        self.port = cfg.port or free_port()
        self.backend = ""
        self.started_at = 0.0
        self.ready_at = 0.0
        self.error = ""
        self._log = None
        # cle aleatoire : sans elle, n'importe quelle page web pourrait interroger le serveur local (CORS *)
        self.api_key = secrets.token_hex(16)

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def exe(self, gpu: bool) -> Path:
        return LLAMA_DIR / ("vulkan" if gpu else "cpu") / "llama-server.exe"

    def start(self) -> bool:
        model = Path(self.cfg.model)
        if not model.is_absolute():
            model = MODELS_DIR / model
        if not model.exists():
            self.error = f"modele absent : {model.name}"
            return False
        gpu = self.cfg.gpu and self.exe(True).exists()
        exe = self.exe(gpu)
        if not exe.exists():
            self.error = "llama-server absent (lancer setup.ps1)"
            return False
        args = [
            str(exe), "-m", str(model), "--host", "127.0.0.1", "--port", str(self.port),
            "-c", str(self.cfg.ctx * self.cfg.slots), "-np", str(self.cfg.slots), "-sps", "0", "-t", str(self.cfg.threads), "-tb", str(self.cfg.threads),
            "--no-webui", "-cram", "0", "--poll", "0", "--fit", "off", "-b", str(self.cfg.batch), "-ub", str(self.cfg.batch),
        ]
        # pas de mmap : sinon le fichier mappe s ajoute a la RAM (GPU 1,2 -> 0,47 Go ; CPU 1,4 -> 0,94 Go)
        args += ["-lm", "none"]
        args += ["-ngl", str(self.cfg.gpu_layers)] if gpu else ["-ngl", "0", "-dev", "none"]
        args += self.cfg.extra
        self.backend = "vulkan" if gpu else "cpu"
        out = subprocess.DEVNULL
        if self.cfg.log_path:
            self._log = open(self.cfg.log_path, "ab")
            out = self._log
        flags = 0x08000000 if os.name == "nt" else 0  # CREATE_NO_WINDOW
        env = dict(os.environ)
        env.pop("LLAMA_ARG_HOST", None)
        env["LLAMA_API_KEY"] = self.api_key  # par l'environnement : invisible dans la ligne de commande
        try:
            self.proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                                         creationflags=flags, cwd=str(exe.parent), env=env)
        except OSError as exc:
            self.error = str(exc)
            return False
        _attach(self.proc)
        self.started_at = time.time()
        return True

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def ready(self) -> bool:
        if self.ready_at:
            return self.alive()
        if not self.alive():
            return False
        try:
            with urllib.request.urlopen(self.base + "/health", timeout=0.5) as r:
                ok = r.status == 200 and b"ok" in r.read()
        except (urllib.error.URLError, OSError, ValueError):
            return False
        if ok:
            self.ready_at = time.time()
        return ok

    def wait_ready(self, timeout: float = 30.0) -> bool:
        end = time.time() + timeout
        while time.time() < end:
            if self.ready():
                return True
            if not self.alive():
                self.error = self.error or f"llama-server s'est arrete (code {self.proc.poll() if self.proc else '?'})"
                return False
            time.sleep(0.05)
        return False

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None
        self.ready_at = 0.0
        if self._log:
            self._log.close()
            self._log = None


# --------------------------------------------------------------------------- decisions typees
def gbnf_choice(options: list[str]) -> str:
    alts = " | ".join(json.dumps(o) for o in options)
    return f"root ::= {alts}"


@dataclass
class Choice:
    answer: str
    confidence: float  # proba (renormalisee sur les options) de la reponse choisie
    probs: dict[str, float]
    latency_ms: float
    prompt_ms: float = 0.0
    cached_tokens: int = 0


class LlamaClient:
    """Pose une question fermee au llama-server : reponse = une des options, toujours parseable."""

    def __init__(self, base: str, timeout: float = 5.0, api_key: str = "") -> None:
        self.base = base
        self.api_key = api_key
        self.timeout = timeout
        self._lock = threading.Lock()  # un seul slot : on serialise

    def _post(self, body: dict) -> dict:
        req = urllib.request.Request(self.base + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"content-type": "application/json",
                                              "authorization": f"Bearer {self.api_key}"})
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            return json.loads(r.read())

    def choose(self, system: str, user: str, options: list[str], examples: list[tuple[str, str]] | None = None,
               slot: int = -1) -> Choice:
        """Un seul pas de decodage : la grammaire ne laisse passer que les debuts d'options, et les
        probabilites APRES grammaire (post_sampling_probs) donnent la masse de chaque option.
        Reponse = option la plus probable (deterministe), confiance = sa masse."""
        msgs = [{"role": "system", "content": system}]
        for q, a in examples or []:
            msgs += [{"role": "user", "content": q}, {"role": "assistant", "content": a}]
        msgs.append({"role": "user", "content": user})
        body = {
            "messages": msgs,
            "grammar": gbnf_choice(options),
            # temperature 1 / top_k 0 : la distribution n'est pas tronquee, on lit ses probabilites ;
            # le token tire n'est pas utilise (on prend l'argmax par option).
            "temperature": 1.0, "top_k": 0, "top_p": 1.0, "min_p": 0.0, "seed": 0,
            "max_tokens": 1,
            "logprobs": True, "top_logprobs": 20, "n_probs": 20, "post_sampling_probs": True,
            "cache_prompt": True,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        if slot >= 0:
            body["id_slot"] = slot
        t0 = time.perf_counter()
        with self._lock:
            res = self._post(body)
            probs = _option_mass(res, options)
            ranked = sorted(probs.items(), key=lambda kv: -kv[1])
            answer = ranked[0][0] if ranked else ""
            if not ranked or (len(ranked) > 1 and abs(ranked[0][1] - ranked[1][1]) < 1e-4):
                # debut commun a plusieurs options : on laisse le modele finir (glouton, contraint)
                body.update({"temperature": 0.0, "max_tokens": 8, "logprobs": False})
                for k in ("top_logprobs", "n_probs", "post_sampling_probs"):
                    body.pop(k, None)
                res2 = self._post(body)
                text = (res2["choices"][0]["message"].get("content") or "").strip()
                answer = text if text in options else (ranked[0][0] if ranked else options[-1])
        ms = (time.perf_counter() - t0) * 1000.0
        t = res.get("timings", {})
        return Choice(answer, probs.get(answer, 0.0), probs, ms, float(t.get("prompt_ms", 0.0)),
                      int(t.get("cache_n", 0)))


def _option_mass(res: dict, options: list[str]) -> dict[str, float]:
    """Masse de probabilite de chaque option au 1er token (apres grammaire). Un token commun a
    plusieurs options (ex. "n" pour name/number) est partage a parts egales."""
    try:
        first = res["choices"][0]["logprobs"]["content"][0]
        tops = first.get("top_probs") or first.get("top_logprobs") or []
    except (KeyError, IndexError, TypeError):
        return {}
    mass: dict[str, float] = {}
    for tl in tops:
        tok = tl.get("token", "")
        if not tok:
            continue
        p = float(tl["prob"]) if "prob" in tl else math.exp(float(tl.get("logprob", -50.0)))
        hits = [o for o in options if o.startswith(tok)]
        for o in hits:
            mass[o] = mass.get(o, 0.0) + p / len(hits)
    total = sum(mass.values())
    return {o: v / total for o, v in mass.items()} if total > 0 else {}
