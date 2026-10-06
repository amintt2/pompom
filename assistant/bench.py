"""Precision + latence de la couche de decision sur le jeu synthetique.

  python bench.py --split test                      # regles seules (pas de modele)
  python bench.py --split test --llm --gpu          # hybride, llama-server Vulkan
  python bench.py --split test --llm --cpu --model Qwen3-0.6B-Q4_K_M.gguf
  python bench.py ... --force-llm                   # le modele decide TOUJOURS la sorte (comparaison de modeles)
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from pompom_assist.decider import Decider  # noqa: E402
from pompom_assist.llm import DEFAULT_MODEL, LlamaClient, LlamaServer, ServerConfig  # noqa: E402
from pompom_assist import rules  # noqa: E402


def pct(xs: list[float], q: float) -> float:
    if not xs:
        return 0.0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def run(args) -> dict:
    rows = [json.loads(l) for l in open(HERE / "data" / f"{args.split}.jsonl", encoding="utf-8")]
    if args.limit:
        rows = rows[: args.limit]
    server = None
    llm = None
    load_s = 0.0
    if args.llm:
        cfg = ServerConfig(model=args.model, gpu=args.gpu, threads=args.threads,
                           log_path=str(HERE / "llama_bench.log") if args.log else "")
        server = LlamaServer(cfg)
        t0 = time.time()
        if not server.start() or not server.wait_ready(60):
            print("llama-server KO:", server.error)
            return {}
        load_s = time.time() - t0
        llm = LlamaClient(server.base, timeout=30, api_key=server.api_key)
    dec = Decider(llm, kind_threshold=(2.0 if args.force_llm else 0.85))
    try:
        if llm:  # chauffe (charge le prefixe commun en cache)
            for r in rows[:3]:
                dec.suggest(r["field"], r["candidates"])
        k_ok = p_ok = both_ok = type_ok = type_n = 0
        lat, llm_lat, calls = [], [], 0
        per_kind: dict[str, list[int]] = {}
        errors = []
        for r in rows:
            t0 = time.perf_counter()
            s = dec.suggest(r["field"], r["candidates"])
            lat.append((time.perf_counter() - t0) * 1000)
            if s.llm_ms:
                llm_lat.append(s.llm_ms)
                calls += 1
            kk = s.kind == r["kind"]
            pk = s.index == r["best"]
            k_ok += kk
            p_ok += pk
            both_ok += kk and pk
            per_kind.setdefault(r["kind"], [0, 0])
            per_kind[r["kind"]][0] += kk
            per_kind[r["kind"]][1] += 1
            for t, g in zip(s.candidate_types, r["types"]):
                type_n += 1
                type_ok += (t == g) or (g == "text" and t in ("text",))
            if not (kk and pk) and len(errors) < args.show_errors:
                errors.append({"want": [r["kind"], r["best"]], "got": [s.kind, s.index, s.kind_source, s.pick_source],
                               "field": r["field"]["name"], "title": r["field"]["window_title"], "types": s.candidate_types})
        n = len(rows)
        res = {
            "split": args.split, "n": n, "mode": ("llm-only-kind" if args.force_llm else "hybrid") if llm else "rules",
            "model": args.model if llm else None, "backend": server.backend if server else None,
            "load_s": round(load_s, 2),
            "field_kind_acc": round(k_ok / n, 3), "best_candidate_acc": round(p_ok / n, 3),
            "end_to_end_acc": round(both_ok / n, 3), "content_type_acc": round(type_ok / max(1, type_n), 3),
            "p50_ms": round(statistics.median(lat), 2), "p95_ms": round(pct(lat, 0.95), 2), "max_ms": round(max(lat), 2),
            "llm_calls": calls, "llm_call_p50_ms": round(statistics.median(llm_lat), 2) if llm_lat else None,
            "llm_call_p95_ms": round(pct(llm_lat, 0.95), 2) if llm_lat else None,
            "per_kind": {k: round(v[0] / v[1], 2) for k, v in sorted(per_kind.items())},
        }
        print(json.dumps(res, ensure_ascii=False, indent=1))
        for e in errors:
            print("  ERR", json.dumps(e, ensure_ascii=False))
        return res
    finally:
        if server:
            server.stop()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="test")
    ap.add_argument("--llm", action="store_true")
    ap.add_argument("--gpu", action="store_true")
    ap.add_argument("--cpu", action="store_true")
    ap.add_argument("--force-llm", action="store_true")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--show-errors", type=int, default=12)
    ap.add_argument("--log", action="store_true")
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
