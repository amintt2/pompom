"""Partie VISION du banc eval_v2 (appelee par tests/eval_v2.py --vision).

Pour chaque encodeur (siglip = actuel, gemma2 = EmbeddingGemma 2) :
  1. encode TOUS les recadrages utiles d'un ecran une seule fois (plein ecran, fenetre au premier plan, grilles
     2x2 et 3x3, zone de mouvement) -> cache dev/cache/vision_<encodeur>_<jeu>.npz ;
  2. activite, IMAGE SEULE : chaque strategie (full, full+fg, grid2+full, grid3+full, ...) en zero-shot
     (phrases) et avec la tete entrainee si elle existe ;
  3. activite, CHAINE COMPLETE comme le service (a priori du processus, pause plein ecran, penalite « jeu »,
     confirmation de la zone de mouvement) ;
  4. ou est la video : mouvement + confirmation (actuel), mouvement seul, cases 3x3 (zero-shot ou tete),
     mouvement + cases, cases seules ;
  5. temps d'encodage par strategie (CPU, et DirectML avec --gpu), donc precision par ms.
"""

from __future__ import annotations

import json
import os
import statistics
import sys
import time
from collections import defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from PIL import Image  # noqa: E402

from pompom_assist import vision  # noqa: E402
from pompom_assist import vision_strategies as vs  # noqa: E402

EVAL_DIR = ROOT / "data" / "eval_v2" / "vision"
CACHE = ROOT / "dev" / "cache"
CLASSES = list(vision.ACTIVITIES)
GAME_PROCS = vision.PROC_PRIOR["game"]


# --------------------------------------------------------------------------- donnees
def load_set(folder: Path, limit: int = 0) -> list[dict]:
    rows = [json.loads(line) for line in (folder / "labels.jsonl").open(encoding="utf-8") if line.strip()]
    mz = np.load(folder / "motion.npz") if (folder / "motion.npz").exists() else None
    for r in rows:
        r["motion"] = [m.astype(np.float32) for m in mz[r["id"]]] if mz is not None and r["id"] in mz.files else []
        r["path"] = str(folder / f"{r['id']}.jpg")
        r.setdefault("foreground", {})
    if limit:
        step = max(1, len(rows) // limit)
        rows = rows[::step][:limit]
    return rows


def motion_rect(r: dict, w: int, h: int):
    reg = vision.motion_region(r["motion"]) if len(r["motion"]) >= 3 else None
    if reg is None:
        return None, None
    x0, y0, x1, y1, share, _ = reg
    sx, sy = w / vision.MOTION_W, h / vision.MOTION_H
    return [int(x0 * sx), int(y0 * sy), int((x1 - x0) * sx), int((y1 - y0) * sy)], share


def all_crops(r: dict, img: Image.Image) -> dict:
    c = vs.make_crops(img, (r.get("foreground") or {}).get("rect"))
    mr, share = motion_rect(r, *img.size)
    if mr is not None and share < 0.97:
        c["motion"] = img.crop((mr[0], mr[1], mr[0] + mr[2], mr[1] + mr[3]))
    return c


# --------------------------------------------------------------------------- encodeurs
def make_eyes(name: str, gpu: bool, threads: int = 4):
    if name == "siglip":
        return vision.SiglipEyes(gpu=gpu, threads=threads)
    if name == "gemma2":
        from pompom_assist.gemma_onnx import GemmaEyes

        return GemmaEyes(gpu=gpu, threads=threads)
    raise ValueError(name)


def eyes_available(name: str) -> bool:
    if name == "siglip":
        return (ROOT / "models" / "siglip_vision.fp16.onnx").exists()
    return (ROOT / "models" / "gemma2" / "gemma2.json").exists() and any((ROOT / "models" / "gemma2").glob("vision*.onnx"))


def encode_all(name: str, eyes, rows: list[dict], tag: str, batch: int = 8) -> dict[str, np.ndarray]:
    """{"id|cle": vecteur} pour tous les recadrages, avec cache disque (reprise possible)."""
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"vision_{name}_{tag}.npz"
    emb = dict(np.load(path)) if path.exists() else {}
    t0 = time.time()
    todo = [r for r in rows if f"{r['id']}|full" not in emb]
    for i, r in enumerate(todo):
        img = Image.open(r["path"]).convert("RGB")
        crops = all_crops(r, img)
        keys = list(crops)
        for j in range(0, len(keys), batch):
            ks = keys[j:j + batch]
            e = eyes.embed_images([crops[k] for k in ks])
            for k, v in zip(ks, e):
                emb[f"{r['id']}|{k}"] = v.astype(np.float32)
        if i % 10 == 9 or i == len(todo) - 1:
            np.savez(path, **emb)
            el = time.time() - t0
            print(f"  [{name}] {i + 1}/{len(todo)} ecrans encodes ({el / (i + 1):.1f} s/ecran)", flush=True)
    return emb


# --------------------------------------------------------------------------- activite
def zs_probs(eyes, e: np.ndarray, temperature: float) -> np.ndarray:
    p = eyes.class_probs(e, vision.ACTIVITIES, temperature=temperature)
    return np.array([p[c] for c in CLASSES])


def strategy_probs(eyes, emb, rid: str, strat: str, head=None, temperature: float = vision.ACT_TEMPERATURE) -> np.ndarray:
    keys = vs.strategy_keys(strat, {k.split("|", 1)[1] for k in emb if k.startswith(rid + "|")})
    if head is not None:
        x = np.mean([emb[f"{rid}|{k}"] for k in keys], axis=0)
        x = x / np.linalg.norm(x)
        p = head.probs(x)
        return np.array([p[head.labels.index(c)] for c in CLASSES])
    ps = [zs_probs(eyes, emb[f"{rid}|{k}"], temperature) for k in keys]
    # le plein ecran compte autant que l'ensemble des recadrages
    if len(ps) > 1:
        return 0.5 * ps[0] + 0.5 * np.mean(ps[1:], axis=0)
    return ps[0]


def pipeline_probs(eyes, emb, r: dict, base: np.ndarray) -> tuple[np.ndarray, str]:
    """Meme logique que VisionWatcher._classify / _pause_reason (sans lissage dans le temps)."""
    fg = r.get("foreground") or {}
    proc = str(fg.get("process", "")).lower()
    full = bool(r.get("fullscreen"))
    if full and not any(n in proc for n in vision.BROWSERS + vision.PROC_PRIOR["video"]):
        p = np.array([0.85 if c == "game" else 0.15 / (len(CLASSES) - 1) for c in CLASSES])
        return p, "paused"
    probs = dict(zip(CLASSES, base))
    if proc:
        prior = {k: 1.0 for k in probs}
        for k, names in vision.PROC_PRIOR.items():
            if any(n in proc for n in names):
                prior[k] = 3.0
        z = sum(probs[k] ** 0.7 * prior[k] ** 0.3 for k in probs)
        probs = {k: probs[k] ** 0.7 * prior[k] ** 0.3 / z for k in probs}
    if not full and not any(n in proc for n in GAME_PROCS):
        probs["game"] *= 0.3
        z = sum(probs.values())
        probs = {k: v / z for k, v in probs.items()}
    mkey = f"{r['id']}|motion"
    if motion_rect(r, 2560, 1440)[0] is not None:
        e = emb.get(mkey, emb[f"{r['id']}|full"])  # zone >= 97 % de l'ecran : le plein ecran (comme vision.py)
        pv = eyes.class_probs(e, {"video": vision.VIDEO_PROMPTS, "ui": vision.UI_PROMPTS})["video"]
        if pv >= 0.5:
            boost = {k: (1.0 + 3.0 * pv if k == "video" else 1.0) for k in probs}
            z = sum(probs[k] * boost[k] for k in probs)
            probs = {k: probs[k] * boost[k] / z for k in probs}
    return np.array([probs[c] for c in CLASSES]), "screen"


def acc_report(rows, preds) -> dict:
    ok = [CLASSES[int(np.argmax(p))] == r["cls"] for r, p in zip(rows, preds)]
    per = defaultdict(lambda: [0, 0])
    for r, o in zip(rows, ok):
        per[r["cls"]][0] += o
        per[r["cls"]][1] += 1
        if r.get("held_out_style"):
            per["*held_out_style"][0] += o
            per["*held_out_style"][1] += 1
        if r.get("video_motion") == "static" and r["cls"] == "video":
            per["*video_static"][0] += o
            per["*video_static"][1] += 1
    return {"acc": round(sum(ok) / len(ok), 3),
            "per_class": {k: [round(v[0] / v[1], 3), v[1]] for k, v in sorted(per.items())}}


# --------------------------------------------------------------------------- ou est la video
def video_scores_tiles(eyes, emb, rid: str, n: int, head=None) -> np.ndarray:
    out = []
    for i in range(n * n):
        e = emb[f"{rid}|g{n}_{i}"]
        if head is not None:
            p = head.probs(e)
            out.append(p[head.labels.index("video")])
        else:
            out.append(eyes.class_probs(e, {"video": vision.VIDEO_PROMPTS, "ui": vision.UI_PROMPTS})["video"])
    return np.array(out)


def locate(method: str, eyes, emb, r: dict, tile_head=None, w: int = 2560, h: int = 1440):
    mr, share = motion_rect(r, w, h)
    full = bool(r.get("fullscreen"))
    if method == "motion":
        if mr is None:
            return None
        return [0, 0, w, h] if (full and share > 0.6) else mr
    if method == "motion+confirm":  # actuel
        if mr is None:
            return None
        e = emb.get(f"{r['id']}|motion", emb[f"{r['id']}|full"])
        pv = eyes.class_probs(e, {"video": vision.VIDEO_PROMPTS, "ui": vision.UI_PROMPTS})["video"]
        if pv < 0.5:
            return None
        return [0, 0, w, h] if (full and share > 0.6) else mr
    if method.startswith("motion-any"):
        reg = vs.motion_region_any(r["motion"]) if len(r["motion"]) >= 3 else None
        mra = None
        if reg is not None:
            x0, y0, x1, y1, sh = reg
            sx, sy = w / vision.MOTION_W, h / vision.MOTION_H
            mra = [int(x0 * sx), int(y0 * sy), int((x1 - x0) * sx), int((y1 - y0) * sy)]
            if full and sh > 0.6:
                mra = [0, 0, w, h]
        if method == "motion-any":
            return mra
        sc = video_scores_tiles(eyes, emb, r["id"], 3, tile_head)
        if mra is not None and vs.tile_mean(sc, mra, w, h, 3) >= 0.5:
            return mra
        return vs.rect_from_tiles(sc, w, h, 3, 0.75) if mra is None else None
    sc = video_scores_tiles(eyes, emb, r["id"], 3, tile_head)
    if method == "tiles":
        return vs.rect_from_tiles(sc, w, h, 3, 0.5)
    if method == "motion+tiles":
        if mr is not None:
            if vs.tile_mean(sc, mr, w, h, 3) >= 0.5:
                return [0, 0, w, h] if (full and share > 0.6) else mr
            return None
        return vs.rect_from_tiles(sc, w, h, 3, 0.75)  # video immobile : seuil plus strict
    raise ValueError(method)


def loc_report(rows, rects) -> dict:
    tp = fp = fn = 0
    ious = []
    per_motion = defaultdict(lambda: [0, 0])
    for r, got in zip(rows, rects):
        want = r.get("video_rect")
        if want:
            i = vs.iou(want, got)
            hit = i >= 0.5
            tp += hit
            fn += not hit
            if got and not hit:
                fp += 1
            if hit:
                ious.append(i)
            per_motion[r.get("video_motion") or "?"][0] += hit
            per_motion[r.get("video_motion") or "?"][1] += 1
        elif got:
            fp += 1
    n_pos = sum(1 for r in rows if r.get("video_rect"))
    n_neg = len(rows) - n_pos
    prec = tp / max(1, tp + fp)
    rec = tp / max(1, n_pos)
    return {"recall_iou50": round(rec, 3), "precision": round(prec, 3),
            "f1": round(2 * prec * rec / max(1e-9, prec + rec), 3),
            "false_alarm_rate_no_video": round(sum(1 for r, g in zip(rows, rects) if not r.get("video_rect") and g) / max(1, n_neg), 3),
            "mean_iou_hits": round(float(np.mean(ious)), 3) if ious else None,
            "recall_by_motion": {k: [round(v[0] / v[1], 3), v[1]] for k, v in sorted(per_motion.items())}}


# --------------------------------------------------------------------------- temps par strategie
CROP_COST = {"full": ["full"], "full+fg": ["full", "fg"], "grid2+full": ["full"] + [f"g2_{i}" for i in range(4)],
             "grid3+full": ["full"] + [f"g3_{i}" for i in range(9)],
             "grid3+full+fg": ["full", "fg"] + [f"g3_{i}" for i in range(9)],
             "motion+confirm": ["full", "motion"], "motion+tiles": ["full"] + [f"g3_{i}" for i in range(9)],
             "tiles (sans plein ecran)": [f"g3_{i}" for i in range(9)]}


def timing(eyes, rows: list[dict], n: int = 10) -> dict:
    out = {}
    sample = rows[:: max(1, len(rows) // n)][:n]
    for strat, keys in CROP_COST.items():
        ts = []
        for r in sample:
            img = Image.open(r["path"]).convert("RGB")
            t0 = time.perf_counter()
            c = all_crops(r, img)
            ims = [c[k] for k in keys if k in c] or [img]
            eyes.embed_images(ims)
            ts.append((time.perf_counter() - t0) * 1000)
        ts = sorted(ts[1:]) if len(ts) > 2 else ts
        out[strat] = {"p50_ms": round(statistics.median(ts), 1), "p95_ms": round(ts[int(0.95 * (len(ts) - 1))], 1)}
    return out


# --------------------------------------------------------------------------- principal
def load_vision_heads(name: str):
    from pompom_assist.np_heads import load_heads

    p = {"gemma2": ROOT / "models" / "gemma2" / "vision_heads.npz",
         "siglip": ROOT / "dev" / "heads_vision" / "siglip_vision_heads.npz"}[name]
    return load_heads(p) if p.exists() else {}


def run(args) -> dict:
    folder = Path(args.real_vision) if getattr(args, "real_vision", "") else EVAL_DIR
    rows = load_set(folder, args.limit)
    tag = "real" if getattr(args, "real_vision", "") else "eval"
    print(f"\n=== VISION : {len(rows)} ecrans ({folder}) ===")
    res = {"n": len(rows), "source": str(folder), "backends": {}}
    strategies = [s for s in (args.strategies.split(",") if args.strategies else vs.STRATEGIES)]
    for name in args.vision_backends:
        if not eyes_available(name):
            print(f"  [{name}] modeles absents : ignore")
            continue
        eyes = make_eyes(name, gpu=False, threads=args.threads)
        eyes.class_probs(np.zeros(getattr(eyes, 'dim', 768), np.float32) + 1e-3, vision.ACTIVITIES)
        emb = encode_all(name, eyes, rows, tag)
        heads = load_vision_heads(name)
        b = {"activity_image_only": {}, "activity_pipeline": {}, "video_location": {}, "timing_cpu": {}}
        for strat in strategies:
            preds = [strategy_probs(eyes, emb, r["id"], strat) for r in rows]
            b["activity_image_only"][f"{strat} / zero-shot"] = acc_report(rows, preds)
            hk = f"activity:{strat}"
            if hk in heads:
                preds_h = [strategy_probs(eyes, emb, r["id"], strat, heads[hk]) for r in rows]
                b["activity_image_only"][f"{strat} / tete"] = acc_report(rows, preds_h)
        for strat in ("full", "full+fg", "grid2+full"):
            for mode in ("zero-shot", "tete"):
                hk = f"activity:{strat}"
                if mode == "tete" and hk not in heads:
                    continue
                pp = [pipeline_probs(eyes, emb, r, strategy_probs(eyes, emb, r["id"], strat, heads.get(hk) if mode == "tete" else None))[0] for r in rows]
                b["activity_pipeline"][f"{strat} / {mode}"] = acc_report(rows, pp)
        th = heads.get("tile_video:g3")
        for m in ("motion", "motion+confirm", "tiles", "motion+tiles", "motion-any", "motion-any+tiles"):
            b["video_location"][f"{m} / zero-shot"] = loc_report(rows, [locate(m, eyes, emb, r) for r in rows])
            if th is not None and "tiles" in m:
                b["video_location"][f"{m} / tete"] = loc_report(rows, [locate(m, eyes, emb, r, th) for r in rows])
        b["timing_cpu"] = timing(eyes, rows) if not getattr(args, "no_timing", False) else {}
        b["backend"] = eyes.backend
        if args.gpu:
            try:
                eg = make_eyes(name, gpu=True, threads=2)
                b["timing_directml"] = timing(eg, rows) if eg.backend == "directml" else "indisponible"
                del eg
            except Exception as exc:  # noqa: BLE001
                b["timing_directml"] = f"erreur : {exc!r}"[:200]
        res["backends"][name] = b
        print_backend(name, b)
        del eyes
    return res


def print_backend(name: str, b: dict) -> None:
    print(f"\n[{name}] activite (image seule) :")
    for k, v in b["activity_image_only"].items():
        print(f"   {k:32} acc {v['acc']:.3f}   " + " ".join(f"{c}={a[0]:.2f}" for c, a in v["per_class"].items()))
    print(f"[{name}] activite (chaine complete du service) :")
    for k, v in b["activity_pipeline"].items():
        print(f"   {k:32} acc {v['acc']:.3f}")
    print(f"[{name}] ou est la video :")
    for k, v in b["video_location"].items():
        print(f"   {k:32} rappel {v['recall_iou50']:.3f} precision {v['precision']:.3f} F1 {v['f1']:.3f} "
              f"fausses alertes {v['false_alarm_rate_no_video']:.3f}  {v['recall_by_motion']}")
    if b["timing_cpu"]:
        print(f"[{name}] temps CPU : " + ", ".join(f"{k} {v['p50_ms']} ms" for k, v in b["timing_cpu"].items()))
    if "timing_directml" in b:
        print(f"[{name}] temps DirectML : {b['timing_directml']}")
