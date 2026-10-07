"""Tableaux Markdown a partir des derniers resultats de tests/eval_v2.py (data/eval_v2/results/*.json).

  python tests/eval_v2_report.py            # imprime les tableaux (texte, vision, latence, RAM)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

RES = Path(__file__).resolve().parent.parent / "data" / "eval_v2" / "results"


def latest(pattern: str):
    fs = sorted(RES.glob(pattern))
    return json.loads(fs[-1].read_text(encoding="utf-8")) if fs else None


def all_results(pattern: str):
    """Tous les fichiers, du plus ancien au plus recent (les plus recents ecrasent les memes configurations)."""
    return [json.loads(f.read_text(encoding="utf-8")) for f in sorted(RES.glob(pattern)) if "_real" not in f.name]


def text_tables() -> None:
    rows = {}
    for d in all_results("*_text*.json"):
        if d:
            for c in d["configs"]:
                rows[c["config"]] = c
            heads = d.get("heads_direct", {})
            for b, sites in heads.items():
                for site, m in sites.items():
                    rows[f"__{b}:{site}"] = m
    print("| config | sorte juste | bonne suggestion | bout en bout | secrets jamais proposés | p50 ms | p95 ms | appels modèle |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for k, c in rows.items():
        if k.startswith("__"):
            continue
        print(f"| {k} | {c['field_kind_acc']:.3f} | {c['right_suggestion_acc']:.3f} | {c['end_to_end_acc']:.3f} | "
              f"{c['secrets_never_suggested']:.3f} ({c['secret_rows_leaked']} fuites) | {c['p50_ms']} | {c['p95_ms']} | "
              f"{c['model_call_share']:.0%} |")
    print("\n| tête seule | précision | couverture au seuil | précision si sûre | ECE |")
    print("| --- | --- | --- | --- | --- |")
    for k, m in rows.items():
        if k.startswith("__"):
            print(f"| {k[2:]} | {m['acc']:.3f} | {m['coverage_at_threshold']:.3f} | {m['acc_when_confident']} | {m['ece_certainty']:.3f} |")


def vision_tables() -> None:
    merged = {}
    for d in all_results("*_vision*.json"):
        for name, b in d.get("backends", {}).items():
            cur = merged.setdefault(name, {})
            for k, v in b.items():
                if v or k not in cur:  # un passage --no-timing ne doit pas effacer les temps mesures avant
                    cur[k] = v
    for name, b in merged.items():
        if True:
            t = b["timing_cpu"]
            print(f"\n**{name}** — activité, image seule (360 écrans) ; temps CPU p50 par strategie\n")
            print("| stratégie | zéro-shot | tête entraînée | styles jamais vus (tête) | vidéo immobile (tête) | ms CPU |")
            print("| --- | --- | --- | --- | --- | --- |")
            act = b["activity_image_only"]
            for strat in dict.fromkeys(k.split(" / ")[0] for k in act):
                z = act.get(f"{strat} / zero-shot", {})
                h = act.get(f"{strat} / tete", {})
                pc = h.get("per_class", {})
                print(f"| {strat} | {z.get('acc', '-')} | {h.get('acc', '-')} | {pc.get('*held_out_style', ['-'])[0]} | "
                      f"{pc.get('*video_static', ['-'])[0]} | {t.get(strat, {}).get('p50_ms', '-')} |")
            print("\n| chaîne complète du service | précision |\n| --- | --- |")
            for k, v in b["activity_pipeline"].items():
                print(f"| {k} | {v['acc']} |")
            print("\n| où est la vidéo | rappel (IoU ≥ 0,5) | précision | F1 | fausses alertes sans vidéo | rappel bouge / immobile / parle |")
            print("| --- | --- | --- | --- | --- | --- |")
            for k, v in b["video_location"].items():
                rm = v["recall_by_motion"]
                print(f"| {k} | {v['recall_iou50']} | {v['precision']} | {v['f1']} | {v['false_alarm_rate_no_video']} | "
                      f"{rm.get('moving', ['-'])[0]} / {rm.get('static', ['-'])[0]} / {rm.get('talking', ['-'])[0]} |")
            if "timing_directml" in b:
                print(f"\nDirectML : {b['timing_directml']}")


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    print("## Texte\n")
    text_tables()
    print("\n## Vision")
    vision_tables()
    for pat, title in (("*_latency*.json", "Latence"), ("*_ram*.json", "RAM")):
        d = latest(pat)
        if d:
            print(f"\n## {title}\n\n```\n{json.dumps(d, ensure_ascii=False, indent=1)}\n```")


if __name__ == "__main__":
    main()
