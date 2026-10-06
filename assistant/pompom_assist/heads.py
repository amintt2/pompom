"""Decisions typees par stuntd : encodeur Laya fige + petites tetes de classification entrainees.

Rien n'est genere : chaque decision est un CHOIX parmi des etiquettes fixes (field_kind, text_kind) ou
parmi les options donnees (decide(), en zero-shot sur la tete d'origine de Laya).

  - field_kind : description du champ -> email, phone, address, url, search, name, code, chat_message,
                 username, number, date, other
  - text_kind  : sorte + description + types copies disponibles -> type de texte a coller (ou none) ;
                 les etiquettes absentes des textes copies sont masquees avant de choisir.

Les tetes sont entrainees hors ligne (train_heads.py) avec `stuntd import` + `stuntd train` sur nos
lignes synthetiques etiquetees : aucun "professeur", aucun LLM, aucun reseau.
Execution : stuntd.serve.decider.Decider, sur CPU ou sur la carte graphique via DirectML.
"""

from __future__ import annotations

import os
import re
import threading
import time
import warnings
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEV = ROOT / "dev"  # environnement de developpement (PyTorch, checkpoints, tetes) : pas livre
LAYA_DIR = DEV / "laya_model"
HEADS_DIR = DEV / "heads"
DEFAULT_BASE = "multilingual"  # sous-dossier de laya_model ; "" = Laya anglais (ModernBERT-large)

SITE_FIELD = "field_kind"
SITE_TEXT = "text_kind"

# --------------------------------------------------------------------------- textes vus par les tetes
_BROWSER_SUFFIX = re.compile(r"\s+[-–—]\s+(Google Chrome|Mozilla Firefox|Opera|Brave|Vivaldi|"
                             r"(Personnel|Personal|Profil \d+|Profile \d+)?\s*-?\s*Microsoft.{0,2}Edge)\s*$")


def window_title(field: dict) -> str:
    return _BROWSER_SUFFIX.sub("", str(field.get("window_title", "") or "")).strip()[:60]


def describe_field(field: dict) -> str:
    """Description d'un champ, ecrite pareil a l'entrainement et en service (jamais son contenu)."""
    parts = [f"app: {field.get('process', '')}", f"window: {window_title(field)}",
             f"control: {field.get('control_type', '')}"]
    for k, lab in (("name", "name"), ("label", "label"), ("help_text", "placeholder"),
                   ("automation_id", "id"), ("aria_role", "role")):
        v = str(field.get(k, "") or "").strip()
        if v and not (k == "aria_role" and v == "textbox") and not (k == "label" and v == field.get("name")):
            parts.append(f"{lab}: {v[:60]}")
    if "multiline=true" in str(field.get("aria_properties", "")):
        parts.append("multiline")
    return " | ".join(parts)


field_text_for_head = describe_field


def text_kind_input(kind: str, field: dict, types: list[str]) -> str:
    uniq = list(dict.fromkeys(types))
    return f"field: {kind} | {describe_field(field)} | copied: {', '.join(uniq) if uniq else 'nothing'}"


# --------------------------------------------------------------------------- execution
@dataclass
class HeadAnswer:
    label: str
    confidence: float  # probabilite de l'etiquette choisie (apres masquage eventuel)
    probs: dict[str, float]
    ms: float
    novel: bool = False
    certainty: float = 1.0  # 1 - entropie normalisee (la « confidence » de stuntd)
    confident: bool = True  # certainty >= seuil d'exploitation fixe a l'entrainement (99 % d'accord)


def directml_device() -> str | None:
    """'privateuseone:0' si torch-directml voit une carte graphique, sinon None."""
    try:
        import torch_directml  # type: ignore

        if torch_directml.device_count() > 0:
            return str(torch_directml.device())
    except Exception:
        return None
    return None


class StuntdHeads:
    """Charge Laya une fois et sert les tetes entrainees de chaque site de decision."""

    def __init__(self, gpu: bool = False, base: str = DEFAULT_BASE, heads_dir: Path = HEADS_DIR,
                 threads: int = 4) -> None:
        import torch

        warnings.filterwarnings("ignore", category=UserWarning)
        torch.set_num_threads(max(1, threads))
        self.base_path = str(LAYA_DIR / base) if base else str(LAYA_DIR)
        self.heads_dir = heads_dir
        self.device = (directml_device() if gpu else None) or "cpu"
        self.backend = "directml" if self.device != "cpu" else "cpu"
        from stuntd.serve.decider import Decider
        from stuntd.train.artifacts import HEAD_FILE, load_model

        t0 = time.perf_counter()
        self._dec = Decider(self.base_path, device=self.device)
        self.load_s = time.perf_counter() - t0
        self._models = {}
        self._head_paths = {}
        for site in (SITE_FIELD, SITE_TEXT):
            try:
                self._models[site] = load_model(heads_dir, site)
                self._head_paths[site] = heads_dir / site / HEAD_FILE
            except (FileNotFoundError, ValueError):
                pass
        self._lock = threading.Lock()

    def has(self, site: str) -> bool:
        return site in self._models

    def warm(self) -> None:
        for site in self._models:
            self._dec.warm(self._models[site], self._head_paths[site])
        self.choose("warm", ["a", "b"])

    def ask(self, site: str, text: str, allowed: list[str] | None = None) -> HeadAnswer:
        model = self._models[site]
        t0 = time.perf_counter()
        with self._lock:
            v = self._dec.decide(model, self._head_paths[site], text)
        probs = dict(zip(model.labels, v.probabilities))
        if allowed is not None:
            probs = {k: p for k, p in probs.items() if k in allowed}
            total = sum(probs.values()) or 1.0
            probs = {k: p / total for k, p in probs.items()}
        label = max(probs, key=probs.__getitem__)
        novel = v.novelty is not None and model.novelty_cutoff is not None and v.novelty > model.novelty_cutoff
        sure = model.threshold is None or v.confidence >= model.threshold
        return HeadAnswer(label, probs[label], probs, (time.perf_counter() - t0) * 1000, novel, v.confidence, sure)

    def choose(self, question: str, options: list[str], context: str = "") -> HeadAnswer:
        """Question fermee quelconque, en zero-shot (tete d'origine de Laya, sans entrainement)."""
        t0 = time.perf_counter()
        crit = {o: None for o in options}
        with self._lock:
            r = self._dec.answer(context or question, {"q": {"type": "choice", "instructions": question,
                                                             "criteria": crit}})
        a = r["answers"]["q"]
        probs = {k: float(v) for k, v in (a.get("probabilities") or {}).items()}
        label = str(a.get("choice", options[0]))
        return HeadAnswer(label, probs.get(label, float(a.get("confidence", 0.0))), probs,
                          (time.perf_counter() - t0) * 1000)


def env_threads() -> int:
    try:
        return int(os.environ.get("POMPOM_ASSIST_THREADS", "4"))
    except ValueError:
        return 4


class OnnxHeads:
    """Meme interface que StuntdHeads, sans PyTorch : graphes ONNX exportes (export_onnx.py) + numpy.
    C'est ce qu'utilise le service ; StuntdHeads (PyTorch) ne sert qu'au developpement et aux comparaisons."""

    def __init__(self, gpu: bool = False, threads: int = 4, prefer: str = "mixed") -> None:
        from . import laya_onnx

        self.rt = laya_onnx.LayaOnnx(gpu=gpu, threads=threads, prefer=prefer)
        self.backend = self.rt.backend
        self.load_s = self.rt.load_s
        self._sites = {s: m for s, m in self.rt.meta["sites"].items() if self.rt.has(s)}

    def has(self, site: str) -> bool:
        return site in self._sites

    def warm(self) -> None:
        for site in self._sites:
            self.rt.site_probs(site, "app: x.exe | window: warm | control: edit | name: warm")

    def ask(self, site: str, text: str, allowed: list[str] | None = None) -> HeadAnswer:
        from .laya_onnx import certainty

        t0 = time.perf_counter()
        labels, p, m = self.rt.site_probs(site, text)
        cert = certainty(p)
        probs = dict(zip(labels, p.tolist()))
        if allowed is not None:
            probs = {k: v for k, v in probs.items() if k in allowed}
            z = sum(probs.values()) or 1.0
            probs = {k: v / z for k, v in probs.items()}
        label = max(probs, key=probs.__getitem__)
        sure = m.get("threshold") is None or cert >= m["threshold"]
        return HeadAnswer(label, probs[label], probs, (time.perf_counter() - t0) * 1000, False, cert, sure)

    def choose(self, question: str, options: list[str], context: str = "") -> HeadAnswer:
        t0 = time.perf_counter()
        probs = self.rt.zero_shot(context or question, "choice", question, {o: None for o in options})
        label = max(probs, key=probs.__getitem__)
        return HeadAnswer(label, probs[label], probs, (time.perf_counter() - t0) * 1000)
