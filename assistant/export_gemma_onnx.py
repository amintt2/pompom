"""(DEVELOPPEMENT, dev\\gemma_venv avec PyTorch) Exporte EmbeddingGemma 2 (texte + image) en ONNX pour que le
service tourne SANS PyTorch (onnxruntime + numpy + tokenizers), puis verifie la parite avec PyTorch.

  dev\\gemma_venv\\Scripts\\python.exe export_gemma_onnx.py [--only text|vision|check] [--quant int8|fp32]

Ecrit dans models/gemma2/ :
  gemma2_embed.int8.npy + gemma2_embed_scale.npy   table d'embeddings du texte (262 144 x 512) en int8 par ligne
                                                   (deja multipliee par sqrt(512)) : lue a la main (numpy), 134 Mo
  backbone.<quant>.onnx      (w8 par defaut ; inputs_embeds [b,n,512], attention_mask [b,n]) -> jetons [b,n,768]
                             (24 couches bidirectionnelles + PLE + norme + projection 512->768)
  vision.<quant>.onnx        (pixel_values [1,P,768], position_ids [1,P,2]) -> jetons doux [1,P/9,512]
                             (tour de vision Gemma 4 + projection vers l'espace du texte)
  tokenizer.json             tokenizer (bibliotheque `tokenizers`)
  gemma2.json                identifiants speciaux, prefixes de tache, budget d'image, revision du modele
  LICENSE-NOTICE.txt         Apache-2.0 (google/embeddinggemma-2) + politique d'usage Gemma

NE PAS utiliser float16 (consigne de Google : l'activation deborde -> NaN) ; fp32 ou int8 (poids seulement,
activations fp32).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("OMP_NUM_THREADS", "4")
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
SRC = ROOT / "dev" / "embeddinggemma2"
OUT = ROOT / "models" / "gemma2"
OPSET = 18


def lowprio() -> None:
    from pompom_assist.lowprio import set_low_priority

    set_low_priority(idle=False)  # BELOW_NORMAL


def load_model():
    import torch
    from transformers import AutoConfig, AutoModel

    torch.set_num_threads(4)
    cfg = AutoConfig.from_pretrained(str(SRC))
    cfg.audio_config = None  # texte + image seulement (440 M)
    m = AutoModel.from_pretrained(str(SRC), config=cfg, dtype=torch.float32, attn_implementation="eager")
    return m.eval()


def export_text(m, quant: str) -> None:
    import numpy as np
    import torch
    import torch.nn as nn

    OUT.mkdir(parents=True, exist_ok=True)
    lm = m.language_model
    w = (lm.embed_tokens.weight.detach().float() * lm.embed_tokens.scalar_embed_scale).numpy()
    scale = np.abs(w).max(axis=1) / 127.0
    scale[scale == 0] = 1.0
    q = np.clip(np.round(w / scale[:, None]), -127, 127).astype(np.int8)
    np.save(OUT / "gemma2_embed.int8.npy", q)
    np.save(OUT / "gemma2_embed_scale.npy", scale.astype(np.float32))
    err = np.abs(q[:5000].astype(np.float32) * scale[:5000, None] - w[:5000]).max()
    print(f"table d'embeddings int8 : erreur max {err:.4f}")

    class Backbone(nn.Module):
        def __init__(self, lm):
            super().__init__()
            self.lm = lm

        def forward(self, inputs_embeds, attention_mask):
            return self.lm(inputs_embeds=inputs_embeds, attention_mask=attention_mask).last_hidden_state

    x = torch.randn(2, 24, 512)
    att = torch.ones(2, 24, dtype=torch.long)
    att[1, 18:] = 0
    tmp = OUT / "_backbone.fp32.onnx"
    with torch.no_grad():
        torch.onnx.export(Backbone(lm).eval(), (x, att), str(tmp), opset_version=OPSET, dynamo=False,
                          input_names=["inputs_embeds", "attention_mask"], output_names=["tokens"],
                          dynamic_axes={"inputs_embeds": {0: "b", 1: "n"}, "attention_mask": {0: "b", 1: "n"},
                                        "tokens": {0: "b", 1: "n"}})
    finish(tmp, OUT / "backbone", quant)


def export_vision(m, quant: str) -> None:
    import torch
    import torch.nn as nn

    class Vision(nn.Module):
        def __init__(self, m):
            super().__init__()
            self.tower, self.embed = m.vision_tower, m.embed_vision

        def forward(self, pixel_values, position_ids):
            h = self.tower(pixel_values=pixel_values, pixel_position_ids=position_ids).last_hidden_state
            return self.embed(inputs_embeds=h)

    from pompom_assist.gemma_onnx import patchify
    from PIL import Image

    pv, pos, _ = patchify(Image.new("RGB", (1280, 720), (90, 120, 160)), 70)
    tmp = OUT / "_vision.fp32.onnx"
    with torch.no_grad():
        torch.onnx.export(Vision(m).eval(), (torch.from_numpy(pv), torch.from_numpy(pos)), str(tmp), opset_version=OPSET,
                          dynamo=False, input_names=["pixel_values", "position_ids"], output_names=["soft_tokens"],
                          dynamic_axes={"pixel_values": {1: "p"}, "position_ids": {1: "p"}, "soft_tokens": {1: "s"}})
    finish(tmp, OUT / "vision", quant)


def finish(src: Path, stem: Path, quant: str) -> None:
    import onnx

    for old in stem.parent.glob(stem.name + ".*.onnx*"):
        old.unlink()
    if quant == "fp32":
        m = onnx.load(str(src))
        onnx.save(m, str(stem) + ".fp32.onnx", save_as_external_data=False)
    elif quant == "w8":
        # poids seulement en 8 bits par blocs de 32 (MatMulNBits), activations en int8 PAR BLOC : les valeurs
        # aberrantes de Gemma restent locales. Mesure : cosinus 0,9997 avec le fp32 (l'int8 dynamique : 0,71).
        from onnxruntime.quantization.matmul_nbits_quantizer import MatMulNBitsQuantizer

        q = MatMulNBitsQuantizer(onnx.load(str(src)), bits=8, block_size=32, is_symmetric=True, accuracy_level=4)
        q.process()
        q.model.save_model_to_file(str(stem) + ".w8.onnx", use_external_data_format=False)
    else:  # int8 dynamique : CASSE la qualite (cosinus 0,71 texte / 0,85 image), garde pour memoire
        from onnxruntime.quantization import QuantType, quantize_dynamic

        quantize_dynamic(str(src), str(stem) + ".int8.onnx", weight_type=QuantType.QInt8, op_types_to_quantize=["MatMul", "Gemm"],
                         per_channel=True)
    for f in src.parent.glob(src.name + "*"):
        f.unlink()
    for f in src.parent.glob("*.data"):
        if f.name.startswith("_"):
            f.unlink()


def write_meta(quant_text: str, quant_vision: str) -> None:
    src_info = json.loads((SRC / "SOURCE.json").read_text(encoding="utf-8")) if (SRC / "SOURCE.json").exists() else {}
    st = json.loads((SRC / "config_sentence_transformers.json").read_text(encoding="utf-8"))
    meta = {"model": "google/embeddinggemma-2", "revision": src_info.get("revision"), "license": "apache-2.0",
            "bos": 2, "eos": 1, "pad": 0, "boi": 255999, "eoi": 258882, "image_token": 258880,
            "prompts": st["prompts"], "dim": 768, "hidden": 512, "patch": 16, "pool": 3,
            "image_soft_tokens": 70, "quant": {"backbone": quant_text, "vision": quant_vision}}
    (OUT / "gemma2.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    shutil.copy(SRC / "tokenizer.json", OUT / "tokenizer.json")
    (OUT / "LICENSE-NOTICE.txt").write_text(
        "EmbeddingGemma 2 (google/embeddinggemma-2, revision %s) - Copyright Google LLC.\n"
        "Licence : Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0 ; carte du modele :\n"
        "https://ai.google.dev/gemma/docs/gemma_4_license). Usage soumis a la politique d'usage interdit de Gemma :\n"
        "https://ai.google.dev/gemma/prohibited_use_policy\n"
        "Fichiers derives (export ONNX / quantification int8) produits par export_gemma_onnx.py.\n" % src_info.get("revision"),
        encoding="utf-8")


def check(m, n_text: int = 40) -> dict:
    """Parite : notre chaine ONNX/numpy contre le modele PyTorch (sentence-transformers equivalent)."""
    import numpy as np
    import torch
    from PIL import Image

    from pompom_assist.gemma_onnx import GemmaEncoder, patchify

    enc = GemmaEncoder(gpu=False, threads=4)
    tok = enc.tok
    sys.path.insert(0, str(ROOT / "data"))
    import gen_eval_v2 as ge  # noqa: F401
    from pompom_assist.heads import describe_field

    rows = [json.loads(line) for line in open(ROOT / "data" / "test.jsonl", encoding="utf-8")][:n_text]
    texts = [enc.prefix + describe_field(r["field"]) for r in rows]
    from transformers import AutoTokenizer

    hf = AutoTokenizer.from_pretrained(str(SRC))
    tok_ok = sum(hf(t)["input_ids"] == enc.ids(t) for t in texts)
    print(f"tokenisation identique a transformers : {tok_ok}/{len(texts)} (ex. {hf(texts[0])['input_ids'][:4]}..."
          f"{hf(texts[0])['input_ids'][-2:]})")
    cos = []
    t_ms = []
    for t in texts:
        ids = enc.ids(t)
        with torch.no_grad():
            out = m.language_model(input_ids=torch.tensor([ids])).last_hidden_state[0].mean(0).numpy()
        ref = out / np.linalg.norm(out)
        t0 = time.perf_counter()
        got = enc.embed_texts([t])[0]
        t_ms.append((time.perf_counter() - t0) * 1000)
        cos.append(float(ref @ got))
    res = {"tokenization_identical": f"{tok_ok}/{len(texts)}", "text_cos_min": round(min(cos), 5), "text_cos_mean": round(float(np.mean(cos)), 5),
           "text_ms_p50": round(float(np.median(t_ms)), 1)}
    imgs = sorted((ROOT / "data" / "eval_v2" / "vision").glob("*.jpg"))[:4]
    ims = [Image.open(p).convert("RGB") for p in imgs] or [Image.new("RGB", (2560, 1440), (40, 80, 120))]
    # formats differents (fenetre au premier plan, zone de mouvement) : la tour de vision doit suivre P variable
    ims += [ims[0].crop((0, 0, 1700, 1300)), ims[0].crop((300, 200, 900, 1400)), ims[0].crop((0, 0, 853, 480))]
    vcos = []
    for im in ims:
        pv, pos, n_soft = patchify(im, enc.budget)
        ids = [enc.meta["bos"], enc.meta["boi"]] + [enc.meta["image_token"]] * n_soft + [enc.meta["eoi"], enc.meta["eos"]]
        with torch.no_grad():
            o = m(input_ids=torch.tensor([ids]), pixel_values=torch.from_numpy(pv), image_position_ids=torch.from_numpy(pos)).last_hidden_state[0].mean(0).numpy()
        ref = o / np.linalg.norm(o)
        got = enc.embed_images([im])[0]
        vcos.append(float(ref @ got))
    res.update({"image_cos_min": round(min(vcos), 5), "image_cos_mean": round(float(np.mean(vcos)), 5)})
    print(json.dumps(res, indent=1))
    (OUT / "parity.json").write_text(json.dumps(res, indent=1), encoding="utf-8")
    return res


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["text", "vision", "check"], default=None)
    ap.add_argument("--quant", default="w8", choices=["w8", "fp32", "int8"], help="backbone (texte + images)")
    ap.add_argument("--quant-vision", default="fp32", choices=["w8", "fp32", "int8"],
                    help="tour de vision (fp32 : le w8 est plus lent sur CPU et non accelere par DirectML)")
    a = ap.parse_args()
    lowprio()
    t0 = time.time()
    m = load_model()
    qv = a.quant_vision
    if a.only in (None, "text"):
        export_text(m, a.quant)
    if a.only in (None, "vision"):
        export_vision(m, qv)
    if a.only != "check":
        old = json.loads((OUT / "gemma2.json").read_text(encoding="utf-8"))["quant"] if (OUT / "gemma2.json").exists() else {}
        write_meta(a.quant if a.only in (None, "text") else old.get("backbone", a.quant),
                   qv if a.only in (None, "vision") else old.get("vision", qv))
    check(m)
    for f in sorted(OUT.iterdir()):
        print(f"{f.name:32} {f.stat().st_size / 2**20:8.1f} Mo")
    print(f"{time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
