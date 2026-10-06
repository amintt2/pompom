"""Affiche bench_results.jsonl en tableau : python data/summarize.py [fichier]"""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "bench_results.jsonl"
for line in open(path, encoding="utf-8"):
    r = json.loads(line)
    print(f"{(r['model'] or '-')[:34]:34} {r['split']:5} {r['mode']:14} {str(r['backend']):7} kind={r['field_kind_acc']:.3f} "
          f"pick={r['best_candidate_acc']:.3f} e2e={r['end_to_end_acc']:.3f} p50={r['p50_ms']:7.2f} p95={r['p95_ms']:7.2f} "
          f"call50={r['llm_call_p50_ms']} call95={r['llm_call_p95_ms']} calls={r['llm_calls']} load={r['load_s']}s")
