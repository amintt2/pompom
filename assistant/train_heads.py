"""Entraine HORS LIGNE les tetes stuntd de Pompom (aucun professeur, aucun LLM, aucun reseau).

  python train_heads.py [--base multilingual|english] [--n 4800] [--epochs 24]

1. data/gen_train.py ecrit des lignes etiquetees ({"text", "answer"}) pour chaque site de decision ;
2. `stuntd import SITE fichier --labels ...` les enregistre dans une base stuntd de travail (.stuntd_work) ;
3. `stuntd train` ajuste une tete par site sur l'encodeur Laya fige (sur CPU : stable, ~quelques minutes) ;
4. les tetes (head.safetensors + meta.json + embeddings.safetensors) sont copiees dans heads/<site>/.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from pompom_assist import rules  # noqa: E402
from pompom_assist.heads import HEADS_DIR, LAYA_DIR, SITE_FIELD, SITE_TEXT  # noqa: E402

TEXT_LABELS = list(rules.CONTENT_TYPES) + ["none"]
SITES = {
    SITE_FIELD: ("data/train_field_kind.jsonl", list(rules.FIELD_KINDS)),
    SITE_TEXT: ("data/train_text_kind.jsonl", TEXT_LABELS),
}

CONFIG = """\
learn = true
[redaction]
enabled = false          # lignes synthetiques : rien a masquer
[storage]
max_rows = 1000000
max_age_days = 36500
[training]
min_examples = 300
holdout = 0.2
target_agreement = 0.99
base_model = {base!r}
epochs = {epochs}
device = "cpu"           # entrainement sur CPU : pas de charge GPU prolongee
cache_encoder = true
novelty_quantile = 0.95
"""


def run(args: list[str], env: dict) -> None:
    print("$", " ".join(args), flush=True)
    subprocess.run(args, check=True, env=env)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="multilingual", choices=["multilingual", "english"])
    ap.add_argument("--n", type=int, default=4800)
    ap.add_argument("--epochs", type=int, default=24)
    ap.add_argument("--out", default=str(HEADS_DIR))
    ap.add_argument("--sites", default=",".join(SITES))
    a = ap.parse_args()
    base = str(LAYA_DIR / "multilingual") if a.base == "multilingual" else str(LAYA_DIR)
    py = sys.executable
    stuntd_cmd = [py, "-c", "import sys; from stuntd.cli import main; sys.exit(main())"]
    work = ROOT / "dev" / ".stuntd_work"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir()
    cfg = work / "stuntd.toml"
    cfg.write_text(CONFIG.format(base=base, epochs=a.epochs), encoding="utf-8")
    env = dict(os.environ, STUNTD_DATA_DIR=str(work), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    t0 = time.time()
    run([py, str(ROOT / "data" / "gen_train.py"), "--n", str(a.n)], env)
    sites = [s for s in a.sites.split(",") if s]
    for site in sites:
        path, labels = SITES[site]
        run([*stuntd_cmd, "import", site, str(ROOT / path), "--labels", ",".join(labels), "--config", str(cfg)], env)
    run([*stuntd_cmd, "train", *sites, "--config", str(cfg)], env)
    out = Path(a.out)
    out.mkdir(exist_ok=True)
    for site in sites:
        src = work / "models" / site
        if not (src / "head.safetensors").exists():
            raise SystemExit(f"pas de tete pour {site}")
        dst = out / site
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
    for site in sites:
        run([*stuntd_cmd, "report", site, "--config", str(cfg)], env)
    shutil.rmtree(work)
    print(f"tetes ecrites dans {out} en {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
