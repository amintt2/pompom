"""(Environnement de DEVELOPPEMENT, avec PyTorch) Exporte tout ce dont le service a besoin en ONNX, pour
que l'installation normale n'ait PAS besoin de PyTorch, de transformers, de laya ni de stuntd.

  dev.venvScriptspython.exe export_onnx.py [--only laya|siglip]

Ecrit dans models/ :
  laya_encoder.mixed.onnx     encodeur Laya multilingual (mmBERT-base) : embeddings int8 + reste fp16
  head_field_kind.fp16.onnx   tete stuntd field_kind      } meme graphe, poids differents :
  head_text_kind.fp16.onnx    tete stuntd text_kind       } (cache, attention, marqueurs, type) -> logits
  head_base.fp16.onnx         tete d'origine de Laya (questions zero-shot de decide())
  heads.json                  etiquettes, temperature, seuil, mise en page de chaque site + config Laya
  laya_tokenizer.json         tokenizer (bibliotheque `tokenizers`, sans transformers)
  siglip_vision.fp16.onnx     tour de vision SigLIP base (fp16)
  siglip_prompts.npz          phrases des classes de vision deja encodees (le modele de texte n'est pas livre)
  siglip_logit.json           echelle / biais des logits SigLIP
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
OUT = ROOT / "models"
LAYA = ROOT / "dev" / "laya_model" / "multilingual"
HEADS = ROOT / "dev" / "heads"
SIGLIP = ROOT / "dev" / "siglip"
OPSET = 17


def export_laya() -> None:
    import laya
    import torch
    import torch.nn as nn
    from safetensors.torch import load_file
    from stuntd.train.artifacts import load_model

    torch.backends.mha.set_fastpath_enabled(False)  # le chemin rapide natif ne s exporte pas
    agent = laya.Agent(str(LAYA), device="cpu")
    model = agent.model.eval()

    class Enc(nn.Module):
        def __init__(self, enc):
            super().__init__()
            self.enc = enc

        def forward(self, input_ids, attention_mask):
            return self.enc(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state

    class Head(nn.Module):
        """Meme calcul que stuntd (trainer._head_forward) / laya DecisionModel.forward apres l'encodeur."""

        def __init__(self, m):
            super().__init__()
            self.type_emb, self.head, self.scorer = m.type_emb, m.head, m.scorer

        def forward(self, hidden, attention_mask, marker_pos, marker_mask, qtype):
            h = hidden + self.type_emb(qtype)[:, None, :]
            pad = attention_mask == 0
            for layer in self.head.layers:
                h = layer(h, src_key_padding_mask=pad)
            idx = marker_pos.clamp(min=0)[:, :, None].expand(-1, -1, h.size(-1))
            m = torch.gather(h, 1, idx)
            logits = self.scorer(m).squeeze(-1).float()
            return logits.masked_fill(~marker_mask, -1e4)

    OUT.mkdir(exist_ok=True)
    ids = torch.tensor([[agent.tok.cls_token_id] + [100] * 30 + [agent.tok.sep_token_id]])
    att = torch.ones_like(ids)
    tmp = OUT / "_tmp"
    tmp.mkdir(exist_ok=True)
    with torch.no_grad():
        torch.onnx.export(Enc(model.encoder), (ids, att), str(tmp / "enc.onnx"), opset_version=OPSET,
                          input_names=["input_ids", "attention_mask"], output_names=["hidden"],
                          dynamic_axes={"input_ids": {0: "b", 1: "n"}, "attention_mask": {0: "b", 1: "n"},
                                        "hidden": {0: "b", 1: "n"}})
    hidden = torch.zeros((1, 32, model.encoder.config.hidden_size))
    mpos = torch.tensor([[3, 6, 9]])
    mmask = torch.ones_like(mpos, dtype=torch.bool)
    qt = torch.tensor([0])
    pristine = {k: v.clone() for k, v in model.state_dict().items() if k.startswith(("head.", "scorer.", "type_emb."))}
    sites = {"base": None}
    for site in ("field_kind", "text_kind"):
        if (HEADS / site / "head.safetensors").exists():
            sites[site] = HEADS / site
    meta = {"laya": {k: agent.cfg[k] for k in ("max_len", "head_max_len")},
            "temperature_by_options": agent.cfg.get("temperature_by_options", {}),
            "temperature": agent.cfg.get("temperature", [1, 1, 1]),
            "special": {"cls": agent.tok.cls_token_id, "sep": agent.tok.sep_token_id, "mask": agent.tok.mask_token_id,
                        "pad": agent.tok.pad_token_id, "mask_token": agent.tok.mask_token},
            "sites": {}}
    for site, folder in sites.items():
        model.load_state_dict(pristine, strict=False)
        if folder is not None:
            w = load_file(str(folder / "head.safetensors"))
            model.load_state_dict({k: v.float() for k, v in w.items()}, strict=False)
            sm = load_model(HEADS, site)
            meta["sites"][site] = {"labels": sm.labels, "field": sm.field, "temperature": sm.temperature,
                                   "threshold": sm.threshold, "max_len": sm.max_len, "head_max_len": sm.head_max_len,
                                   "spaced_labels": sm.spaced_labels, "agreement": sm.agreement,
                                   "coverage": sm.coverage, "n_train": sm.n_train}
        with torch.no_grad():
            torch.onnx.export(Head(model).eval(), (hidden, torch.ones((1, 32), dtype=torch.long), mpos, mmask, qt),
                              str(tmp / f"head_{site}.onnx"), opset_version=OPSET,
                              input_names=["hidden", "attention_mask", "marker_pos", "marker_mask", "qtype"],
                              output_names=["logits"],
                              dynamic_axes={"hidden": {0: "b", 1: "n"}, "attention_mask": {0: "b", 1: "n"},
                                            "marker_pos": {0: "b", 1: "k"}, "marker_mask": {0: "b", 1: "k"},
                                            "qtype": {0: "b"}, "logits": {0: "b", 1: "k"}})
    (OUT / "heads.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    shutil.copy(LAYA / "tokenizer" / "tokenizer.json", OUT / "laya_tokenizer.json")
    finish(tmp / "enc.onnx", OUT / "laya_encoder", "mixed")
    for site in sites:
        finish(tmp / f"head_{site}.onnx", OUT / f"head_{site}", "fp16")
    shutil.rmtree(tmp)


def finish(src: Path, dst_stem: Path, fmt: str) -> Path:
    """Ecrit UN seul format par modele :
    - "mixed" : table d'embeddings (Gather) en int8 + toutes les autres matrices en fp16. Mesure : le
      tout-int8 casse la tete (0,939 -> 0,861 en hybride, 0,11 tete seule) ; l'embedding int8 seul ne coute rien.
    - "fp16"  : tout en fp16 (petites tetes) ; "fp32" : copie."""
    import onnx

    out = Path(str(dst_stem) + f".{fmt}.onnx")
    if fmt == "fp32":
        shutil.copy(src, out)
        return out
    from onnxruntime.transformers.float16 import convert_float_to_float16

    if fmt == "mixed":
        from onnxruntime.quantization import QuantType, quantize_dynamic

        tmp = Path(str(dst_stem) + "._g.onnx")
        quantize_dynamic(str(src), str(tmp), weight_type=QuantType.QInt8, op_types_to_quantize=["Gather"])
        m = convert_float_to_float16(onnx.load(str(tmp)), keep_io_types=True,
                                     op_block_list=["DequantizeLinear", "Gather", "DynamicQuantizeLinear"])
        tmp.unlink()
    else:
        m = convert_float_to_float16(onnx.load(str(src)), keep_io_types=True)
    onnx.save(m, str(out))
    return out


def fetch_siglip_logit() -> None:
    """Echelle et biais des logits SigLIP (2 nombres), lus par requetes HTTP partielles dans les poids
    google/siglip-base-patch16-224 (les exports ONNX ne les contiennent pas)."""
    import struct
    import urllib.request as u

    import numpy as np

    dst = SIGLIP / "logit_params.json"
    if dst.exists():
        return
    url = "https://huggingface.co/google/siglip-base-patch16-224/resolve/main/model.safetensors"
    n = struct.unpack("<Q", u.urlopen(u.Request(url, headers={"Range": "bytes=0-7"})).read())[0]
    h = json.loads(u.urlopen(u.Request(url, headers={"Range": f"bytes=8-{7 + n}"})).read())
    out = {}
    for k in ("logit_scale", "logit_bias"):
        a, b = h[k]["data_offsets"]
        raw = u.urlopen(u.Request(url, headers={"Range": f"bytes={8 + n + a}-{8 + n + b - 1}"})).read()
        out[k] = np.frombuffer(raw, dtype=np.float32).astype(float).tolist()
    dst.write_text(json.dumps(out), encoding="utf-8")


def export_siglip() -> None:
    fetch_siglip_logit()
    import numpy as np
    import onnxruntime as ort
    from tokenizers import Tokenizer

    from pompom_assist import vision

    OUT.mkdir(exist_ok=True)
    # fp16 tel que publie par Xenova : exact sur DirectML ; sur CPU il faut ORT_ENABLE_BASIC (voir laya_onnx.session)
    shutil.copy(SIGLIP / "onnx" / "vision_model_fp16.onnx", OUT / "siglip_vision.fp16.onnx")
    # phrases encodees une fois avec le modele de texte complet (fp32), qui n'est PAS livre
    text = ort.InferenceSession(str(SIGLIP / "onnx" / "text_model.onnx"), providers=["CPUExecutionProvider"])
    tok = Tokenizer.from_file(str(SIGLIP / "tokenizer.json"))
    texts = sorted({t for v in vision.ACTIVITIES.values() for t in v} | set(vision.VIDEO_PROMPTS) | set(vision.UI_PROMPTS))
    ids = np.ones((len(texts), 64), dtype=np.int64)
    for i, t in enumerate(texts):
        e = tok.encode(vision._canon(t)).ids[:64]
        ids[i, : len(e)] = e
    emb = text.run(["pooler_output"], {"input_ids": ids})[0]
    emb = emb / np.linalg.norm(emb, axis=1, keepdims=True)
    np.savez_compressed(OUT / "siglip_prompts.npz", texts=np.array(texts), emb=emb.astype(np.float32))
    shutil.copy(SIGLIP / "logit_params.json", OUT / "siglip_logit.json")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["laya", "siglip"], default=None)
    a = ap.parse_args()
    if a.only in (None, "laya"):
        export_laya()
    if a.only in (None, "siglip"):
        export_siglip()
    for f in sorted(OUT.iterdir()):
        print(f"{f.name:32} {f.stat().st_size / 2**20:8.1f} Mo")


if __name__ == "__main__":
    main()
