"""Affiche un fichier de resultats de bench.py en tableau : python data/summarize.py [fichier]"""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "data/bench_results.jsonl"
with open(path, encoding="utf-8") as f:
    for line in f:
        r = json.loads(line)
        print(f"{(r['model'] or '-'):18} {r['split']:5} {r['mode']:7} {str(r['backend']):8} kind={r['field_kind_acc']:.3f} "
              f"pick={r['best_candidate_acc']:.3f} e2e={r['end_to_end_acc']:.3f} p50={r['p50_ms']:7.2f} p95={r['p95_ms']:7.2f} "
              f"call50={r.get('head_call_p50_ms')} call95={r.get('head_call_p95_ms')} calls={r.get('head_calls')} "
              f"load={r['load_s']}s")
