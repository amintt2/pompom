"""Les Â« yeux Â» de Pompom : que fait l'utilisateur, et ou est la video a l'ecran ?

- Encodeur d'images : SigLIP base patch16-224 (google/siglip-base-patch16-224, Apache-2.0), en ONNX
  (export Xenova), execute par ONNX Runtime : DirectML (carte graphique) ou CPU.
- Activite = choix zero-shot parmi game / video / work_code / work_docs / browse / chat / other : on compare
  l'image d'ecran a des phrases d'exemple (plusieurs par classe), softmax des similarites, lissage dans le
  temps (moyenne mobile exponentielle), puis un leger a priori tire du nom de l'appli au premier plan.
- Video : carte de mouvement (differences d'images 96x54 sur les dernieres captures), plus grande zone qui
  bouge en continu, confirmee par l'encodeur (Â« image de video Â» contre Â« capture d'interface Â»).
- Vie privee : captures en memoire seulement (jamais ecrites, jamais envoyees), seulement quand le reglage
  `vision` est actif ; on ne garde que quelques vignettes 96x54 en niveaux de gris et la derniere capture.

(nnlgsakib/laya-vision a ete essaye d'abord : 99,9 % de ses poids publies sont NaN -> inutilisable.)
"""

from __future__ import annotations

import ctypes
import math
import os
import string
import threading
import time
from collections import deque
from ctypes import wintypes
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SIGLIP_DIR = ROOT / "dev" / "siglip"  # developpement seulement (export) ; le service lit models/

ACTIVITIES: dict[str, list[str]] = {
    "game": ["a screenshot of a video game", "a 3d video game being played on a computer",
             "a video game with a character and a health bar", "gameplay of a pc game with a game hud"],
    "video": ["a frame of a movie", "a video playing in a video player", "a scene from a tv show",
              "a youtube video playing in a web browser", "a photo of a real scene with people or animals",
              "a nature documentary"],
    "work_code": ["a screenshot of a code editor with source code", "programming code in visual studio code",
                  "a terminal window with command line text"],
    "work_docs": ["a screenshot of a text document in a word processor", "a spreadsheet with rows and columns",
                  "a slide presentation being edited"],
    "browse": ["a screenshot of a website in a web browser", "a news website with articles and pictures",
               "an online shopping website"],
    "chat": ["a screenshot of a chat application with messages", "a messaging app conversation",
             "an email inbox"],
    "other": ["a computer desktop with icons and wallpaper", "a file explorer window with folders",
              "a settings window"],
}
VIDEO_PROMPTS = ["a frame of a movie", "a scene from a tv show", "a video game scene", "a photo of people",
                 "a frame of an animated cartoon", "a nature video"]
UI_PROMPTS = ["a screenshot of a website", "a screenshot of text", "a screenshot of a user interface with buttons",
              "a code editor", "a spreadsheet", "a chat conversation"]

# a priori faible a partir du processus au premier plan (complete l'image, ne la remplace pas)
PROC_PRIOR = {
    "work_code": ("code.exe", "devenv.exe", "pycharm", "idea64", "notepad++", "sublime_text", "cursor.exe",
                  "windowsterminal", "godot", "rider64", "clion64"),
    "work_docs": ("winword", "excel", "powerpnt", "onenote", "acrobat", "libreoffice", "soffice", "notepad.exe"),
    "chat": ("discord", "slack", "teams", "whatsapp", "telegram", "signal", "outlook", "thunderbird"),
    "video": ("vlc", "mpc-hc", "mpv", "potplayer", "netflix", "wmplayer", "video.ui"),
    "game": ("steam", "epicgames", "riotclient", "battle.net", "minecraft", "javaw.exe", "unitycrashhandler"),
    "browse": ("chrome", "msedge", "firefox", "opera", "brave", "vivaldi"),
}
BROWSERS = PROC_PRIOR["browse"]

MOTION_W, MOTION_H = 96, 54
# SigLIP zero-shot est tres tranche (logit_scale 117) ; T=2 adoucit. Non calibre sur de vraies captures.
ACT_TEMPERATURE = 2.0
VISION_PRECISION = "int8"  # format livre de la tour de vision (voir export_onnx.py / README)


# --------------------------------------------------------------------------- encodeur
def _canon(text: str) -> str:
    t = text.lower().translate(str.maketrans("", "", string.punctuation))
    return " ".join(t.split())


class SiglipEyes:
    """Encodeur d'images SigLIP en ONNX. Les phrases des classes sont deja encodees (models/siglip_prompts.npz,
    fait par export_onnx.py) : le modele de texte n'est pas livre. Sans models/, retombe sur siglip/ (dev)."""

    def __init__(self, gpu: bool = False, threads: int = 2, precision: str = "", use_head: bool = False) -> None:
        import json

        from .laya_onnx import MODELS, find, session

        t0 = time.perf_counter()
        # tete d'activite entrainee (train_gemma_heads.py --vision --encoder siglip), seulement si demandee
        self.activity_head = self.activity_head_fg = None
        if use_head and (MODELS / "siglip_vision_heads.npz").exists():
            from .np_heads import load_heads

            hs = load_heads(MODELS / "siglip_vision_heads.npz")
            self.activity_head = hs.get("activity:full")
            self.activity_head_fg = hs.get("activity:full+fg")
        self._dev = not (MODELS / "siglip_prompts.npz").exists()
        if self._dev:
            path = SIGLIP_DIR / "onnx" / "vision_model_fp16.onnx"
            logit = SIGLIP_DIR / "logit_params.json"
        else:
            path = find("siglip_vision", MODELS, precision or VISION_PRECISION)
            logit = MODELS / "siglip_logit.json"
        self.vision, self.backend = session(path, gpu, threads)
        self.path = path
        self._vis_in = self.vision.get_inputs()[0]
        self._fp16 = "float16" in self._vis_in.type
        with open(logit, encoding="utf-8") as f:
            p = json.load(f)
        self.logit_scale = math.exp(p["logit_scale"][0])
        self.logit_bias = p["logit_bias"][0]
        self._cache: dict[str, np.ndarray] = {}
        if not self._dev:
            z = np.load(MODELS / "siglip_prompts.npz")
            self._cache = {str(t): e for t, e in zip(z["texts"], z["emb"])}
        self._text = None
        self._threads = threads
        self.load_s = time.perf_counter() - t0

    def embed_texts(self, texts: list[str]) -> np.ndarray:
        todo = [t for t in texts if t not in self._cache]
        if todo:  # dev seulement : il faut le modele de texte SigLIP
            import onnxruntime as ort
            from tokenizers import Tokenizer

            if self._text is None:
                self._text = ort.InferenceSession(str(SIGLIP_DIR / "onnx" / "text_model.onnx"),
                                                  providers=["CPUExecutionProvider"])
                self._tok = Tokenizer.from_file(str(SIGLIP_DIR / "tokenizer.json"))
            ids = np.ones((len(todo), 64), dtype=np.int64)  # </s> sert de remplissage (SigLIP)
            for i, t in enumerate(todo):
                e = self._tok.encode(_canon(t)).ids[:64]
                ids[i, : len(e)] = e
            out = self._text.run(["pooler_output"], {"input_ids": ids})[0]
            out = out / np.linalg.norm(out, axis=1, keepdims=True)
            for t, v in zip(todo, out):
                self._cache[t] = v
        return np.stack([self._cache[t] for t in texts])

    def release_text_model(self) -> None:
        self._text = None

    def embed_images(self, images: list) -> np.ndarray:
        from PIL import Image

        arr = np.stack([
            ((np.asarray(im.convert("RGB").resize((224, 224), Image.BICUBIC), dtype=np.float32) / 255.0 - 0.5) / 0.5)
            .transpose(2, 0, 1) for im in images])
        if self._fp16:
            arr = arr.astype(np.float16)
        out = self.vision.run(["pooler_output"], {self._vis_in.name: arr})[0].astype(np.float32)
        return out / np.linalg.norm(out, axis=1, keepdims=True)

    def class_probs(self, img_emb: np.ndarray, classes: dict[str, list[str]], temperature: float = 1.0) -> dict[str, float]:
        """Softmax sur les classes de logit_scale * cos(image, moyenne des phrases de la classe)."""
        names = list(classes)
        cent = []
        for n in names:
            e = self.embed_texts(classes[n]).mean(0)
            cent.append(e / np.linalg.norm(e))
        logits = self.logit_scale * (np.stack(cent) @ img_emb) / temperature
        logits -= logits.max()
        p = np.exp(logits)
        p /= p.sum()
        return {n: float(v) for n, v in zip(names, p)}


# --------------------------------------------------------------------------- ecran / fenetres
class _RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long), ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


def foreground_info(own_pids: set[int]) -> dict:
    """Rectangle et processus de la fenetre au premier plan (rien d'autre)."""
    if os.name != "nt":
        return {}
    u = ctypes.windll.user32
    u.GetForegroundWindow.restype = wintypes.HWND
    h = u.GetForegroundWindow()
    if not h:
        return {}
    r = _RECT()
    u.GetWindowRect(h, ctypes.byref(r))
    pid = wintypes.DWORD()
    u.GetWindowThreadProcessId(h, ctypes.byref(pid))
    from .focus_probe import process_name

    return {"rect": [r.left, r.top, r.right - r.left, r.bottom - r.top], "process": process_name(pid.value),
            "own": pid.value in own_pids}


def _largest_component(mask: np.ndarray) -> tuple[int, int, int, int, int] | None:
    """(x0, y0, x1, y1, cellules) de la plus grande zone connexe (4-voisins) d'un petit masque."""
    h, w = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    best = None
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or seen[y, x]:
                continue
            stack = [(y, x)]
            seen[y, x] = True
            n, x0, y0, x1, y1 = 0, x, y, x, y
            while stack:
                cy, cx = stack.pop()
                n += 1
                x0, x1, y0, y1 = min(x0, cx), max(x1, cx), min(y0, cy), max(y1, cy)
                for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
            if best is None or n > best[4]:
                best = (x0, y0, x1 + 1, y1 + 1, n)
    return best


def motion_region(frames: list[np.ndarray], diff_thr: float = 10.0, min_hits: int | None = None) -> tuple | None:
    """Zone qui change dans (presque) toutes les dernieres paires d'images 96x54 (niveaux de gris).
    Renvoie (x0, y0, x1, y1, part_de_l_ecran, densite) en cellules, ou None."""
    if len(frames) < 3:
        return None
    diffs = [np.abs(frames[i + 1] - frames[i]) > diff_thr for i in range(len(frames) - 1)]
    hits = np.sum(diffs, axis=0)
    need = min_hits if min_hits is not None else max(2, len(diffs) - 1)
    mask = hits >= need
    # on bouche les petits trous (une video a des zones fixes : bandes noires, decor)
    m2 = mask.copy()
    m2[1:-1, 1:-1] |= (mask[:-2, 1:-1] & mask[2:, 1:-1]) | (mask[1:-1, :-2] & mask[1:-1, 2:])
    comp = _largest_component(m2)
    if comp is None:
        return None
    x0, y0, x1, y1, n = comp
    area = (x1 - x0) * (y1 - y0)
    if n < 12 or area < 0.012 * MOTION_W * MOTION_H:
        return None
    return x0, y0, x1, y1, area / (MOTION_W * MOTION_H), n / max(1, area)


# --------------------------------------------------------------------------- boucle de vision
class VisionWatcher(threading.Thread):
    """Capture l'ecran principal (en memoire), estime l'activite et la zone video. start()/stop()."""

    def __init__(self, eyes_factory, motion_interval: float = 1.0, classify_interval: float = 3.0,
                 ema: float = 0.35, own_pids: set[int] | None = None) -> None:
        super().__init__(name="vision", daemon=True)
        self._factory = eyes_factory
        self.eyes: SiglipEyes | None = None
        self.motion_interval = motion_interval
        self.classify_interval = classify_interval
        self.ema = ema
        self.own_pids = own_pids or set()
        self._stop = threading.Event()
        self.lock = threading.Lock()
        self.state: dict = {"probs": {}, "top": "", "video_rect": None, "fullscreen": False, "ts": 0.0,
                            "ready": False}
        self.stats = {"grab_ms": 0.0, "encode_ms": 0.0, "classify_count": 0, "backend": "", "error": ""}
        self._frames: deque = deque(maxlen=5)
        self._smooth: dict[str, float] = {}
        self._video_smooth = 0.0
        self._frame_req = threading.Event()
        self.paused_by_client = False

    def stop(self) -> None:
        self._stop.set()

    def get(self) -> dict:
        with self.lock:
            return dict(self.state)

    def run(self) -> None:
        try:
            import mss
            from PIL import Image

            self.eyes = self._factory()
            self.stats["backend"] = self.eyes.backend
            # phrases encodees une fois, puis le modele de texte est libere
            self.eyes.class_probs(np.zeros(768, np.float32) + 1e-3, ACTIVITIES)
            self.eyes.embed_texts(VIDEO_PROMPTS + UI_PROMPTS)
            self.eyes.release_text_model()
        except Exception as exc:  # noqa: BLE001
            self.stats["error"] = repr(exc)[:200]
            return
        with mss.mss() as sct:
            mon = sct.monitors[1]  # ecran principal
            last_cls = 0.0
            while not self._stop.is_set():
                t0 = time.perf_counter()
                forced = self._frame_req.is_set()
                reason = "" if forced else self._pause_reason(mon)
                if reason:
                    # PAUSE TOTALE : ni capture ni encodeur (jeu en plein ecran / competitif, ou demande du jeu)
                    self._frames.clear()
                    self._set_paused(reason, mon)
                    self._stop.wait(self.motion_interval)
                    continue
                self._frame_req.clear()
                try:
                    shot = sct.grab(mon)
                    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
                except Exception as exc:  # noqa: BLE001
                    self.stats["error"] = repr(exc)[:200]
                    self._stop.wait(self.motion_interval)
                    continue
                small = np.asarray(img.convert("L").resize((MOTION_W, MOTION_H), Image.BILINEAR), dtype=np.float32)
                self._frames.append(small)
                self.stats["grab_ms"] = (time.perf_counter() - t0) * 1000
                if forced or time.monotonic() - last_cls >= self.classify_interval:
                    last_cls = time.monotonic()
                    try:
                        self._classify(img, mon)
                    except Exception as exc:  # noqa: BLE001
                        self.stats["error"] = repr(exc)[:200]
                del img, shot
                self._stop.wait(max(0.05, self.motion_interval - (time.perf_counter() - t0)))

    # ------------------------------------------------------------------ pause
    def request_frame(self) -> None:
        """Une analyse tout de suite, meme en pause (pour une integration de jeu qui le demande)."""
        self._frame_req.set()

    def _fullscreen(self, fg: dict, mon: dict) -> bool:
        fr = fg.get("rect") or [0, 0, 0, 0]
        return (not fg.get("own") and fr[0] <= mon["left"] and fr[1] <= mon["top"]
                and fr[0] + fr[2] >= mon["left"] + mon["width"] and fr[1] + fr[3] >= mon["top"] + mon["height"])

    def _pause_reason(self, mon: dict) -> str:
        if self.paused_by_client:
            return "client"
        fg = foreground_info(self.own_pids)
        if not self._fullscreen(fg, mon):
            return ""
        proc = str(fg.get("process", "")).lower()
        # plein ecran d'un navigateur ou d'un lecteur video : on continue (video plein ecran)
        if any(n in proc for n in BROWSERS + PROC_PRIOR["video"]):
            return ""
        return "fullscreen_app"  # tres probablement un jeu : on ne regarde pas, on ne consomme rien

    def _set_paused(self, reason: str, mon: dict) -> None:
        with self.lock:
            if self.state.get("paused") == reason:
                return
            game = reason == "fullscreen_app"
            probs = {k: (0.85 if k == "game" else 0.15 / (len(ACTIVITIES) - 1)) for k in ACTIVITIES} if game                 else dict(self.state.get("probs") or {})
            self.state = {
                "probs": probs, "top": "game" if game else self.state.get("top", ""),
                "video_rect": None, "motion_rect": None, "fullscreen": game, "paused": reason,
                "is_watching_video": 0.0, "is_fullscreen_game": 0.85 if game else 0.0,
                "screen": [mon["left"], mon["top"], mon["width"], mon["height"]], "source": "foreground",
                "ts": time.time(), "ready": True, "ms": 0.0,
            }
        self._smooth = {}

    def _classify(self, img, mon: dict) -> None:
        eyes = self.eyes
        t0 = time.perf_counter()
        sw, sh = mon["width"], mon["height"]
        fg = foreground_info(self.own_pids)
        crops = [img]
        reg = motion_region(list(self._frames))
        rect = None
        motion_rect = None
        if reg is not None:
            x0, y0, x1, y1, share, _dens = reg
            sx, sy = sw / MOTION_W, sh / MOTION_H
            rect = [int(x0 * sx), int(y0 * sy), int((x1 - x0) * sx), int((y1 - y0) * sy)]
            motion_rect = list(rect)
            if share < 0.97:
                crops.append(img.crop((rect[0], rect[1], rect[0] + rect[2], rect[1] + rect[3])))
        motion_idx = 1 if len(crops) > 1 else 0
        # strategie « plein ecran + fenetre au premier plan » (eval_v2 : meilleure precision par ms), seulement
        # avec une tete entrainee pour elle et une fenetre qui ne couvre pas deja l'ecran
        head = getattr(eyes, "activity_head", None)
        head_fg = getattr(eyes, "activity_head_fg", None)
        fg_idx = None
        if head_fg is not None and not fg.get("own"):
            fr = fg.get("rect") or [0, 0, 0, 0]
            fx0, fy0 = max(0, fr[0] - mon["left"]), max(0, fr[1] - mon["top"])
            fx1, fy1 = min(sw, fr[0] - mon["left"] + fr[2]), min(sh, fr[1] - mon["top"] + fr[3])
            if fx1 - fx0 > 64 and fy1 - fy0 > 64 and (fx1 - fx0) * (fy1 - fy0) < 0.9 * sw * sh:
                fg_idx = len(crops)
                crops.append(img.crop((fx0, fy0, fx1, fy1)))
        emb = eyes.embed_images(crops)
        self.stats["encode_ms"] = (time.perf_counter() - t0) * 1000
        if head_fg is not None:
            x = emb[0] if fg_idx is None else emb[0] + emb[fg_idx]
            hp = head_fg.probs(x / np.linalg.norm(x))
            probs = {k: float(hp[head_fg.labels.index(k)]) for k in ACTIVITIES}
        elif head is not None:  # tete entrainee sur des ecrans (eval_v2 : bien meilleure que le zero-shot)
            hp = head.probs(emb[0])
            probs = {k: float(hp[head.labels.index(k)]) for k in ACTIVITIES}
        else:
            probs = eyes.class_probs(emb[0], ACTIVITIES, temperature=ACT_TEMPERATURE)
        # a priori de l'appli au premier plan (30 %), sauf si c'est le jeu lui-meme
        proc = str(fg.get("process", "")).lower()
        if proc and not fg.get("own"):
            prior = {k: 1.0 for k in probs}
            for k, names in PROC_PRIOR.items():
                if any(n in proc for n in names):
                    prior[k] = 3.0
            z = sum(probs[k] ** 0.7 * prior[k] ** 0.3 for k in probs)
            probs = {k: probs[k] ** 0.7 * prior[k] ** 0.3 / z for k in probs}
        fullscreen = self._fullscreen(fg, mon)
        if not fullscreen and not any(n in proc for n in PROC_PRIOR["game"]):
            # un jeu est presque toujours en plein ecran ou lance par un lanceur connu : sinon, on se mefie
            # (le zero-shot confond facilement les interfaces sombres avec des jeux)
            probs["game"] *= 0.3
            z = sum(probs.values())
            probs = {k: v / z for k, v in probs.items()}
        video_like = None
        if rect is not None:
            e = emb[motion_idx]
            pv = eyes.class_probs(e, {"video": VIDEO_PROMPTS, "ui": UI_PROMPTS})
            video_like = pv["video"]
            if video_like < 0.5:
                rect = None
            else:
                # une zone qui bouge en continu ET ressemble a une image filmee : indice fort de video
                boost = {k: (1.0 + 3.0 * video_like if k == "video" else 1.0) for k in probs}
                z = sum(probs[k] * boost[k] for k in probs)
                probs = {k: probs[k] * boost[k] / z for k in probs}
        # plein ecran : fenetre au premier plan qui couvre tout l'ecran principal
        if fullscreen and reg is not None and reg[4] > 0.6:
            rect = [0, 0, sw, sh]
        a = self.ema if self._smooth else 1.0
        self._smooth = {k: a * v + (1 - a) * self._smooth.get(k, v) for k, v in probs.items()}
        z = sum(self._smooth.values())
        sm = {k: round(v / z, 4) for k, v in self._smooth.items()}
        top = max(sm, key=sm.get)
        with self.lock:
            self.state = {
                "probs": sm, "top": top,
                "video_rect": rect, "fullscreen": bool(fullscreen),
                "motion_rect": motion_rect, "video_score": None if video_like is None else round(float(video_like), 4),
                "is_watching_video": round(float(sm.get("video", 0.0) if rect is None else max(sm.get("video", 0.0), video_like or 0.0)), 4),
                "is_fullscreen_game": round(float(sm.get("game", 0.0)) if fullscreen else 0.0, 4),
                "foreground": proc, "screen": [mon["left"], mon["top"], sw, sh],
                "ts": time.time(), "ready": True, "ms": round(self.stats["encode_ms"], 1), "paused": "",
                "source": "screen",
            }
        self.stats["classify_count"] += 1
