"""Laya + tetes stuntd SANS PyTorch : ONNX Runtime + numpy + `tokenizers`.

Reproduit exactement ce que font laya (build_head / build_sequence) et stuntd (site_row, decide) a
l'entrainement, avec les graphes exportes par export_onnx.py :
  encodeur (input_ids, attention_mask) -> hidden
  tete     (hidden, attention_mask, marker_pos, marker_mask, qtype) -> logits
"""

from __future__ import annotations

import json
import math
import threading
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "models"
QTYPES = {"choice": 0, "score": 1, "noul": 2}
TEMP_MIN, TEMP_MAX = 0.5, 5.0


def _clamp_t(t) -> float:
    try:
        t = float(t)
    except (TypeError, ValueError):
        return 1.0
    if not math.isfinite(t):
        return 1.0
    return min(TEMP_MAX, max(TEMP_MIN, t))


def certainty(p: np.ndarray) -> float:
    """1 - entropie normalisee (meme formule que stuntd.train.metrics.confidence)."""
    if len(p) < 2:
        return 1.0
    ent = -float(np.sum(p * np.log(np.clip(p, 1e-12, 1.0))))
    return round(min(1.0, max(0.0, 1.0 - ent / math.log(len(p)))), 6)


def softmax(x: np.ndarray, t: float = 1.0) -> np.ndarray:
    z = x / t
    z = z - z.max()
    e = np.exp(z)
    return e / e.sum()


def session(path: Path, gpu: bool, threads: int):
    import onnxruntime as ort

    so = ort.SessionOptions()
    so.intra_op_num_threads = max(1, threads)
    so.inter_op_num_threads = 1
    so.log_severity_level = 3
    so.enable_cpu_mem_arena = False  # moins de RAM gardee entre deux appels
    if ".fp16." in str(path):
        # bug de fusion LayerNorm d'ORT sur certains graphes fp16 (SigLIP) : optimisations de base seulement
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    if gpu:
        try:
            so_g = ort.SessionOptions()
            so_g.enable_mem_pattern = False
            so_g.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
            so_g.log_severity_level = 3
            s = ort.InferenceSession(str(path), so_g, providers=["DmlExecutionProvider", "CPUExecutionProvider"])
            if "DmlExecutionProvider" in s.get_providers():
                return s, "directml"
        except Exception:
            pass
    return ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"]), "cpu"


def find(stem: str, models: Path = MODELS, prefer: str = "int8") -> Path:
    order = [f".{prefer}.onnx"] + [f".{q}.onnx" for q in ("mixed", "fp16", "int8", "fp32") if q != prefer]
    # (un seul format est livre par modele ; l'ordre ne sert qu'aux comparaisons en developpement)
    for suffix in order + [".onnx"]:
        p = models / (stem + suffix)
        if p.exists():
            return p
    raise FileNotFoundError(stem)


class LayaOnnx:
    def __init__(self, gpu: bool = False, threads: int = 4, models: Path = MODELS, prefer: str = "mixed") -> None:
        from tokenizers import Tokenizer

        t0 = time.perf_counter()
        self.meta = json.loads((models / "heads.json").read_text(encoding="utf-8"))
        sp = self.meta["special"]
        self.cls, self.sep, self.mask, self.pad = sp["cls"], sp["sep"], sp["mask"], sp["pad"]
        self.mask_token = sp["mask_token"]
        self.tok = Tokenizer.from_file(str(models / "laya_tokenizer.json"))
        self.tok.no_truncation()
        self.tok.no_padding()
        self.enc, self.backend = session(find("laya_encoder", models, prefer), gpu, threads)
        # tetes chargees a la premiere utilisation (la tete « base » ne sert qu'a decide())
        self._head_paths = {}
        for site in self.meta["sites"].keys() | {"base"}:
            try:
                self._head_paths[site] = find(f"head_{site}", models, "fp32" if prefer == "fp32" else "fp16")
            except FileNotFoundError:
                pass
        self.heads = {}
        self._threads = threads
        self._lock = threading.Lock()
        self.load_s = time.perf_counter() - t0

    # ------------------------------------------------------------------ texte -> sequence (laya)
    def _ids(self, text: str) -> list[int]:
        return self.tok.encode(text, add_special_tokens=False).ids

    def _render(self, t: str, crit) -> list[str]:
        if t == "choice":
            return [str(k) if v is None or v == "" else f"{k}: {v}" for k, v in crit.items()]
        if t == "noul":
            crit = crit or {}
            f, tr = crit.get("false"), crit.get("true")
            return ["false: " + (f if f else "no, the statement does not hold"),
                    "true: " + (tr if tr else "yes, the statement holds")]
        return [f"level {i}: {c}" for i, c in enumerate(crit)]

    def build(self, state: str, t: str, ins: str, crit, max_len: int, head_max_len: int) -> tuple[list[int], list[int]]:
        opts = self._render(t, crit)
        head_ids = self._ids("%s question: %s" % (t, str(ins).replace(self.mask_token, " ")))
        opt_ids = [[self.mask] + self._ids(" " + o.replace(self.mask_token, " "))[:48] for o in opts]
        budget = head_max_len - sum(len(o) for o in opt_ids)
        if budget < 16:
            per = max(4, (head_max_len - 16) // max(1, len(opt_ids)))
            opt_ids = [o[:per] for o in opt_ids]
            budget = head_max_len - sum(len(o) for o in opt_ids)
        head_ids = head_ids[: max(8, budget)]
        ids = [self.cls] + head_ids + [self.sep]
        markers = []
        for o in opt_ids:
            markers.append(len(ids))
            ids.extend(o)
        ids.append(self.sep)
        room = max(0, max_len - len(ids) - 1)
        st = self._ids(state.replace(self.mask_token, " "))[:room]
        ids = ids + st + [self.sep]
        ids, markers = ids[:max_len], [m for m in markers if m < max_len]
        return ids, markers

    def logits(self, site: str, ids: list[int], markers: list[int], qtype: int) -> np.ndarray:
        a_ids = np.array([ids], dtype=np.int64)
        att = np.ones_like(a_ids)
        with self._lock:
            hidden = self.enc.run(["hidden"], {"input_ids": a_ids, "attention_mask": att})[0].astype(np.float32)
            if site not in self.heads:
                self.heads[site] = session(self._head_paths[site], False, self._threads)[0]  # petit : CPU
            out = self.heads[site].run(["logits"], {
                "hidden": hidden, "attention_mask": att, "marker_pos": np.array([markers], dtype=np.int64),
                "marker_mask": np.ones((1, len(markers)), dtype=bool), "qtype": np.array([qtype], dtype=np.int64)})[0]
        return out[0]

    # ------------------------------------------------------------------ sites stuntd
    def has(self, site: str) -> bool:
        return site in self._head_paths and site in self.meta["sites"]

    def site_probs(self, site: str, text: str) -> tuple[list[str], np.ndarray, dict]:
        m = self.meta["sites"][site]
        labels = m["labels"]
        options = [lab.replace("_", " ") for lab in labels] if m.get("spaced_labels") else labels
        lay = self.meta["laya"]
        ids, markers = self.build(text, "choice", f"Choose {m['field']}", dict.fromkeys(options),
                                  m.get("max_len") or lay["max_len"], m.get("head_max_len") or lay["head_max_len"])
        lg = self.logits(site, ids, markers, QTYPES["choice"])[: len(labels)]
        return labels, softmax(lg.astype(np.float64), m["temperature"]), m

    # ------------------------------------------------------------------ zero-shot (tete d'origine)
    def zero_shot(self, state: str, t: str, ins: str, crit) -> dict[str, float]:
        lay = self.meta["laya"]
        ids, markers = self.build(state, t, ins, crit, lay["max_len"], lay["head_max_len"])
        k = len(markers)
        lg = self.logits("base", ids, markers, QTYPES[t])[:k].astype(np.float64)  # charge la tete au 1er appel
        size = "2" if k <= 2 else "3-5" if k <= 5 else "6-10" if k <= 10 else "11+"
        tb = self.meta.get("temperature_by_options", {})
        temp = _clamp_t(tb.get(f"{t}:{size}", self.meta["temperature"][QTYPES[t]]))
        p = softmax(lg, temp)
        names = list(crit.keys()) if t == "choice" else (["false", "true"] if t == "noul" else [str(i) for i in range(k)])
        return dict(zip(names, p.tolist()))
