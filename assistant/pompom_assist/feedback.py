"""Boucle de retour sur donnees reelles : embeddings des exemples corriges par l'utilisateur.

Quand le compagnon se trompe (il regarde une « video » alors que tu ecoutes de la musique, il n'a pas fete
ton but...), le jeu enregistre un exemple corrige (godot/scripts/feedback/). Pour pouvoir re-entrainer nos
petites tetes sans jamais garder ni envoyer d'image, on calcule ICI, en local, l'embedding de l'ecran
(encodeur SigLIP actuel) ou de la description du champ (encodeur Laya actuel), normalise L2.

  POST /embed {screen?: bool = true, text?: str, field?: {...}}
    -> {ok, screen: {b64, dtype, dim, model_id, model_version} | null,
            text:   {b64, dtype, dim, model_id, model_version} | null,
            model_id, dim, ms, errors: {...}}

- b64 = octets float32 petit-boutiste (numpy '<f4') en base64 ; vecteur de norme 1.
- Les embeddings dependent du modele : chaque vecteur porte model_id + model_version (empreinte du fichier
  ONNX). Un exemple n'est utilisable qu'avec l'encodeur qui l'a produit.
- La capture d'ecran reste en memoire le temps du calcul (jamais ecrite, jamais envoyee).
- Champ : on encode une description SANS le titre de la fenetre (field_text) ; jamais le contenu du champ,
  jamais un champ mot de passe.
- Cout : l'encodeur d'images de la vision est reutilise s'il tourne ; sinon un encodeur SigLIP sur CPU
  (2 fils) est charge a la demande et libere apres `idle_unload` s d'inactivite.

Vocabulaire des etiquettes : TASKS ci-dessous. Il est recopie dans godot/scripts/feedback/feedback_store.gd
et server/feedback/app.py (tests/test_feedback.py verifie qu'ils restent identiques).
"""

from __future__ import annotations

import base64
import hashlib
import threading
import time
from pathlib import Path

import numpy as np

from . import rules

# --------------------------------------------------------------------------- vocabulaire
ACTIVITY_LABELS = ("video", "music", "game", "code", "ai", "email", "docs", "spreadsheet", "chat", "social",
                   "reading", "design", "browse", "meeting", "other")
GAME_EVENT_LABELS = ("goal", "goal_against", "kill", "death", "round_won", "round_lost", "match_won", "match_lost",
                     "none")
FIELD_KIND_LABELS = tuple(rules.FIELD_KINDS)
TASKS: dict[str, tuple[str, ...]] = {
    "activity": ACTIVITY_LABELS,
    "game_event": GAME_EVENT_LABELS,
    "field_kind": FIELD_KIND_LABELS,
}
# classes grossieres de la vision actuelle (vision.ACTIVITIES) : pour comparer aux tetes actuelles
ACTIVITY_TO_VISION = {
    "video": "video", "music": "other", "game": "game", "code": "work_code", "ai": "work_code", "email": "chat",
    "docs": "work_docs", "spreadsheet": "work_docs", "chat": "chat", "social": "browse", "reading": "browse",
    "design": "other", "browse": "browse", "meeting": "chat", "other": "other",
}
# gestionnaires de mots de passe / ecrans de connexion Windows : jamais de capture
PRIVATE_PROCS = ("bitwarden", "1password", "keepass", "dashlane", "lastpass", "enpass", "nordpass", "proton pass",
                 "credentialuibroker", "consent.exe", "logonui", "veracrypt", "authy", "winauth")


# --------------------------------------------------------------------------- vecteurs
def l2(v) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32).reshape(-1)
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def pack(v, model_id: str, model_version: str) -> dict:
    v = l2(v).astype("<f4")
    return {"b64": base64.b64encode(v.tobytes()).decode("ascii"), "dtype": "float32", "dim": int(v.size),
            "model_id": model_id, "model_version": model_version}


def unpack(d: dict) -> np.ndarray:
    """Inverse de pack() ; accepte aussi dtype float16 (format envoye au serveur)."""
    raw = base64.b64decode(d.get("b64") or d.get("emb") or "")
    dt = "<f2" if str(d.get("dtype", "float32")) == "float16" else "<f4"
    return np.frombuffer(raw, dtype=dt).astype(np.float32)


_TAGS: dict[str, str] = {}


def file_tag(path: Path | str) -> str:
    """Empreinte courte et bon marche d'un fichier de modele : sha256(taille + premier Mo)."""
    p = Path(path)
    key = str(p)
    if key not in _TAGS:
        h = hashlib.sha256()
        try:
            h.update(str(p.stat().st_size).encode())
            with open(p, "rb") as f:
                h.update(f.read(1 << 20))
        except OSError:
            h.update(key.encode())
        _TAGS[key] = h.hexdigest()[:12]
    return _TAGS[key]


def _precision(path: Path | str) -> str:
    parts = Path(path).name.split(".")
    return parts[-2] if len(parts) >= 3 else "fp32"


def screen_model_id(path: Path | str) -> str:
    return "siglip-b16-224." + _precision(path)


def text_model_id(path: Path | str) -> str:
    return "laya-multi-meanpool." + _precision(path)


# --------------------------------------------------------------------------- textes
def field_text(field: dict) -> str:
    """Description d'un champ pour l'embedding partageable : comme heads.describe_field, SANS le titre de la
    fenetre (il peut contenir un nom, un sujet de mail...). Jamais le contenu du champ."""
    parts = [f"app: {str(field.get('process', '') or '').lower()}", f"control: {field.get('control_type', '')}"]
    for k, lab in (("name", "name"), ("label", "label"), ("help_text", "placeholder"),
                   ("automation_id", "id"), ("aria_role", "role")):
        v = str(field.get(k, "") or "").strip()
        if v and not (k == "aria_role" and v == "textbox") and not (k == "label" and v == field.get("name")):
            parts.append(f"{lab}: {v[:60]}")
    if "multiline=true" in str(field.get("aria_properties", "")):
        parts.append("multiline")
    return " | ".join(parts)


def is_private_proc(proc: str) -> bool:
    p = str(proc or "").lower()
    return any(n in p for n in PRIVATE_PROCS)


# --------------------------------------------------------------------------- encodeurs
class Embedder:
    """Calcule les embeddings demandes par /embed. Reutilise ce que le service a deja charge."""

    def __init__(self, state, threads: int = 2, idle_unload: float = 120.0) -> None:
        self.state = state
        self.threads = threads
        self.idle_unload = idle_unload
        self._eyes = None  # SiglipEyes a nous (seulement si la vision est coupee)
        self._eyes_used = 0.0
        self._lock = threading.Lock()
        self._reaper = None

    # ------------------------------------------------------------------ ecran
    def _vision_eyes(self):
        v = getattr(self.state, "vision", None)
        return getattr(v, "eyes", None) if v is not None else None

    def _own_eyes(self):
        with self._lock:
            if self._eyes is None:
                from .vision import SiglipEyes

                self._eyes = SiglipEyes(gpu=False, threads=self.threads)  # CPU : la carte graphique reste au jeu
            self._eyes_used = time.time()
            if self._reaper is None:
                self._reaper = threading.Thread(target=self._reap, name="embed-reaper", daemon=True)
                self._reaper.start()
            return self._eyes

    def _reap(self) -> None:
        while True:
            time.sleep(10)
            with self._lock:
                if self._eyes is not None and time.time() - self._eyes_used > self.idle_unload:
                    self._eyes = None
                    import gc

                    gc.collect()

    def grab_screen(self):
        """Capture de l'ecran principal, en memoire (PIL.Image)."""
        import mss
        from PIL import Image

        with mss.mss() as sct:
            shot = sct.grab(sct.monitors[1])
            return Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")

    def screen(self, image=None) -> dict:
        eyes = self._vision_eyes() or self._own_eyes()
        img = image if image is not None else self.grab_screen()
        try:
            v = eyes.embed_images([img])[0]
        finally:
            del img
        path = getattr(eyes, "path", "siglip_vision.onnx")
        return pack(v, screen_model_id(path), file_tag(path))

    # ------------------------------------------------------------------ texte
    def _text_rt(self, wait: float = 15.0):
        st = self.state
        if getattr(st, "decider", None) is None:
            return None
        if getattr(st.decider, "heads", None) is None and hasattr(st, "use_heads"):
            st.use_heads()
            t0 = time.time()
            while st.decider.heads is None and getattr(st, "heads_state", "") == "loading" and time.time() - t0 < wait:
                time.sleep(0.05)
        heads = getattr(st.decider, "heads", None)
        return getattr(heads, "rt", None)  # LayaOnnx (OnnxHeads) ; autre encodeur -> pas de texte

    def text(self, text: str) -> dict | None:
        rt = self._text_rt()
        if rt is None:
            return None
        ids = [rt.cls] + rt._ids(text)[:510] + [rt.sep]
        a = np.array([ids], dtype=np.int64)
        att = np.ones_like(a)
        with rt._lock:
            hidden = rt.enc.run(["hidden"], {"input_ids": a, "attention_mask": att})[0].astype(np.float32)
        v = hidden[0].mean(axis=0)  # moyenne des jetons (masque plein : une seule sequence)
        path = getattr(rt.enc, "_model_path", "") or "laya_encoder.onnx"
        return pack(v, text_model_id(path), file_tag(path))


def handle_embed(state, body: dict) -> tuple[int, dict]:
    """POST /embed (voir l'en-tete du module). Renvoie (code HTTP, objet JSON)."""
    emb = getattr(state, "feedback_embedder", None)
    if emb is None:
        emb = Embedder(state)
        state.feedback_embedder = emb
    t0 = time.perf_counter()
    out: dict = {"ok": True, "screen": None, "text": None, "errors": {}}
    if bool(body.get("screen", True)):
        try:
            from .vision import foreground_info

            fg = foreground_info(set())
            if is_private_proc(fg.get("process", "")):
                out["errors"]["screen"] = "private"
            else:
                out["screen"] = emb.screen()
        except Exception as exc:  # noqa: BLE001
            out["errors"]["screen"] = repr(exc)[:160]
    text = body.get("text")
    field = body.get("field")
    if isinstance(field, dict):
        text = None if field.get("is_password") else field_text(field)
    if isinstance(text, str) and text.strip():
        try:
            out["text"] = emb.text(text[:2000])
            if out["text"] is None:
                out["errors"]["text"] = "no_text_encoder"
        except Exception as exc:  # noqa: BLE001
            out["errors"]["text"] = repr(exc)[:160]
    main = out["screen"] or out["text"]
    out["model_id"] = main["model_id"] if main else ""
    out["dim"] = main["dim"] if main else 0
    out["ms"] = round((time.perf_counter() - t0) * 1000, 1)
    out["ok"] = main is not None or not (body.get("screen", True) or text)
    return 200, out
