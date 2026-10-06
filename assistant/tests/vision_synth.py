"""(dev) Sonde rapide de la classification d'activite sur des « ecrans » synthetiques dessines ici
(editeur de code sombre, document blanc, page web, discussion) et sur des photos (= video).

  python tests/vision_synth.py [DOSSIER_PHOTOS]
"""

from __future__ import annotations

import glob
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

W, H = 1920, 1080


def code_screen():
    from PIL import Image, ImageDraw

    im = Image.new("RGB", (W, H), (30, 30, 30))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 260, H], fill=(37, 37, 38))
    d.rectangle([0, 0, W, 34], fill=(50, 50, 50))
    cols = [(86, 156, 214), (206, 145, 120), (78, 201, 176), (220, 220, 170), (212, 212, 212)]
    for i in range(55):
        x = 300 + random.randint(0, 6) * 24
        y = 50 + i * 18
        for _ in range(random.randint(2, 7)):
            w = random.randint(30, 140)
            d.rectangle([x, y + 4, x + w, y + 12], fill=random.choice(cols))
            x += w + 10
    for i in range(30):
        d.rectangle([20, 50 + i * 22, 20 + random.randint(60, 200), 58 + i * 22], fill=(200, 200, 200))
    return im


def doc_screen():
    from PIL import Image, ImageDraw

    im = Image.new("RGB", (W, H), (230, 230, 230))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, W, 140], fill=(43, 87, 154))
    d.rectangle([0, 140, W, 180], fill=(245, 245, 245))
    d.rectangle([460, 200, 1460, H], fill="white")
    for i in range(38):
        d.rectangle([540, 260 + i * 21, 540 + random.randint(600, 840), 270 + i * 21], fill=(40, 40, 40))
    return im


def web_screen():
    from PIL import Image, ImageDraw

    im = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, W, 80], fill=(222, 225, 230))
    d.rectangle([200, 20, 1500, 60], fill="white")
    d.rectangle([0, 80, W, 160], fill=(25, 118, 210))
    for r in range(2):
        for c in range(4):
            x, y = 120 + c * 430, 220 + r * 420
            d.rectangle([x, y, x + 380, y + 230], fill=tuple(random.randint(60, 220) for _ in range(3)))
            for k in range(4):
                d.rectangle([x, y + 250 + k * 22, x + random.randint(200, 380), y + 262 + k * 22], fill=(60, 60, 60))
    return im


def chat_screen():
    from PIL import Image, ImageDraw

    im = Image.new("RGB", (W, H), (54, 57, 63))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 72, H], fill=(32, 34, 37))
    d.rectangle([72, 0, 312, H], fill=(47, 49, 54))
    for i in range(14):
        y = 60 + i * 66
        d.ellipse([340, y, 380, y + 40], fill=tuple(random.randint(80, 240) for _ in range(3)))
        d.rectangle([400, y + 2, 400 + random.randint(80, 160), y + 14], fill=(255, 255, 255))
        d.rectangle([400, y + 22, 400 + random.randint(300, 1100), y + 34], fill=(220, 221, 222))
    d.rectangle([340, H - 70, W - 40, H - 20], fill=(64, 68, 75))
    return im


def main() -> None:
    from PIL import Image

    from pompom_assist import vision

    random.seed(1)
    e = vision.SiglipEyes(gpu=True)
    cases = {"work_code": code_screen(), "work_docs": doc_screen(), "browse": web_screen(), "chat": chat_screen()}
    if len(sys.argv) > 1:
        for i, f in enumerate(sorted(glob.glob(sys.argv[1] + "/*.jpg"))[:4]):
            cases[f"video#{i}"] = Image.open(f).convert("RGB").resize((W, H))
    ok = 0
    for want, im in cases.items():
        p = e.class_probs(e.embed_images([im])[0], vision.ACTIVITIES, temperature=vision.ACT_TEMPERATURE)
        top = max(p, key=p.get)
        ok += top == want.split("#")[0]
        print(f"{want:10} -> {top:10} " + " ".join(f"{k}={v:.2f}" for k, v in sorted(p.items(), key=lambda kv: -kv[1])[:3]))
    print(f"{ok}/{len(cases)}")


if __name__ == "__main__":
    main()
