"""EmbeddingGemma 2 (google/embeddinggemma-2, Apache-2.0) SANS PyTorch : onnxruntime + numpy + tokenizers.

Un seul encodeur pour le texte ET les images (meme espace de 768 dimensions) :
  texte  : jetons -> table d'embeddings int8 (numpy, memoire projetee) -> backbone ONNX -> moyenne -> norme
  image  : pixels -> carres 16x16 (budget de 70 « jetons doux » par defaut) -> tour de vision ONNX
           -> [BOS, debut d'image, jetons doux..., fin d'image, EOS] -> backbone ONNX -> moyenne -> norme
Les decisions sont de petites tetes numpy (np_heads.py) entrainees hors ligne (train_gemma_heads.py) sur
l'encodeur FIGE. Memes interfaces que la pile actuelle :
  GemmaHeads  ~ heads.OnnxHeads   (has, warm, ask(site, texte, allowed), choose(question, options, contexte))
  GemmaEyes   ~ vision.SiglipEyes (embed_images, embed_texts, class_probs, release_text_model)
Fichiers : models/gemma2/ (export_gemma_onnx.py).
"""

from __future__ import annotations

import json
import math
import threading
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
GEMMA_DIR = ROOT / "models" / "gemma2"
PATCH, POOL = 16, 3
SUPPORTED_BUDGETS = (70, 140, 280, 560, 1120)


# --------------------------------------------------------------------------- pretraitement image (= Gemma4ImageProcessor)
def target_size(h: int, w: int, budget: int) -> tuple[int, int]:
    max_patches = budget * POOL * POOL
    target_px = max_patches * PATCH * PATCH
    f = math.sqrt(target_px / (h * w))
    side = POOL * PATCH
    th = int(math.floor(f * h / side)) * side
    tw = int(math.floor(f * w / side)) * side
    max_side = (max_patches // POOL ** 2) * side
    if th == 0 and tw == 0:
        th = tw = side
    elif th == 0:
        th, tw = side, min(int(math.floor(w / h)) * side, max_side)
    elif tw == 0:
        tw, th = side, min(int(math.floor(h / w)) * side, max_side)
    return th, tw


def patchify(img, budget: int = 70):
    """PIL -> (pixel_values [1,P,768] float32 dans [0,1], position_ids [1,P,2] int64 (x,y), nb de jetons doux)."""
    from PIL import Image

    img = img.convert("RGB")
    th, tw = target_size(img.height, img.width, budget)
    if (th, tw) != (img.height, img.width):
        img = img.resize((tw, th), Image.BICUBIC)
    a = np.asarray(img, dtype=np.float32) * (1.0 / 255.0)  # H, W, C
    a = a.transpose(2, 0, 1)  # C, H, W
    c, h, w = a.shape
    ph, pw = h // PATCH, w // PATCH
    p = a.reshape(c, ph, PATCH, pw, PATCH).transpose(1, 3, 2, 4, 0).reshape(ph * pw, -1)
    gx, gy = np.meshgrid(np.arange(pw), np.arange(ph), indexing="xy")
    pos = np.stack([gx, gy], axis=-1).reshape(ph * pw, 2).astype(np.int64)
    return p[None].astype(np.float32), pos[None], (ph * pw) // (POOL * POOL)


# --------------------------------------------------------------------------- sessions
def _session(path: Path, gpu: bool, threads: int):
    import onnxruntime as ort

    so = ort.SessionOptions()
    so.intra_op_num_threads = max(1, threads)
    so.inter_op_num_threads = 1
    so.log_severity_level = 3
    so.enable_cpu_mem_arena = False
    if gpu:
        try:
            g = ort.SessionOptions()
            g.enable_mem_pattern = False
            g.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
            g.log_severity_level = 3
            s = ort.InferenceSession(str(path), g, providers=["DmlExecutionProvider", "CPUExecutionProvider"])
            if "DmlExecutionProvider" in s.get_providers():
                return s, "directml"
        except Exception:
            pass
    return ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"]), "cpu"


def _find(stem: str, folder: Path, prefer: str = "") -> Path:
    for q in ([prefer] if prefer else []) + ["w8", "fp32", "int8"]:
        p = folder / f"{stem}.{q}.onnx"
        if p.exists():
            return p
    raise FileNotFoundError(f"{stem}.*.onnx dans {folder}")


class GemmaEncoder:
    """Encodeur partage texte + image. La tour de vision n'est chargee qu'a la premiere image."""

    def __init__(self, gpu: bool = False, threads: int = 4, folder: Path = GEMMA_DIR, budget: int | None = None) -> None:
        from tokenizers import Tokenizer

        t0 = time.perf_counter()
        self.folder = folder
        self.meta = json.loads((folder / "gemma2.json").read_text(encoding="utf-8"))
        self.prefix = self.meta["prompts"]["Classification"]
        self.budget = budget or int(self.meta.get("image_soft_tokens", 70))
        self.tok = Tokenizer.from_file(str(folder / "tokenizer.json"))
        self.tok.no_truncation()
        self.tok.no_padding()
        # table d'embeddings int8 en memoire projetee : seules les lignes lues entrent en RAM
        self.emb_q = np.load(folder / "gemma2_embed.int8.npy", mmap_mode="r")
        self.emb_s = np.load(folder / "gemma2_embed_scale.npy")
        self.gpu, self.threads = gpu, threads
        self.backbone, self.backend = _session(_find("backbone", folder), gpu, threads)
        self._vision = None
        self.vision_backend = ""
        self.lock = threading.Lock()
        self.load_s = time.perf_counter() - t0

    # ------------------------------------------------------------------ texte
    def ids(self, text: str, max_len: int = 512) -> list[int]:
        ids = self.tok.encode(text, add_special_tokens=False).ids[: max_len - 2]
        return [self.meta["bos"]] + ids + [self.meta["eos"]]

    def lookup(self, ids) -> np.ndarray:
        ids = np.asarray(ids, dtype=np.int64)
        return self.emb_q[ids].astype(np.float32) * self.emb_s[ids][..., None]

    def run_backbone(self, embeds: list[np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
        """Liste de [n_i, 512] -> (jetons [b, n, 768], masque [b, n]) ; remplissage a droite."""
        n = max(e.shape[0] for e in embeds)
        x = np.zeros((len(embeds), n, embeds[0].shape[1]), np.float32)
        m = np.zeros((len(embeds), n), np.int64)
        for i, e in enumerate(embeds):
            x[i, : len(e)] = e
            m[i, : len(e)] = 1
        with self.lock:
            out = self.backbone.run(["tokens"], {"inputs_embeds": x, "attention_mask": m})[0]
        return out, m

    @staticmethod
    def pool(tokens: np.ndarray, mask: np.ndarray) -> np.ndarray:
        s = (tokens * mask[..., None]).sum(1) / np.maximum(1, mask.sum(1, keepdims=True))
        return s / np.linalg.norm(s, axis=1, keepdims=True)

    def embed_texts(self, texts: list[str], prefix: bool = False, batch: int = 16, return_tokens: bool = False):
        out, toks = [], []
        for i in range(0, len(texts), batch):
            chunk = texts[i:i + batch]
            embeds = [self.lookup(self.ids((self.prefix if prefix else "") + t)) for t in chunk]
            tk, m = self.run_backbone(embeds)
            out.append(self.pool(tk, m))
            if return_tokens:
                toks.extend(tk[j, : int(m[j].sum())] for j in range(len(chunk)))
        e = np.concatenate(out)
        return (e, toks) if return_tokens else e

    # ------------------------------------------------------------------ image
    def vision(self):
        if self._vision is None:
            self._vision, self.vision_backend = _session(_find("vision", self.folder), self.gpu, self.threads)
        return self._vision

    def image_tokens(self, img) -> np.ndarray:
        pv, pos, n_soft = patchify(img, self.budget)
        sess = self.vision()
        with self.lock:
            soft = sess.run(["soft_tokens"], {"pixel_values": pv, "position_ids": pos})[0]
        soft = soft.reshape(-1, soft.shape[-1])
        m = self.meta
        head = self.lookup([m["bos"], m["boi"]])
        tail = self.lookup([m["eoi"], m["eos"]])
        return np.concatenate([head, soft[:n_soft].astype(np.float32), tail])

    def embed_images(self, images: list) -> np.ndarray:
        seqs = [self.image_tokens(im) for im in images]
        out = []
        # meme taille (memes recadrages) -> un seul passage du backbone
        for i in range(0, len(seqs), 8):
            tk, m = self.run_backbone(seqs[i:i + 8])
            out.append(self.pool(tk, m))
        return np.concatenate(out)


_SHARED: dict = {}


def shared_encoder(gpu: bool, threads: int) -> GemmaEncoder:
    """Un seul encodeur par peripherique : texte et vision partagent le backbone (economie de RAM)."""
    key = bool(gpu)
    enc = _SHARED.get(key)
    if enc is None:
        enc = _SHARED[key] = GemmaEncoder(gpu=gpu, threads=threads)
    return enc


def release_shared(gpu: bool | None = None) -> None:
    for k in list(_SHARED):
        if gpu is None or k == bool(gpu):
            _SHARED.pop(k, None)


# --------------------------------------------------------------------------- decisions texte
class GemmaHeads:
    """Meme interface que heads.OnnxHeads. Tetes : models/gemma2/text_heads.npz."""

    def __init__(self, gpu: bool = False, threads: int = 4, folder: Path = GEMMA_DIR, encoder: GemmaEncoder | None = None) -> None:
        from .np_heads import load_heads

        t0 = time.perf_counter()
        self.enc = encoder or shared_encoder(gpu, threads)
        self.backend = self.enc.backend
        p = folder / "text_heads.npz"
        self.heads = load_heads(p) if p.exists() else {}
        self._last: dict[str, np.ndarray] = {}
        self.load_s = time.perf_counter() - t0

    def has(self, site: str) -> bool:
        return site in self.heads and site != "secret"

    def warm(self) -> None:
        self.enc.embed_texts(["app: x.exe | window: warm | control: edit | name: warm"], prefix=True)

    def _vec(self, head, text: str):
        if head.q is not None:
            e, toks = self.enc.embed_texts([text], prefix=True, return_tokens=True)
            return head.pool(toks[0])
        v = self._last.get(text)
        if v is None:  # meme description pour field_kind et la garde « secret » : un seul passage
            v = self.enc.embed_texts([text], prefix=True)[0]
            if len(self._last) > 16:
                self._last.clear()
            self._last[text] = v
        return v

    def is_secret(self, field: dict) -> bool:
        """Garde semantique (tete « secret ») : mots de passe / codes / cartes / cles meme sans mot-cle connu."""
        from .heads import describe_field

        h = self.heads.get("secret")
        if h is None:
            return False
        p = h.probs(self._vec(h, describe_field(field)))
        return float(p[h.labels.index("secret")]) >= float(h.meta.get("secret_threshold", 0.5))

    def ask(self, site: str, text: str, allowed: list[str] | None = None):
        from .heads import HeadAnswer
        from .np_heads import certainty

        t0 = time.perf_counter()
        h = self.heads[site]
        p = h.probs(self._vec(h, text))
        cert = certainty(p)
        probs = dict(zip(h.labels, p.tolist()))
        if allowed is not None:
            probs = {k: v for k, v in probs.items() if k in allowed}
            z = sum(probs.values()) or 1.0
            probs = {k: v / z for k, v in probs.items()}
        label = max(probs, key=probs.__getitem__)
        sure = h.threshold is None or cert >= h.threshold
        return HeadAnswer(label, probs[label], probs, (time.perf_counter() - t0) * 1000, False, cert, sure)

    def choose(self, question: str, options: list[str], context: str = ""):
        """Choix zero-shot par similarite (question + contexte contre chaque option), sans entrainement."""
        from .heads import HeadAnswer
        from .np_heads import softmax

        t0 = time.perf_counter()
        q = self.enc.embed_texts([f"{question} {context}".strip()], prefix=True)[0]
        o = self.enc.embed_texts(list(options), prefix=True)
        p = softmax((o @ q) * 30.0)
        probs = {k: float(v) for k, v in zip(options, p)}
        label = max(probs, key=probs.__getitem__)
        return HeadAnswer(label, probs[label], probs, (time.perf_counter() - t0) * 1000)


# --------------------------------------------------------------------------- vision
class GemmaEyes:
    """Meme interface que vision.SiglipEyes. Les phrases des classes sont encodees par le meme backbone."""

    def __init__(self, gpu: bool = False, threads: int = 2, folder: Path = GEMMA_DIR, encoder: GemmaEncoder | None = None,
                 use_head: bool = True) -> None:
        t0 = time.perf_counter()
        self.enc = encoder or shared_encoder(gpu, threads)
        self.enc.vision()
        self.backend = self.enc.vision_backend
        self.dim = 768
        self.logit_scale = float(self.enc.meta.get("zs_scale", 50.0))
        self._cache: dict[str, np.ndarray] = {}
        p = folder / "vision_heads.npz"
        if p.exists():
            from .np_heads import load_heads

            self.heads = load_heads(p)
        else:
            self.heads = {}
        # lu par VisionWatcher._classify : tete d'activite sur le plein ecran (sinon zero-shot)
        self.activity_head = self.heads.get("activity:full") if use_head else None
        self.activity_head_fg = self.heads.get("activity:full+fg") if use_head else None
        self.load_s = time.perf_counter() - t0

    def embed_texts(self, texts: list[str]) -> np.ndarray:
        todo = [t for t in texts if t not in self._cache]
        if todo:
            for t, v in zip(todo, self.enc.embed_texts(todo, prefix=True)):
                self._cache[t] = v
        return np.stack([self._cache[t] for t in texts])

    def release_text_model(self) -> None:
        pass  # le backbone sert aussi aux images

    def embed_images(self, images: list) -> np.ndarray:
        return self.enc.embed_images(images)

    def class_probs(self, img_emb: np.ndarray, classes: dict[str, list[str]], temperature: float = 1.0) -> dict[str, float]:
        names = list(classes)
        cent = []
        for n in names:
            e = self.embed_texts(classes[n]).mean(0)
            cent.append(e / np.linalg.norm(e))
        logits = self.logit_scale * (np.stack(cent) @ img_emb) / temperature
        logits -= logits.max()
        p = np.exp(logits)
        p /= p.sum()
        return {n: float(v) for n, v in zip(names, p)}
