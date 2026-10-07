"""Petites tetes de decision en numpy pur (aucun PyTorch a l'execution).

Entrainees cote dev (train_gemma_heads.py, PyTorch CPU), sauvegardees en .npz :
  <p>W1 [d, h], <p>b1 [h], <p>W2 [h, k], <p>b2 [k]     MLP : x -> ReLU(x W1 + b1) W2 + b2
  <p>q [d] (facultatif)                                 attention : poids = softmax(T q / sqrt(d)) sur les jetons
  <p>ln_g, <p>ln_b (facultatif)                         LayerNorm sur l'entree
  meta (json) : etiquettes, temperature, seuil de certitude (99 % d'accord sur des lignes mises de cote, comme stuntd)
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np


def softmax(x: np.ndarray, t: float = 1.0, axis: int = -1) -> np.ndarray:
    z = x / t
    z = z - z.max(axis=axis, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=axis, keepdims=True)


def certainty(p: np.ndarray) -> float:
    """1 - entropie normalisee (meme formule que stuntd)."""
    if len(p) < 2:
        return 1.0
    ent = -float(np.sum(p * np.log(np.clip(p, 1e-12, 1.0))))
    return round(min(1.0, max(0.0, 1.0 - ent / math.log(len(p)))), 6)


class NpHead:
    def __init__(self, arrays: dict, prefix: str, meta: dict) -> None:
        g = lambda k: arrays.get(prefix + k)  # noqa: E731
        self.W1, self.b1, self.W2, self.b2 = g("W1"), g("b1"), g("W2"), g("b2")
        self.q = g("q")
        self.ln_g, self.ln_b = g("ln_g"), g("ln_b")
        self.meta = meta
        self.labels: list[str] = meta.get("labels", [])
        self.temperature = float(meta.get("temperature", 1.0))
        self.threshold = meta.get("threshold")
        self.dim = int(meta.get("dim", self.W1.shape[0]))

    def pool(self, tokens: np.ndarray, mask: np.ndarray | None = None) -> np.ndarray:
        """tokens [n, d] -> vecteur [d] (attention apprise si q existe, sinon moyenne)."""
        if mask is not None:
            tokens = tokens[mask.astype(bool)]
        if self.q is None:
            return tokens.mean(0)
        a = softmax(tokens @ self.q / math.sqrt(tokens.shape[1]))
        return a @ tokens

    def logits(self, x: np.ndarray) -> np.ndarray:
        x = np.asarray(x, np.float32)
        if x.shape[-1] > self.dim:  # Matryoshka : on garde les premieres dimensions puis on renormalise
            x = x[..., : self.dim]
            x = x / (np.linalg.norm(x, axis=-1, keepdims=True) + 1e-9)
        if self.ln_g is not None:
            mu = x.mean(-1, keepdims=True)
            var = x.var(-1, keepdims=True)
            x = (x - mu) / np.sqrt(var + 1e-5) * self.ln_g + self.ln_b
        h = np.maximum(0.0, x @ self.W1 + self.b1)
        return h @ self.W2 + self.b2

    def probs(self, x: np.ndarray) -> np.ndarray:
        return softmax(self.logits(x).astype(np.float64), self.temperature)


def load_heads(path: Path) -> dict[str, NpHead]:
    z = np.load(path, allow_pickle=False)
    arrays = {k: z[k] for k in z.files if k != "meta"}
    meta = json.loads(str(z["meta"]))
    return {name: NpHead(arrays, name + ".", m) for name, m in meta.items()}


def save_heads(path: Path, heads: dict[str, tuple[dict, dict]]) -> None:
    """heads : nom -> (tableaux numpy {W1, b1, ...}, meta)."""
    arrays, meta = {}, {}
    for name, (arrs, m) in heads.items():
        for k, v in arrs.items():
            arrays[f"{name}.{k}"] = np.asarray(v, np.float32)
        meta[name] = m
    np.savez_compressed(path, meta=np.array(json.dumps(meta, ensure_ascii=False)), **arrays)
