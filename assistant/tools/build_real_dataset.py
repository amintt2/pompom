"""Construit le jeu de donnees REEL (developpement) pour re-entrainer les petites tetes.

  python tools/build_real_dataset.py [--labels data/real/labels.jsonl] [--export serveur.jsonl ...]
                                     [--dataset %APPDATA%/Pompom/dataset] [--out data/real] [--eval-frac 0.2]

Sources fusionnees :
  1. captures du mode developpeur etiquetees par label_screens.py (embedding SigLIP calcule ICI, en local,
     avec l'encodeur ACTUEL ; cache par empreinte d'image) ;
  2. corrections faites dans le jeu (feedback*.jsonl du dossier dataset) ;
  3. export du serveur de contributions anonymes (GET /v1/export : embeddings float16 uniquement).

Les embeddings dependent du modele : un exemple n'est garde que si son model_id + model_version sont ceux de
l'encodeur actuel (sinon il est recalcule depuis la capture locale quand elle existe, ou compte comme ignore).

Doublons : meme tache + meme vecteur (arrondi) -> un seul exemple ; si les etiquettes se contredisent, on
garde la majorite (>= 2/3) ou on jette.

Decoupage entrainement / evaluation PAR JOUR (aucune fuite : deux captures d'une meme journee se ressemblent
trop) : un jour va en evaluation si sha1(jour) tombe dans les premiers --eval-frac ; au moins un jour de chaque
cote des qu'il y en a deux.

Sorties : <out>/<tache>_train.npz et <tache>_eval.npz (X float32 normalises, y, labels, day, source, app)
+ <out>/manifest.json (comptes, modeles, jours d'evaluation).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from real_common import (  # noqa: E402
    OUT_DIR, TASKS, current_models, dataset_dir, l2, low_priority, read_jsonl, task_kind, unpack,
)

_DAY_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")


def day_of(*vals) -> str:
    for v in vals:
        if isinstance(v, (int, float)) and v > 1e9:
            return time.strftime("%Y-%m-%d", time.localtime(v))
        m = _DAY_RE.search(str(v or ""))
        if m:
            return m.group(1)
    return "unknown"


def is_eval_day(day: str, frac: float) -> bool:
    return int(hashlib.sha1(day.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF < frac


def split_days(days: list[str], frac: float) -> set[str]:
    uniq = sorted(set(days))
    ev = {d for d in uniq if is_eval_day(d, frac)}
    if len(uniq) >= 2:
        if not ev:
            ev = {uniq[-1]}  # le jour le plus recent
        if ev == set(uniq):
            ev.discard(uniq[0])
    return ev


def vkey(task: str, x: np.ndarray) -> str:
    return task + ":" + hashlib.sha1(np.round(x, 3).astype(np.float16).tobytes()).hexdigest()


class ScreenEncoder:
    """Encodeur SigLIP actuel (CPU, peu de fils) avec cache disque par empreinte d'image."""

    def __init__(self, cache: Path, version: str, threads: int = 2) -> None:
        self.cache_path = cache
        self.version = version
        self.threads = threads
        self._eyes = None
        self.cache: dict[str, np.ndarray] = {}
        if cache.exists():
            with np.load(cache) as z:
                if str(z["version"]) == version:
                    self.cache = {str(k): v for k, v in zip(z["keys"], z["X"])}

    def __call__(self, path: Path, key: str) -> np.ndarray:
        if key not in self.cache:
            if self._eyes is None:
                from pompom_assist.vision import SiglipEyes

                self._eyes = SiglipEyes(gpu=False, threads=self.threads)
            from PIL import Image

            with Image.open(path) as im:
                self.cache[key] = self._eyes.embed_images([im.convert("RGB")])[0]
        return self.cache[key]

    def save(self) -> None:
        if self.cache:
            self.cache_path.parent.mkdir(parents=True, exist_ok=True)
            keys = list(self.cache)
            np.savez_compressed(self.cache_path, keys=np.array(keys), X=np.stack([self.cache[k] for k in keys]),
                                version=np.array(self.version))


def build(a, models: dict, embed_screen=None) -> dict:
    """Coeur de l'outil (separe pour les tests). embed_screen(path, key) -> vecteur, ou None."""
    recs: list[dict] = []
    skipped = Counter()
    want = {k: (v["model_id"], v["model_version"]) for k, v in models.items()}

    def add(task, label, x, day, source, app="", text=""):
        if task not in TASKS or label not in TASKS[task]:
            skipped["bad_label"] += 1
            return
        recs.append({"task": task, "label": label, "x": l2(x), "day": day, "source": source, "app": app, "text": text})

    # 1) captures etiquetees
    screens = Path(a.dataset) / "screens"
    for d in read_jsonl(Path(a.labels)) if a.labels else []:
        lab = d.get("label") or {}
        img = screens / str(d.get("file", ""))
        if not lab or not img.exists() or embed_screen is None:
            skipped["screen_missing" if lab else "no_label"] += 1
            continue
        meta = d.get("meta") or {}
        x = embed_screen(img, str(d.get("sha1") or img.name))
        day = day_of(meta.get("day"), meta.get("time"), img.name)
        app = str(meta.get("proc", ""))
        if float(lab.get("activity_confidence", 0)) >= a.min_conf:
            add("activity", lab.get("activity"), x, day, "screens", app)
        else:
            skipped["low_confidence"] += 1
        if (lab.get("game") or meta.get("game")) and float(lab.get("hud_event_confidence", 0)) >= a.min_conf:
            add("game_event", lab.get("hud_event"), x, day, "screens", app)

    # 2) corrections du jeu
    fb_files = sorted(Path(a.dataset).glob("feedback*.jsonl"))
    for f in fb_files:
        for s in read_jsonl(f):
            task, emb = str(s.get("task", "")), s.get("emb")
            kind = task_kind(task)
            x = None
            if isinstance(emb, dict) and (emb.get("model_id"), emb.get("model_version")) == want.get(kind):
                x = unpack(emb)
            else:
                shot = str((s.get("local") or {}).get("shot", ""))
                p = Path(a.dataset) / shot if shot else None
                if kind == "screen" and p is not None and p.exists() and embed_screen is not None:
                    x = embed_screen(p, "shot:" + p.name)
            if x is None:
                skipped["feedback_model_mismatch" if emb else "feedback_no_embedding"] += 1
                continue
            add(task, str(s.get("label", "")), x, day_of(s.get("day"), s.get("time")), "feedback",
                str(s.get("app", "")), str((s.get("local") or {}).get("field_text", "")))

    # 3) export du serveur
    for path in a.export or []:
        for s in read_jsonl(Path(path)):
            task = str(s.get("task", ""))
            if (s.get("model_id"), s.get("model_version")) != want.get(task_kind(task)):
                skipped["server_model_mismatch"] += 1
                continue
            x = unpack(s)
            if x.size != int(s.get("dim", -1)) or not np.all(np.isfinite(x)):
                skipped["server_bad_vector"] += 1
                continue
            add(task, str(s.get("label", "")), x, day_of(s.get("day")), "server", str(s.get("app", "")))

    # doublons / contradictions
    groups: dict[str, list[dict]] = defaultdict(list)
    for r in recs:
        groups[vkey(r["task"], r["x"])].append(r)
    kept = []
    for g in groups.values():
        c = Counter(r["label"] for r in g)
        lab, n = c.most_common(1)[0]
        if n / len(g) >= 2 / 3:
            keep = next(r for r in g if r["label"] == lab)
            kept.append(keep)
            skipped["duplicates"] += len(g) - 1
        else:
            skipped["conflicts"] += len(g)

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    ev_days = split_days([r["day"] for r in kept], a.eval_frac)
    manifest = {"models": models, "eval_days": sorted(ev_days), "skipped": dict(skipped), "tasks": {},
                "built": time.strftime("%Y-%m-%d %H:%M:%S")}
    for task, labels in TASKS.items():
        rows = [r for r in kept if r["task"] == task]
        if not rows:
            continue
        info = {}
        for split in ("train", "eval"):
            part = [r for r in rows if (r["day"] in ev_days) == (split == "eval")]
            if not part:
                continue
            np.savez_compressed(
                out / f"{task}_{split}.npz", X=np.stack([r["x"] for r in part]).astype(np.float32),
                y=np.array([labels.index(r["label"]) for r in part], dtype=np.int64), labels=np.array(labels),
                day=np.array([r["day"] for r in part]), source=np.array([r["source"] for r in part]),
                app=np.array([r["app"] for r in part]), text=np.array([r["text"] for r in part]))
            info[split] = {"n": len(part), "labels": dict(Counter(r["label"] for r in part)),
                           "sources": dict(Counter(r["source"] for r in part))}
        manifest["tasks"][task] = info
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    return manifest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", default=str(dataset_dir()))
    ap.add_argument("--labels", default=str(OUT_DIR / "labels.jsonl"))
    ap.add_argument("--export", nargs="*", default=[], help="fichier(s) jsonl de GET /v1/export")
    ap.add_argument("--out", default=str(OUT_DIR))
    ap.add_argument("--eval-frac", type=float, default=0.2)
    ap.add_argument("--min-conf", type=float, default=0.5, help="confiance minimale des etiquettes du grand modele")
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--no-screens", action="store_true", help="ne pas calculer d'embeddings d'images")
    a = ap.parse_args(argv)
    low_priority()
    models = current_models()
    enc = None
    if not a.no_screens and "screen" in models:
        enc = ScreenEncoder(Path(a.out) / "screen_cache.npz", models["screen"]["model_version"], a.threads)
    try:
        m = build(a, {k: {"model_id": v["model_id"], "model_version": v["model_version"]} for k, v in models.items()}, enc)
    finally:
        if enc is not None:
            enc.save()
    for task, info in m["tasks"].items():
        print(f"{task:11s} train={info.get('train', {}).get('n', 0):5d}  eval={info.get('eval', {}).get('n', 0):5d}")
    print("ignores :", m["skipped"], "| jours d'evaluation :", len(m["eval_days"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
