"""Re-entraine les petites tetes sur donnees REELLES (+ synthetiques) et compare aux tetes actuelles sur le
decoupage d'evaluation REEL (jours jamais vus a l'entrainement).

  python tools/train_real_heads.py [--data data/real] [--task all|activity|game_event|field_kind]
                                   [--synthetic-weight 0.3] [--synthetic-text] [--baseline-heads] [--out data/real/probes]

Tete = regression logistique multinomiale (numpy, CPU, quelques secondes) sur l'embedding normalise de
l'encodeur fige (SigLIP pour l'ecran, Laya moyenne des jetons pour les champs). Elle se charge en 2 lignes :
  z = np.load("probe_activity.npz"); p = softmax(z["W"] @ x + z["b"])

Synthetiques (optionnels, poids --synthetic-weight par rapport au reel) :
  - activity  : les phrases d'exemple des classes de la vision (models/siglip_prompts.npz) ;
  - field_kind: data/train_field_kind.jsonl encode par Laya (--synthetic-text : lourd, mis en cache) ;
  - --synthetic-npz FICHIER : tout autre jeu (X, y, labels).

Tetes actuelles (reference) :
  - activity  : choix zero-shot SigLIP actuel (vision.py, 7 classes grossieres) -> on compare au niveau grossier ;
  - field_kind: tete stuntd actuelle (--baseline-heads, si le texte local du champ est disponible) ;
  - game_event: pas de modele d'ecran actuel -> classe majoritaire.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from real_common import (  # noqa: E402
    ACTIVITY_TO_VISION, OUT_DIR, ROOT, TASKS, current_models, l2, low_priority, read_jsonl, task_kind,
)

# phrases de la vision actuelle -> etiquette fine (synthetiques pour « activity »)
PROMPT_TO_FINE = {"an email inbox": "email", "a spreadsheet with rows and columns": "spreadsheet",
                  "a terminal window with command line text": "code", "a slide presentation being edited": "docs"}
COARSE_TO_FINE = {"game": "game", "video": "video", "work_code": "code", "work_docs": "docs", "browse": "browse",
                  "chat": "chat", "other": "other"}


def softmax(z: np.ndarray) -> np.ndarray:
    z = z - z.max(axis=-1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=-1, keepdims=True)


def train_lr(X: np.ndarray, y: np.ndarray, k: int, w: np.ndarray | None = None, l2reg: float = 1e-4,
             epochs: int = 400, lr: float = 0.05, seed: int = 0) -> tuple[np.ndarray, np.ndarray]:
    """Regression logistique multinomiale, Adam plein lot. Renvoie W (k x d), b (k)."""
    n, d = X.shape
    rng = np.random.default_rng(seed)
    W = rng.normal(0, 0.01, (k, d)).astype(np.float64)
    b = np.zeros(k)
    w = np.ones(n) if w is None else w
    w = w / w.sum()
    Y = np.eye(k)[y]
    m = [np.zeros_like(W), np.zeros_like(b)]
    v = [np.zeros_like(W), np.zeros_like(b)]
    for t in range(1, epochs + 1):
        P = softmax(X @ W.T * 1.0 + b)
        G = (P - Y) * w[:, None]
        gW = G.T @ X + l2reg * W
        gb = G.sum(0)
        for i, g in enumerate((gW, gb)):
            m[i] = 0.9 * m[i] + 0.1 * g
            v[i] = 0.999 * v[i] + 0.001 * g * g
            step = lr * (m[i] / (1 - 0.9 ** t)) / (np.sqrt(v[i] / (1 - 0.999 ** t)) + 1e-8)
            if i == 0:
                W -= step
            else:
                b -= step
    return W.astype(np.float32), b.astype(np.float32)


def balanced_weights(y: np.ndarray, k: int) -> np.ndarray:
    cnt = np.bincount(y, minlength=k).astype(np.float64)
    return 1.0 / np.maximum(cnt[y], 1.0)


def load_split(data: Path, task: str, split: str) -> dict | None:
    p = data / f"{task}_{split}.npz"
    if not p.exists():
        return None
    with np.load(p) as z:
        return {k: z[k] for k in z.files}


# --------------------------------------------------------------------------- synthetiques
def synthetic_activity(models_dir: Path) -> tuple[np.ndarray, np.ndarray] | None:
    p = models_dir / "siglip_prompts.npz"
    if not p.exists():
        return None
    from pompom_assist.vision import ACTIVITIES

    with np.load(p) as z:
        emb = {str(t): e for t, e in zip(z["texts"], z["emb"])}
    labels = TASKS["activity"]
    X, y = [], []
    for coarse, prompts in ACTIVITIES.items():
        for t in prompts:
            if t in emb:
                X.append(l2(emb[t]))
                y.append(labels.index(PROMPT_TO_FINE.get(t, COARSE_TO_FINE[coarse])))
    return (np.stack(X), np.array(y)) if X else None


def synthetic_field_kind(cache: Path) -> tuple[np.ndarray, np.ndarray] | None:
    if cache.exists():
        with np.load(cache) as z:
            return z["X"], z["y"]
    rows = read_jsonl(ROOT / "data" / "train_field_kind.jsonl")
    if not rows:
        return None
    from pompom_assist.feedback import Embedder

    class _St:  # etat minimal : seulement l'encodeur de texte
        def __init__(self):
            from pompom_assist.heads import OnnxHeads

            self.decider = type("D", (), {"heads": OnnxHeads(gpu=False, threads=2)})()

    emb = Embedder(_St())
    labels = TASKS["field_kind"]
    X, y = [], []
    for i, r in enumerate(rows):
        if r.get("answer") not in labels:
            continue
        # meme forme que feedback.field_text : on retire la partie « window: ... »
        txt = " | ".join(p for p in str(r["text"]).split(" | ") if not p.startswith("window:"))
        from pompom_assist.feedback import unpack

        X.append(unpack(emb.text(txt)))
        y.append(labels.index(r["answer"]))
        if (i + 1) % 200 == 0:
            print(f"  synthetiques field_kind : {i + 1}/{len(rows)}")
    X, y = np.stack(X), np.array(y)
    cache.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(cache, X=X, y=y)
    return X, y


# --------------------------------------------------------------------------- tetes actuelles
def baseline_activity(models_dir: Path, X: np.ndarray) -> np.ndarray | None:
    """Prediction grossiere (7 classes) du zero-shot SigLIP actuel (sans l'a priori du processus)."""
    p = models_dir / "siglip_prompts.npz"
    if not p.exists():
        return None
    import math

    from pompom_assist.vision import ACT_TEMPERATURE, ACTIVITIES

    with np.load(p) as z:
        emb = {str(t): e for t, e in zip(z["texts"], z["emb"])}
    lg = json.loads((models_dir / "siglip_logit.json").read_text(encoding="utf-8"))
    scale = math.exp(lg["logit_scale"][0])
    names = list(ACTIVITIES)
    cent = np.stack([l2(np.mean([emb[t] for t in ACTIVITIES[n]], axis=0)) for n in names])
    pred = (scale * X @ cent.T / ACT_TEMPERATURE).argmax(1)
    return np.array([names[i] for i in pred])


def baseline_field_kind(texts: np.ndarray) -> np.ndarray | None:
    if len(texts) == 0 or not all(str(t) for t in texts):
        return None
    from pompom_assist.heads import SITE_FIELD, OnnxHeads

    h = OnnxHeads(gpu=False, threads=2)
    return np.array([h.ask(SITE_FIELD, str(t)).label for t in texts])


# --------------------------------------------------------------------------- principal
def run_task(task: str, a, models_dir: Path, models: dict) -> dict | None:
    tr, ev = load_split(Path(a.data), task, "train"), load_split(Path(a.data), task, "eval")
    if tr is None:
        print(f"{task}: pas de donnees d'entrainement reelles")
        return None
    labels = list(TASKS[task])
    k = len(labels)
    X, y = tr["X"].astype(np.float64), tr["y"].astype(np.int64)
    w = balanced_weights(y, k)
    n_real = len(y)
    n_syn = 0
    syn = None
    if a.synthetic_weight > 0:
        if task == "activity":
            syn = synthetic_activity(models_dir)
        elif task == "field_kind" and a.synthetic_text:
            syn = synthetic_field_kind(Path(a.data) / "synth_field_kind.npz")
        if a.synthetic_npz:
            with np.load(a.synthetic_npz) as z:
                extra = (z["X"], z["y"]) if [str(x) for x in z["labels"]] == labels else None
            if extra is not None:
                syn = extra if syn is None else (np.vstack([syn[0], extra[0]]), np.concatenate([syn[1], extra[1]]))
    if syn is not None:
        sx, sy = syn
        n_syn = len(sy)
        ws = np.full(n_syn, a.synthetic_weight * w.sum() / max(n_syn, 1))
        X, y, w = np.vstack([X, sx]), np.concatenate([y, sy]), np.concatenate([w, ws])
    W, b = train_lr(X, y, k, w, l2reg=a.l2, epochs=a.epochs)
    res = {"task": task, "n_train_real": n_real, "n_train_synthetic": n_syn, "n_eval": 0}
    if ev is not None:
        Xe, ye = ev["X"].astype(np.float64), ev["y"]
        pred = (Xe @ W.T + b).argmax(1)
        res["n_eval"] = int(len(ye))
        res["new_acc"] = float((pred == ye).mean())
        res["per_label_eval"] = {labels[i]: int((ye == i).sum()) for i in range(k) if (ye == i).any()}
        if task == "activity":
            truth_c = np.array([ACTIVITY_TO_VISION[labels[i]] for i in ye])
            new_c = np.array([ACTIVITY_TO_VISION[labels[i]] for i in pred])
            res["new_acc_coarse"] = float((new_c == truth_c).mean())
            base = baseline_activity(models_dir, Xe)
            if base is not None:
                res["current_acc_coarse"] = float((base == truth_c).mean())
                res["current"] = "zero-shot SigLIP (7 classes)"
        elif task == "field_kind":
            base = baseline_field_kind(ev.get("text", np.array([]))) if a.baseline_heads else None
            if base is not None:
                res["current_acc"] = float((base == np.array([labels[i] for i in ye])).mean())
                res["current"] = "tete stuntd field_kind"
        else:
            maj = np.bincount(tr["y"], minlength=k).argmax()
            res["current_acc"] = float((ye == maj).mean())
            res["current"] = "classe majoritaire (aucun modele d'ecran actuel)"
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    mk = models.get(task_kind(task), {})
    np.savez_compressed(out / f"probe_{task}.npz", W=W, b=b, labels=np.array(labels), task=np.array(task),
                        model_id=np.array(mk.get("model_id", "")), model_version=np.array(mk.get("model_version", "")),
                        metrics=np.array(json.dumps(res)))
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", default=str(OUT_DIR))
    ap.add_argument("--task", default="all", choices=["all", *TASKS])
    ap.add_argument("--out", default=str(OUT_DIR / "probes"))
    ap.add_argument("--models", default=str(ROOT / "models"))
    ap.add_argument("--synthetic-weight", type=float, default=0.3)
    ap.add_argument("--synthetic-text", action="store_true", help="encode data/train_field_kind.jsonl (lourd)")
    ap.add_argument("--synthetic-npz", default="")
    ap.add_argument("--baseline-heads", action="store_true", help="charge la tete stuntd actuelle (field_kind)")
    ap.add_argument("--epochs", type=int, default=400)
    ap.add_argument("--l2", type=float, default=1e-4)
    a = ap.parse_args(argv)
    low_priority()
    manifest = Path(a.data) / "manifest.json"
    models = json.loads(manifest.read_text(encoding="utf-8")).get("models", {}) if manifest.exists() else current_models()
    tasks = list(TASKS) if a.task == "all" else [a.task]
    report = [r for t in tasks if (r := run_task(t, a, Path(a.models), models))]
    print(f"\n{'tache':11s} {'reel':>6s} {'synth':>6s} {'eval':>5s}  {'nouvelle':>9s}  {'actuelle':>9s}")
    for r in report:
        new = r.get("new_acc_coarse", r.get("new_acc"))
        cur = r.get("current_acc_coarse", r.get("current_acc"))
        fmt = lambda v: "   n/a   " if v is None else f"{100 * v:8.1f}%"  # noqa: E731
        print(f"{r['task']:11s} {r['n_train_real']:6d} {r['n_train_synthetic']:6d} {r['n_eval']:5d}  {fmt(new)}  {fmt(cur)}"
              + ("  (niveau grossier, 7 classes)" if "new_acc_coarse" in r else ""))
    Path(a.out).mkdir(parents=True, exist_ok=True)
    (Path(a.out) / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
