"""(dev, avec PyTorch) Verifie que le chemin ONNX donne les memes reponses que stuntd/laya en PyTorch.

  .venv-dev\\Scripts\\python.exe tests/parity_onnx.py [--n 60]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

os.environ.setdefault("HF_HUB_OFFLINE", "1")
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=60)
    a = ap.parse_args()
    from laya.common import build_sequence
    from stuntd.train.layout import Layout
    from stuntd.train.trainer import site_row

    from pompom_assist.heads import StuntdHeads, describe_field, text_kind_input
    from pompom_assist.laya_onnx import LayaOnnx

    th = StuntdHeads(gpu=False)
    ox = LayaOnnx(gpu=False)
    tok = th._dec._agent.tok if th._dec._agent is not None else None
    with open(ROOT / "data" / "test.jsonl", encoding="utf-8") as f:
        rows = [json.loads(line) for line in f][: a.n]
    from pompom_assist import rules

    worst, agree, same_ids, n = 0.0, 0, 0, 0
    for r in rows:
        for site in ("field_kind", "text_kind"):
            if not (th.has(site) and ox.has(site)):
                continue
            text = describe_field(r["field"]) if site == "field_kind" else \
                text_kind_input(r["kind"], r["field"], [rules.content_type(c) for c in r["candidates"]])
            model = th._models[site]
            lay = Layout(model.max_len or 512, model.head_max_len or 192, model.spaced_labels)
            ref_ids = site_row(tok, text, model.field, model.labels, lay)["ids"]
            labels, p, _ = ox.site_probs(site, text)
            m = ox.meta["sites"][site]
            mine, _mk = ox.build(text, "choice", f"Choose {m['field']}",
                                 dict.fromkeys([x.replace("_", " ") for x in labels] if m["spaced_labels"] else labels),
                                 m["max_len"] or 512, m["head_max_len"] or 192)
            same_ids += mine == ref_ids
            a_t = th.ask(site, text)
            pt = np.array([a_t.probs[x] for x in labels])
            worst = max(worst, float(np.abs(pt - p).max()))
            agree += labels[int(np.argmax(p))] == a_t.label
            n += 1
    zs = ox.zero_shot("Le compagnon a faim.", "choice", "Que fait-il ?", {"manger": None, "dormir": None, "jouer": None})
    zt = th.choose("Que fait-il ?", ["manger", "dormir", "jouer"], "Le compagnon a faim.")
    print(f"tokens identiques {same_ids}/{n} ; meme reponse {agree}/{n} ; ecart max de probabilite {worst:.4f}")
    print("zero-shot onnx", {k: round(v, 3) for k, v in zs.items()}, " torch", {k: round(v, 3) for k, v in zt.probs.items()})
    _ = build_sequence


if __name__ == "__main__":
    main()
