"""Precision + latence de la couche de decision sur le jeu synthetique.

  python bench.py --split test                          # regles seules (pas de modele)
  python bench.py --split test --heads --gpu            # hybride : regles + tetes stuntd (DirectML)
  python bench.py --split test --heads --cpu --mode heads   # les tetes stuntd decident tout (CPU)
  python bench.py ... --base english --heads-dir heads_english  # autre checkpoint Laya
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from pompom_assist.decider import Decider  # noqa: E402


def pct(xs: list[float], q: float) -> float:
    if not xs:
        return 0.0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def run(args) -> dict:
    with open(HERE / "data" / f"{args.split}.jsonl", encoding="utf-8") as f:
        rows = [json.loads(line) for line in f]
    if args.limit:
        rows = rows[: args.limit]
    heads = None
    load_s = 0.0
    if args.heads:
        t0 = time.time()
        if args.runtime == "torch":
            from pompom_assist.heads import StuntdHeads

            heads = StuntdHeads(gpu=args.gpu, base=("" if args.base == "english" else args.base),
                                heads_dir=HERE / args.heads_dir, threads=args.threads)
        else:
            from pompom_assist.heads import OnnxHeads

            heads = OnnxHeads(gpu=args.gpu, threads=args.threads, prefer=args.precision)
        heads.warm()
        load_s = time.time() - t0
    dec = Decider(heads, mode=args.mode)
    for r in rows[:3]:  # chauffe
        dec.suggest(r["field"], r["candidates"])
    k_ok = p_ok = both_ok = 0
    lat, model_lat, calls = [], [], 0
    per_kind: dict[str, list[int]] = {}
    errors = []
    for r in rows:
        t0 = time.perf_counter()
        s = dec.suggest(r["field"], r["candidates"])
        lat.append((time.perf_counter() - t0) * 1000)
        n_calls = 1 if s.model_ms else 0  # suggestions qui ont fait tourner une tete (1 ou 2 passes)
        if n_calls:
            model_lat.append(s.model_ms)
            calls += n_calls
        kk = s.kind == r["kind"]
        pk = s.index == r["best"]
        k_ok += kk
        p_ok += pk
        both_ok += kk and pk
        per_kind.setdefault(r["kind"], [0, 0])
        per_kind[r["kind"]][0] += kk and pk
        per_kind[r["kind"]][1] += 1
        if not (kk and pk) and len(errors) < args.show_errors:
            errors.append({"want": [r["kind"], r["best"]], "got": [s.kind, s.index, s.kind_source, s.pick_source],
                           "field": r["field"]["name"], "title": r["field"]["window_title"], "types": s.candidate_types})
    n = len(rows)
    res = {
        "split": args.split, "n": n, "mode": args.mode if heads else "rules",
        "model": (f"laya-{args.base}/{args.runtime}" + (f"-{args.precision}" if args.runtime == "onnx" else "")) if heads else None, "backend": heads.backend if heads else None,
        "load_s": round(load_s, 2),
        "field_kind_acc": round(k_ok / n, 3), "best_candidate_acc": round(p_ok / n, 3),
        "end_to_end_acc": round(both_ok / n, 3),
        "p50_ms": round(statistics.median(lat), 2), "p95_ms": round(pct(lat, 0.95), 2), "max_ms": round(max(lat), 2),
        "head_calls": calls, "head_call_p50_ms": round(statistics.median(model_lat), 2) if model_lat else None,
        "head_call_p95_ms": round(pct(model_lat, 0.95), 2) if model_lat else None,
        "per_kind_e2e": {k: round(v[0] / v[1], 2) for k, v in sorted(per_kind.items())},
    }
    print(json.dumps(res, ensure_ascii=False, indent=1))
    for e in errors:
        print("  ERR", json.dumps(e, ensure_ascii=False))
    return res


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="test")
    ap.add_argument("--heads", action="store_true")
    ap.add_argument("--gpu", action="store_true")
    ap.add_argument("--cpu", action="store_true")
    ap.add_argument("--mode", default="hybrid", choices=["hybrid", "heads"])
    ap.add_argument("--base", default="multilingual")
    ap.add_argument("--heads-dir", default="heads")
    ap.add_argument("--runtime", default="onnx", choices=["onnx", "torch"])
    ap.add_argument("--precision", default="mixed", choices=["int8", "fp16", "fp32", "mixed"])
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--show-errors", type=int, default=12)
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    if args.cpu:
        args.gpu = False
    res = run(args)
    if args.out and res:
        with open(args.out, "a", encoding="utf-8") as f:
            f.write(json.dumps(res, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
