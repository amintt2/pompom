"""Outils communs de la boucle de retour sur donnees reelles (developpement uniquement).

Dossiers par defaut :
  - jeu de donnees local du jeu : %APPDATA%/Pompom/dataset  (feedback.jsonl, screens/, shots/)
  - sorties des outils          : assistant/data/real/       (labels.jsonl, *.npz, rapports)
"""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # assistant/
sys.path.insert(0, str(ROOT))

from pompom_assist.feedback import (  # noqa: E402,F401
    ACTIVITY_LABELS, ACTIVITY_TO_VISION, GAME_EVENT_LABELS, TASKS, file_tag, l2, screen_model_id, text_model_id,
    unpack,
)

OUT_DIR = ROOT / "data" / "real"


def dataset_dir() -> Path:
    env = os.environ.get("POMPOM_DATASET_DIR")
    if env:
        return Path(env)
    base = os.environ.get("APPDATA") or str(Path.home() / ".local" / "share")
    return Path(base) / "Pompom" / "dataset"


def low_priority() -> None:
    """Le PC sert aussi a jouer : on passe en priorite basse (Windows) / nice 10 (ailleurs)."""
    try:
        if os.name == "nt":
            # (meme correctif que pompom_assist/lowprio.py : sans restype/argtypes, ctypes tronque la
            #  pseudo-poignee -1 et SetPriorityClass echoue sans rien dire)
            from pompom_assist.lowprio import set_low_priority

            set_low_priority()
        else:
            os.nice(10)
    except Exception:  # noqa: BLE001
        pass


def read_jsonl(path: Path) -> list[dict]:
    out = []
    if not path.exists():
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue  # ligne tronquee (arret brutal) : ignoree
            if isinstance(d, dict):
                out.append(d)
    return out


def append_jsonl(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def sha1_file(path: Path) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def current_models(models: Path | None = None) -> dict:
    """model_id / model_version des encodeurs ACTUELS (ceux du dossier models/)."""
    from pompom_assist.laya_onnx import MODELS, find

    m = models or MODELS
    out = {}
    try:
        p = find("siglip_vision", m, "int8")
        out["screen"] = {"model_id": screen_model_id(p), "model_version": file_tag(p), "path": str(p)}
    except FileNotFoundError:
        pass
    try:
        p = find("laya_encoder", m, "mixed")
        out["text"] = {"model_id": text_model_id(p), "model_version": file_tag(p), "path": str(p)}
    except FileNotFoundError:
        pass
    return out


def task_kind(task: str) -> str:
    """Quel encodeur produit les entrees d'une tache : 'screen' ou 'text'."""
    return "text" if task == "field_kind" else "screen"
