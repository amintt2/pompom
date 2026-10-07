"""Ecrans de bureau SYNTHETIQUES 2560x1440 (vision : activite + rectangle video), dessines ici avec PIL/numpy.

  python data/gen_screens.py --split eval  --n 360    -> data/eval_v2/vision/   (jeu FIGE, JPEG)
  python data/gen_screens.py --split train --n 600    -> dev/vision_train/      (entrainement des tetes, jamais l'eval)
  python data/gen_screens.py --preview 12             -> planche de controle (dossier temporaire)

Rien n'est copie : chrome d'applis (navigateur + page type YouTube, editeur de code sombre/clair, terminal,
traitement de texte, tableur, diapos, lecteur PDF, discussion type Discord/Slack/WhatsApp, boite mail,
explorateur, reglages, bureau), images « naturelles » procedurales (paysages fBm, ville de nuit, fonds
marins, personne qui parle, sport, dessin anime, diapos de cours) et jeux procedururaux (FPS/TPS en
perspective, plateforme pixel-art, strategie vue de dessus, course) avec ATH. Polices Windows locales.

Chaque scenario = 5 captures a 1 s d'intervalle (comme VisionWatcher) : on enregistre la DERNIERE en JPEG
pleine resolution + les 5 vignettes 96x54 en niveaux de gris de la carte de mouvement (calculees exactement
comme vision.py, a partir des images pleine resolution AVANT compression). Etiquettes : classe d'activite
(application au premier plan), rectangle video [x, y, w, h] ou null, type de video (moving / static / talking),
plein ecran, processus et rectangle de la fenetre au premier plan.

Styles « tenus a l'ecart » : la variante de mise en page n°2 de chaque appli (lecteur centre type Vimeo,
JetBrains, lecteur PDF, WhatsApp, encyclopedie, reglages, jeu de course...) n'apparait QUE dans l'eval
(held_out_style = true) : mesure la generalisation a une mise en page jamais vue par les tetes entrainees.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
W, H = 2560, 1440
MW, MH = 96, 54  # carte de mouvement (vision.MOTION_W/H)
N_FRAMES = 5
CLASSES = ["game", "video", "work_code", "work_docs", "browse", "chat", "other"]
FONT_DIR = Path("C:/Windows/Fonts")
FONTS = {"ui": "segoeui.ttf", "uib": "segoeuib.ttf", "uisb": "seguisb.ttf", "mono": "consola.ttf",
         "monob": "consolab.ttf", "serif": "georgia.ttf", "serifb": "georgiab.ttf", "doc": "calibri.ttf",
         "docb": "calibrib.ttf", "arial": "arial.ttf", "arialb": "arialbd.ttf", "comic": "comicbd.ttf"}


@lru_cache(maxsize=512)
def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(str(FONT_DIR / FONTS.get(name, name)), max(6, int(size)))
    except OSError:
        return ImageFont.load_default()


# ======================================================================================= mots
FR = ("le la les un une des du de et en pour avec sans sur dans par plus tres bien tout faire voir projet "
      "maison ville jour nuit temps monde vie travail equipe semaine reunion budget rapport idee resultat "
      "nouveau grand petit premier dernier simple rapide facile important possible public ecole famille "
      "musique film serie jeu vacances voyage cuisine recette sante sport match saison annonce prix offre "
      "commande livraison client service question reponse message photo video article page site lecture").split()
EN = ("the a of and to in for with on at by from about new best how why what this that your our team "
      "project update report review guide tips news world game music video season match price deal order "
      "delivery account support release version feature design code data model build test launch city "
      "travel food recipe health science space history market people life work home school story").split()
NAMES = ["Léa", "Hugo", "Inès", "Nathan", "Chloé", "Louis", "Manon", "Jules", "Camille", "Arthur", "Zoé", "Noah",
         "Sarah", "Adam", "Emma", "Lucas", "Jade", "Malik", "Yanis", "Clara"]
CODE = {
    "py": ["import os", "import json", "from pathlib import Path", "", "class Inventory:",
           "    def __init__(self, size: int = 20) -> None:", "        self.items = []", "        self.size = size", "",
           "    def add(self, item):", "        if len(self.items) >= self.size:", "            return False",
           "        self.items.append(item)  # nouvel objet", "        return True", "",
           "def load(path: str) -> dict:", "    with open(path, encoding=\"utf-8\") as f:", "        return json.load(f)",
           "", "for i in range(10):", "    print(f\"slot {i}: {inv.items[i]}\")", "results = [x * 2 for x in data if x > 0]"],
    "js": ["import { useState } from 'react';", "", "export function Player({ name, score }) {",
           "  const [hp, setHp] = useState(100);", "  // TODO: animations", "  useEffect(() => {",
           "    const id = setInterval(() => setHp(h => h - 1), 1000);", "    return () => clearInterval(id);",
           "  }, []);", "  return <div className=\"player\">{name}: {score}</div>;", "}", "",
           "const api = await fetch('/api/scores?limit=20');", "const data = await api.json();",
           "console.log(data.map(d => d.name));"],
    "rs": ["use std::collections::HashMap;", "", "#[derive(Debug, Clone)]", "pub struct Tile {", "    pub x: i32,",
           "    pub y: i32,", "    pub kind: TileKind,", "}", "", "impl World {",
           "    pub fn new(w: usize, h: usize) -> Self {", "        let tiles = vec![Tile::default(); w * h];",
           "        Self { w, h, tiles }", "    }", "}", "fn main() {", "    let mut world = World::new(64, 64);",
           "    println!(\"{:?}\", world.get(3, 4));", "}"],
    "gd": ["extends CharacterBody2D", "", "@export var speed := 220.0", "var jumping := false", "",
           "func _physics_process(delta: float) -> void:", "\tvar dir := Input.get_axis(\"left\", \"right\")",
           "\tvelocity.x = dir * speed", "\tif is_on_floor() and Input.is_action_just_pressed(\"jump\"):",
           "\t\tvelocity.y = -400.0", "\tmove_and_slide()", "", "func _on_coin_collected(value: int) -> void:",
           "\tscore += value", "\t$HUD.update_score(score)"],
    "cs": ["using System;", "using System.Linq;", "", "namespace Shop.Api", "{", "    public class OrderService",
           "    {", "        private readonly IRepository _repo;", "", "        public decimal Total(Order o)",
           "        {", "            return o.Lines.Sum(l => l.Price * l.Qty);", "        }", "    }", "}"],
}
KW = set("import from class def return if for in with as while else elif try except const let var function export "
         "use pub struct impl fn mut self Self extends func and not or using namespace public private readonly new "
         "await async true false True False None null".split())
TERM = ["PS C:\\Users\\lea\\projet> git status", "On branch main", "Your branch is up to date with 'origin/main'.",
        "Changes not staged for commit:", "        modified:   src/player.gd", "        modified:   README.md",
        "PS C:\\Users\\lea\\projet> python -m pytest -q", "........................................  [100%]",
        "42 passed in 3.71s", "PS C:\\Users\\lea\\projet> npm run build", "> app@1.4.0 build", "> vite build",
        "vite v6.2.1 building for production...", "✓ 312 modules transformed.", "dist/index.html   0.46 kB",
        "dist/assets/index-4f2a.js   148.20 kB │ gzip: 47.91 kB", "✓ built in 2.84s",
        "PS C:\\Users\\lea\\projet> cargo run --release", "   Compiling world v0.3.0", "    Finished release [optimized]",
        "     Running `target\\release\\world.exe`", "PS C:\\Users\\lea\\projet> ls", "    Directory: C:\\Users\\lea\\projet",
        "Mode   LastWriteTime   Length Name", "d----  07/10/2026 10:12        src", "-a---  07/10/2026 09:58   1204 README.md"]
CHAT = ["salut ! tu as vu le nouveau trailer ?", "oui trop bien, ça sort quand ?", "on lance une partie ce soir ?",
        "je suis dispo à partir de 21h", "quelqu'un a le lien de la réunion ?", "merci pour le doc 🙏",
        "c'est bon j'ai poussé le correctif", "photo du chat 😺", "haha", "ok ça marche", "lol non",
        "rdv devant la gare à 18h30", "tu peux relire ma PR ?", "le serveur est de nouveau en ligne",
        "gg à tous pour hier", "qui ramène les boissons ?", "je regarde ça demain matin"]


def words(rng, n, lang=None):
    pool = FR if (lang or rng.choice(["fr", "en"])) == "fr" else EN
    return " ".join(rng.choice(pool) for _ in range(n))


def sentence(rng, a=4, b=12, lang=None):
    s = words(rng, rng.randint(a, b), lang)
    return s[:1].upper() + s[1:]


# ======================================================================================= images naturelles
def fbm(rng: np.random.Generator, h: int, w: int, octaves: int = 5, base: int = 3) -> np.ndarray:
    acc = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        gh, gw = base * 2 ** o + 1, int(base * 2 ** o * w / max(1, h)) + 2
        g = rng.random((gh, gw)).astype(np.float32)
        acc += amp * np.asarray(Image.fromarray(g, "F").resize((w, h), Image.BILINEAR))
        tot += amp
        amp *= 0.5
    acc /= tot
    return (acc - acc.min()) / (np.ptp(acc) + 1e-6)


def ridge(rng: np.random.Generator, w: int, octaves: int = 6) -> np.ndarray:
    acc = np.zeros(w, np.float32)
    amp = 1.0
    for o in range(octaves):
        n = 2 + 2 ** (o + 1)
        g = rng.random(n).astype(np.float32)
        acc += amp * np.interp(np.linspace(0, n - 1, w), np.arange(n), g)
        amp *= 0.5
    return (acc - acc.min()) / (np.ptp(acc) + 1e-6)


SKIES = [((122, 170, 230), (40, 90, 180)), ((250, 170, 100), (90, 60, 140)), ((190, 196, 205), (120, 130, 145)),
         ((255, 210, 150), (60, 120, 200)), ((30, 40, 80), (5, 8, 25)), ((170, 220, 240), (60, 150, 210))]


def lerp(a, b, t):
    return np.asarray(a, np.float32) * (1 - t) + np.asarray(b, np.float32) * t


def landscape(seed: int, w: int, h: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    top, hor = SKIES[rng.integers(len(SKIES))]
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    img = lerp(hor, top, 1 - t) * np.ones((1, w, 1), np.float32)
    clouds = fbm(rng, h, w, 6, 2)
    cm = np.clip((clouds - 0.55) * 3, 0, 1)[..., None] * (1 - t * 1.4).clip(0, 1)
    img = img * (1 - cm * 0.8) + 245 * cm * 0.8
    if rng.random() < 0.5:
        sx, sy, r = rng.uniform(0.1, 0.9) * w, rng.uniform(0.15, 0.45) * h, rng.uniform(0.03, 0.06) * w
        yy, xx = np.mgrid[0:h, 0:w]
        d = np.sqrt((xx - sx) ** 2 + (yy - sy) ** 2)
        glow = np.clip(1 - d / (r * 4), 0, 1) ** 2
        img = img + glow[..., None] * np.array([90, 70, 30]) + (d < r)[..., None] * 120
    yy = np.arange(h)[:, None]
    base_cols = [(70, 90, 120), (55, 80, 70), (40, 70, 45), (30, 55, 30), (90, 80, 60)]
    n_layers = int(rng.integers(2, 5))
    for i in range(n_layers):
        r = ridge(rng, w)
        y0 = h * (0.35 + 0.12 * i) + (r - 0.5) * h * (0.35 - 0.06 * i)
        mask = (yy > y0[None, :]).astype(np.float32)
        haze = 0.65 - 0.18 * i
        col = lerp(base_cols[rng.integers(len(base_cols))], hor, max(0.0, haze))
        tex = fbm(rng, h, w, 4, 6)[..., None]
        layer = col * (0.8 + 0.4 * tex)
        img = img * (1 - mask[..., None]) + layer * mask[..., None]
    if rng.random() < 0.4:  # eau au premier plan, reflet du ciel
        wy = int(h * rng.uniform(0.72, 0.85))
        refl = img[wy - (h - wy):wy][::-1] if wy - (h - wy) >= 0 else img[:h - wy][::-1]
        n = min(len(refl), h - wy)
        waves = fbm(rng, n, w, 3, 8)[..., None]
        img[wy:wy + n] = refl[:n] * (0.55 + 0.25 * waves) + np.array([10, 30, 50])
    return np.clip(img, 0, 255)


def city(seed: int, w: int, h: int) -> np.ndarray:
    rng = random.Random(seed)
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        c = lerp((10, 14, 40), (60, 40, 90), y / h)
        d.line([(0, y), (w, y)], fill=tuple(int(v) for v in c))
    x = 0
    while x < w:
        bw, bh = rng.randint(w // 30, w // 10), rng.randint(h // 5, int(h * 0.8))
        col = (rng.randint(15, 40),) * 3
        d.rectangle([x, h - bh, x + bw, h], fill=col)
        for wy in range(h - bh + 8, h - 6, max(6, h // 60)):
            for wx in range(x + 4, x + bw - 4, max(5, w // 140)):
                if rng.random() < 0.35:
                    d.rectangle([wx, wy, wx + max(2, w // 300), wy + max(2, h // 160)],
                                fill=(255, rng.randint(190, 235), rng.randint(90, 160)))
        x += bw + rng.randint(0, w // 80)
    bok = Image.new("RGB", (w, h))
    bd = ImageDraw.Draw(bok)
    for _ in range(40):
        cx, cy, r = rng.randint(0, w), rng.randint(h // 2, h), rng.randint(h // 40, h // 12)
        bd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(rng.randint(150, 255), rng.randint(80, 200), rng.randint(40, 150)))
    bok = bok.filter(ImageFilter.GaussianBlur(max(2, h // 60)))
    return np.clip(np.asarray(im, np.float32) + np.asarray(bok, np.float32) * 0.5, 0, 255)


def underwater(seed: int, w: int, h: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    img = lerp((40, 160, 190), (5, 30, 70), t) * np.ones((1, w, 1), np.float32)
    rays = fbm(rng, h, w, 3, 2)
    img += (np.clip(rays - 0.5, 0, 1) * 80 * (1 - t[..., 0]))[..., None]
    sand = fbm(rng, h, w, 4, 5)
    img = np.where((np.arange(h)[:, None, None] > h * (0.8 + 0.1 * sand[..., None])), lerp((150, 140, 100), (90, 80, 60), sand[..., None]), img)
    return np.clip(img, 0, 255)


def to_img(a: np.ndarray) -> Image.Image:
    return Image.fromarray(a.astype(np.uint8), "RGB")


class Clip:
    """Une « video » : base fixe (plus grande que le cadre) + panoramique + objets qui bougent + coupe."""

    KINDS_MOVING = ["landscape", "city", "underwater", "sports", "cartoon", "gameplay", "talking", "landscape2"]

    def __init__(self, seed: int, kind: str, motion: str = "moving") -> None:
        self.seed, self.kind, self.motion = seed, kind, motion
        self.rng = random.Random(seed)
        self.rw, self.rh = 768, 432
        self._base = {}
        self.cut_at = self.rng.choice([None, 2, 3]) if motion == "moving" else None
        # 1 capture/s : en une seconde une vraie video bouge beaucoup (panoramique de 5 a 15 % du cadre, objets,
        # coupes). Mesure sur la premiere version (panoramique 2 %) : la carte de mouvement ne voyait presque rien.
        self.pan = (self.rng.choice([-1, 1]) * self.rng.uniform(35, 110), self.rng.uniform(-14, 14))

    def base(self, scene: int) -> Image.Image:
        if scene not in self._base:
            s = self.seed * 7 + scene
            bw, bh = int(self.rw * 1.6), int(self.rh * 1.3)
            k = self.kind
            if k in ("landscape", "landscape2"):
                im = to_img(landscape(s, bw, bh))
            elif k == "city":
                im = to_img(city(s, bw, bh))
            elif k == "underwater":
                im = to_img(underwater(s, bw, bh))
            elif k == "sports":
                im = sports_field(s, bw, bh)
            elif k == "cartoon":
                im = cartoon_bg(s, bw, bh)
            elif k == "talking":
                im = room_bg(s, bw, bh)
            elif k == "slides":
                im = slide(s, bw, bh)
            elif k == "gameplay":
                im = game_view(s, "tps", bw, bh, 0, hud=True).resize((bw, bh))
            else:
                im = to_img(landscape(s, bw, bh))
            self._base[scene] = im
        return self._base[scene]

    def frame(self, k: int, w: int, h: int) -> Image.Image:
        if self.motion == "static":
            k = 0
        scene = 1 if (self.cut_at is not None and k >= self.cut_at) else 0
        b = self.base(scene)
        if self.kind == "gameplay" and self.motion != "static":
            im = game_view(self.seed * 7 + scene, "tps", self.rw, self.rh, k, hud=True)
        else:
            x0 = int(self.rw * 0.02) if self.pan[0] > 0 else int(self.rw * 0.58)
            dx = int(x0 + self.pan[0] * k) if self.motion == "moving" else x0
            dy = int(self.rh * 0.15 + self.pan[1] * k) if self.motion == "moving" else int(self.rh * 0.15)
            dx = max(0, min(b.width - self.rw, dx))
            dy = max(0, min(b.height - self.rh, dy))
            im = b.crop((dx, dy, dx + self.rw, dy + self.rh)).copy()
            d = ImageDraw.Draw(im)
            r = random.Random(self.seed * 31 + scene)
            if self.kind == "talking":
                person(d, r, self.rw, self.rh, k if self.motion != "static" else 0)
            elif self.kind == "sports":
                for i in range(14):
                    px = (r.uniform(0.1, 0.9) * self.rw + (k * r.uniform(-45, 45) if self.motion == "moving" else 0)) % self.rw
                    py = r.uniform(0.35, 0.9) * self.rh + (k * r.uniform(-15, 15) if self.motion == "moving" else 0)
                    c = (220, 40, 40) if i % 2 else (240, 240, 250)
                    d.ellipse([px - 5, py - 12, px + 5, py + 2], fill=c)
                    d.ellipse([px - 4, py - 20, px + 4, py - 12], fill=(220, 180, 150))
                d.rectangle([12, 12, 190, 40], fill=(20, 30, 60))
                d.text((20, 14), f"PAR 1 - 0 LYO  {23 + k // 2}:{(41 + k) % 60:02d}", font=font("arialb", 16), fill="white")
            elif self.kind in ("landscape", "landscape2", "underwater", "cartoon", "city"):
                for i in range(r.randint(1, 4)):  # oiseaux / poissons / personnages
                    ox = (r.uniform(0, 1) * self.rw + k * r.uniform(30, 90) * (1 if self.motion == "moving" else 0)) % self.rw
                    oy = r.uniform(0.2, 0.8) * self.rh
                    sz = r.uniform(10, 40)
                    col = (r.randint(0, 255), r.randint(0, 255), r.randint(0, 255)) if self.kind != "landscape" else (30, 30, 30)
                    d.ellipse([ox - sz, oy - sz / 2, ox + sz, oy + sz / 2], fill=col)
        im = im.resize((max(8, w), max(8, h)), Image.BICUBIC)
        if self.kind not in ("slides", "cartoon"):
            im = im.filter(ImageFilter.GaussianBlur(0.6))
        return im


def sports_field(seed, w, h):
    rng = random.Random(seed)
    im = Image.new("RGB", (w, h), (40, 120, 50))
    d = ImageDraw.Draw(im)
    hor = int(h * 0.25)
    d.rectangle([0, 0, w, hor], fill=(60, 60, 70))
    for i in range(0, w, 6):
        d.line([(i, hor - rng.randint(5, 40)), (i, hor)], fill=(rng.randint(80, 200),) * 3, width=4)
    for i in range(10):
        y0 = hor + (h - hor) * i / 10
        d.rectangle([0, y0, w, y0 + (h - hor) / 20], fill=(46, 135, 56))
    d.line([(w // 2, hor), (w // 2, h)], fill="white", width=3)
    d.ellipse([w // 2 - 90, h * 0.55 - 40, w // 2 + 90, h * 0.55 + 40], outline="white", width=3)
    return im


def cartoon_bg(seed, w, h):
    rng = random.Random(seed)
    im = Image.new("RGB", (w, h), (130, 200, 250))
    d = ImageDraw.Draw(im)
    for i in range(4):
        cx, r = rng.uniform(0, w), rng.uniform(h * 0.3, h * 0.6)
        d.ellipse([cx - r * 1.6, h * 0.65 - r * 0.5, cx + r * 1.6, h * 0.65 + r * 1.5],
                  fill=(rng.randint(60, 120), rng.randint(170, 220), rng.randint(60, 110)), outline=(20, 60, 20), width=4)
    for i in range(3):
        cx, cy = rng.uniform(0, w), rng.uniform(0, h * 0.3)
        for j in range(3):
            d.ellipse([cx + j * 30 - 40, cy - 20, cx + j * 30 + 40, cy + 25], fill="white")
    cx, cy = w * rng.uniform(0.3, 0.6), h * 0.62
    d.ellipse([cx - 60, cy - 80, cx + 60, cy + 60], fill=(250, 200, 60), outline="black", width=5)
    d.ellipse([cx - 30, cy - 50, cx - 8, cy - 20], fill="white", outline="black", width=3)
    d.ellipse([cx + 8, cy - 50, cx + 30, cy - 20], fill="white", outline="black", width=3)
    d.arc([cx - 30, cy - 10, cx + 30, cy + 30], 0, 180, fill="black", width=4)
    return im


def room_bg(seed, w, h):
    rng = random.Random(seed)
    im = Image.new("RGB", (w, h), tuple(rng.randint(150, 220) for _ in range(3)))
    d = ImageDraw.Draw(im)
    x = 0
    while x < w * 0.4:  # etagere
        bw = rng.randint(10, 26)
        d.rectangle([x + 20, h * 0.15, x + 20 + bw, h * 0.15 + rng.randint(60, 110)], fill=tuple(rng.randint(40, 200) for _ in range(3)))
        x += bw + 2
    d.rectangle([10, h * 0.15 + 112, w * 0.45, h * 0.15 + 124], fill=(110, 80, 50))
    d.ellipse([w * 0.78, h * 0.3, w * 0.95, h * 0.62], fill=(60, 120, 60))
    d.rectangle([w * 0.85, h * 0.55, w * 0.88, h], fill=(90, 60, 40))
    return im.filter(ImageFilter.GaussianBlur(5))


def person(d: ImageDraw.ImageDraw, r: random.Random, w: int, h: int, k: int) -> None:
    cx = w * r.uniform(0.4, 0.6) + (k % 2) * 3
    skin = r.choice([(240, 200, 170), (200, 150, 110), (150, 100, 70), (90, 60, 40)])
    shirt = tuple(r.randint(20, 200) for _ in range(3))
    d.rounded_rectangle([cx - w * 0.2, h * 0.68, cx + w * 0.2, h * 1.1], radius=60, fill=shirt)
    d.rectangle([cx - 22, h * 0.55, cx + 22, h * 0.72], fill=skin)
    hy = h * 0.42 + (k % 3) * 2
    d.ellipse([cx - 62, hy - 85, cx + 62, hy + 85], fill=skin)
    d.ellipse([cx - 68, hy - 98, cx + 68, hy - 10], fill=r.choice([(40, 25, 15), (90, 60, 30), (20, 20, 20), (200, 170, 90)]))
    for ex in (-25, 25):
        d.ellipse([cx + ex - 9, hy - 18, cx + ex + 9, hy - 6], fill="white")
        d.ellipse([cx + ex - 4, hy - 16, cx + ex + 4, hy - 8], fill=(40, 30, 20))
    mo = 4 + (k * 7) % 12
    d.ellipse([cx - 18, hy + 35 - mo / 2, cx + 18, hy + 35 + mo / 2], fill=(150, 60, 60))


def slide(seed, w, h):
    rng = random.Random(seed)
    bg = rng.choice([(255, 255, 255), (245, 240, 230), (20, 40, 80)])
    fg = (30, 30, 30) if sum(bg) > 400 else (240, 240, 240)
    im = Image.new("RGB", (w, h), bg)
    d = ImageDraw.Draw(im)
    d.text((w * 0.08, h * 0.1), sentence(rng, 3, 6), font=font("uib", h // 12), fill=fg)
    for i in range(rng.randint(3, 6)):
        y = h * 0.3 + i * h * 0.1
        d.ellipse([w * 0.1, y + 8, w * 0.1 + 10, y + 18], fill=fg)
        d.text((w * 0.13, y), sentence(rng, 3, 9), font=font("ui", h // 22), fill=fg)
    if rng.random() < 0.5:
        for i in range(5):
            bh = rng.uniform(0.1, 0.4) * h
            d.rectangle([w * (0.65 + i * 0.055), h * 0.85 - bh, w * (0.69 + i * 0.055), h * 0.85], fill=(60, 120, 200))
    return im


# ======================================================================================= jeux
def ground_texture(u, v, pal):
    a = (np.sin(u * 0.9) * np.sin(v * 0.7) + np.sin(u * 0.13 + v * 0.21) * 0.8)
    chk = ((np.floor(u / 6) + np.floor(v / 6)) % 2) * 0.15
    t = (a * 0.25 + 0.5 + chk).clip(0, 1)[..., None]
    return lerp(pal[0], pal[1], t)


def game_view(seed: int, kind: str, w: int, h: int, k: int, hud: bool = True) -> Image.Image:
    """Image de jeu procedurale (rendu basse resolution puis agrandi), camera qui bouge avec k."""
    rng = random.Random(seed)
    rw, rh = 480, 270
    if kind == "platformer":
        im = platformer(rng, rw, rh, k).resize((w, h), Image.NEAREST)
    elif kind == "strategy":
        im = strategy(seed, rw * 2, rh * 2, k).resize((w, h), Image.BILINEAR)
    elif kind == "racing":
        im = racing(rng, rw, rh, k).resize((w, h), Image.BILINEAR)
    else:
        im = perspective(seed, rw, rh, k, kind).resize((w, h), Image.BILINEAR)
    if hud:
        draw_hud(im, rng, kind, k)
    return im


def perspective(seed, rw, rh, k, kind):
    rng = random.Random(seed)
    nrng = np.random.default_rng(seed)
    pals = [((50, 110, 40), (90, 150, 60)), ((150, 130, 90), (190, 170, 120)), ((200, 210, 220), (240, 245, 250)),
            ((60, 60, 65), (95, 95, 100)), ((120, 70, 40), (170, 110, 60))]
    pal = pals[rng.randrange(len(pals))]
    sky = landscape(seed, rw, rh)
    img = sky.copy()
    hor = int(rh * rng.uniform(0.38, 0.5))
    yy, xx = np.mgrid[hor + 1:rh, 0:rw].astype(np.float32)
    z = 60.0 / (yy - hor)
    camx, camz = k * rng.uniform(-3, 3), k * rng.uniform(2, 6)
    u = (xx - rw / 2) * z * 0.08 + camx
    v = z * 4 + camz
    g = ground_texture(u, v, pal)
    fog = np.clip(z / 40, 0, 1)[..., None]
    img[hor + 1:] = g * (1 - fog) + img[hor + 1:] * fog
    im = to_img(img)
    d = ImageDraw.Draw(im)
    objs = []
    for _ in range(rng.randint(8, 25)):
        wx, wz = rng.uniform(-60, 60), rng.uniform(3, 60)
        objs.append((wz, wx, rng.choice(["tree", "tree", "rock", "box", "enemy", "house"])))
    for wz, wx, t in sorted(objs, reverse=True):
        zz = wz - camz * 0.5
        if zz <= 1:
            continue
        sx = rw / 2 + (wx - camx) / (zz * 0.08)
        sy = hor + 60.0 / zz * 4
        s = 120 / zz
        if t == "tree":
            d.rectangle([sx - s * 0.08, sy - s * 0.5, sx + s * 0.08, sy], fill=(80, 55, 30))
            d.polygon([(sx - s * 0.4, sy - s * 0.4), (sx + s * 0.4, sy - s * 0.4), (sx, sy - s * 1.4)], fill=(30, 90 + int(nrng.integers(0, 50)), 40))
        elif t == "rock":
            d.ellipse([sx - s * 0.3, sy - s * 0.3, sx + s * 0.3, sy], fill=(110, 110, 115))
        elif t == "box":
            d.rectangle([sx - s * 0.25, sy - s * 0.5, sx + s * 0.25, sy], fill=(150, 110, 60), outline=(80, 60, 30))
        elif t == "house":
            d.rectangle([sx - s * 0.6, sy - s * 0.7, sx + s * 0.6, sy], fill=(200, 190, 170))
            d.polygon([(sx - s * 0.7, sy - s * 0.7), (sx + s * 0.7, sy - s * 0.7), (sx, sy - s * 1.2)], fill=(150, 50, 40))
        else:
            d.ellipse([sx - s * 0.12, sy - s * 0.95, sx + s * 0.12, sy - s * 0.72], fill=(200, 60, 60))
            d.rectangle([sx - s * 0.15, sy - s * 0.72, sx + s * 0.15, sy - s * 0.25], fill=(150, 30, 30))
            d.rectangle([sx - s * 0.12, sy - s * 0.25, sx + s * 0.12, sy], fill=(60, 30, 30))
    if kind == "tps":
        cx = rw / 2
        d.rectangle([cx - 12, rh * 0.62, cx + 12, rh * 0.86], fill=(40, 60, 120))
        d.ellipse([cx - 9, rh * 0.55, cx + 9, rh * 0.63], fill=(220, 180, 140))
        d.rectangle([cx - 11, rh * 0.86, cx - 2, rh * 0.98], fill=(30, 30, 40))
        d.rectangle([cx + 2, rh * 0.86, cx + 11, rh * 0.98], fill=(30, 30, 40))
    else:  # fps : arme en bas a droite
        d.polygon([(rw * 0.62, rh), (rw * 0.7, rh * 0.72), (rw * 0.78, rh * 0.7), (rw * 0.86, rh)], fill=(50, 50, 55))
        d.rectangle([rw * 0.69, rh * 0.68, rw * 0.74, rh * 0.75], fill=(30, 30, 30))
    return im


def platformer(rng, rw, rh, k):
    im = Image.new("RGB", (rw, rh), rng.choice([(110, 170, 255), (255, 190, 140), (40, 30, 70)]))
    d = ImageDraw.Draw(im)
    off = k * 12
    for i in range(-1, 8):  # collines (parallaxe)
        x = i * 90 - (off // 3) % 90
        d.ellipse([x - 60, rh * 0.55, x + 80, rh * 0.95], fill=(60, 140, 80))
    tile = 16
    ground = rh - 3 * tile
    for x in range(-tile, rw + tile, tile):
        xx = x - off % tile
        d.rectangle([xx, ground, xx + tile - 1, rh], fill=(150, 90, 50))
        d.rectangle([xx, ground, xx + tile - 1, ground + 4], fill=(70, 170, 60))
    for i in range(6):
        px = (i * 97 + 40 - off) % (rw + 80) - 40
        py = ground - tile * rng.randint(2, 5)
        for j in range(rng.randint(2, 4)):
            d.rectangle([px + j * tile, py, px + (j + 1) * tile - 1, py + tile - 1], fill=(200, 120, 40), outline=(90, 50, 20))
        d.ellipse([px + 4, py - 14, px + 12, py - 4], fill=(255, 215, 0))
    cx = rw // 3
    d.rectangle([cx, ground - 24, cx + 12, ground], fill=(220, 40, 40))
    d.rectangle([cx + 2, ground - 32, cx + 10, ground - 24], fill=(250, 200, 160))
    return im


def strategy(seed, rw, rh, k):
    rng = np.random.default_rng(seed)
    hgt = fbm(rng, rh + 40, rw + 80, 5, 3)
    ox = min(80, k * 6)
    hgt = hgt[:rh, ox:ox + rw]
    cols = np.zeros((rh, rw, 3), np.float32)
    for lo, hi, c in ((0, 0.35, (40, 80, 160)), (0.35, 0.4, (210, 200, 140)), (0.4, 0.65, (80, 150, 60)),
                      (0.65, 0.8, (40, 100, 40)), (0.8, 1.01, (130, 120, 110))):
        m = (hgt >= lo) & (hgt < hi)
        cols[m] = c
    cols *= (0.85 + 0.3 * hgt[..., None])
    im = to_img(np.clip(cols, 0, 255))
    d = ImageDraw.Draw(im)
    r = random.Random(seed)
    for _ in range(40):
        x, y = r.uniform(0, rw), r.uniform(0, rh)
        c = r.choice([(220, 40, 40), (40, 80, 220)])
        d.rectangle([x, y, x + 6, y + 6], fill=c, outline="black")
    for _ in range(6):
        x, y = r.uniform(0, rw), r.uniform(0, rh)
        d.rectangle([x, y, x + 18, y + 14], fill=(170, 150, 120), outline="black")
    return im


def racing(rng, rw, rh, k):
    im = to_img(landscape(rng.randint(0, 10**6), rw, rh))
    d = ImageDraw.Draw(im)
    hor = int(rh * 0.45)
    d.rectangle([0, hor, rw, rh], fill=(70, 150, 60))
    d.polygon([(rw * 0.47, hor), (rw * 0.53, hor), (rw * 0.95, rh), (rw * 0.05, rh)], fill=(80, 80, 85))
    for i in range(12):
        t0 = ((i + k * 0.37) % 12) / 12
        t1 = t0 + 0.04
        y0, y1 = hor + (rh - hor) * t0 ** 2, hor + (rh - hor) * t1 ** 2
        d.polygon([(rw / 2 - 1 - 4 * t0, y0), (rw / 2 + 1 + 4 * t0, y0), (rw / 2 + 1 + 4 * t1, y1), (rw / 2 - 1 - 4 * t1, y1)], fill="white")
    d.rounded_rectangle([rw * 0.42, rh * 0.74, rw * 0.58, rh * 0.92], radius=6, fill=(200, 30, 30))
    d.rectangle([rw * 0.44, rh * 0.76, rw * 0.56, rh * 0.82], fill=(40, 60, 90))
    return im


def draw_hud(im: Image.Image, rng: random.Random, kind: str, k: int) -> None:
    w, h = im.size
    d = ImageDraw.Draw(im)
    s = h / 1080
    if kind in ("fps", "tps"):
        d.rectangle([40 * s, h - 90 * s, 440 * s, h - 60 * s], fill=(40, 0, 0))
        d.rectangle([40 * s, h - 90 * s, (40 + rng.randint(120, 400)) * s, h - 60 * s], fill=(210, 40, 40))
        d.rectangle([40 * s, h - 50 * s, 340 * s, h - 32 * s], fill=(30, 60, 160))
        d.text((w - 330 * s, h - 120 * s), f"{rng.randint(5, 30)} / {rng.randint(60, 240)}", font=font("arialb", 64 * s), fill="white")
        r = 130 * s
        d.ellipse([w - 2 * r - 30 * s, 30 * s, w - 30 * s, 30 * s + 2 * r], fill=(20, 30, 20), outline=(200, 200, 200), width=3)
        for _ in range(6):
            px = w - r - 30 * s + rng.uniform(-r, r) * 0.6
            py = 30 * s + r + rng.uniform(-r, r) * 0.6
            d.ellipse([px - 5, py - 5, px + 5, py + 5], fill=(220, 50, 50))
        cx, cy = w / 2, h / 2
        d.line([(cx - 14 * s, cy), (cx + 14 * s, cy)], fill="white", width=2)
        d.line([(cx, cy - 14 * s), (cx, cy + 14 * s)], fill="white", width=2)
        for i in range(rng.randint(2, 4)):
            d.text((30 * s, (30 + i * 34) * s), f"{rng.choice(NAMES)} ✕ {rng.choice(NAMES)}", font=font("uib", 26 * s), fill=(240, 240, 240))
        for i in range(8):
            x = w / 2 - 4 * 74 * s + i * 74 * s
            d.rectangle([x, h - 90 * s, x + 66 * s, h - 24 * s], fill=(30, 30, 30), outline=(180, 180, 180), width=2)
    elif kind == "platformer":
        d.text((30 * s, 20 * s), f"SCORE {rng.randint(100, 99999):06d}", font=font("arialb", 48 * s), fill="white")
        for i in range(3):
            d.ellipse([(w - 260 + i * 70) * s, 30 * s, (w - 210 + i * 70) * s, 80 * s], fill=(230, 30, 60))
    elif kind == "strategy":
        d.rectangle([0, 0, w, 44 * s], fill=(35, 30, 25))
        for i, lab in enumerate(["Bois", "Or", "Pierre", "Nourriture"]):
            d.text(((30 + i * 300) * s, 6 * s), f"{lab} {rng.randint(50, 3000)}", font=font("uib", 28 * s), fill=(240, 220, 160))
        d.rectangle([0, h - 260 * s, w, h], fill=(45, 40, 35))
        d.rectangle([20 * s, h - 245 * s, 300 * s, h - 20 * s], fill=(30, 60, 30), outline=(200, 180, 120), width=3)
        for i in range(12):
            x = 900 * s + (i % 6) * 110 * s
            y = h - 230 * s + (i // 6) * 105 * s
            d.rectangle([x, y, x + 96 * s, y + 92 * s], fill=(70, 60, 50), outline=(200, 180, 120), width=2)
    elif kind == "racing":
        d.text((40 * s, 30 * s), f"TOUR {1 + k % 3}/3   POS {rng.randint(1, 8)}/8", font=font("arialb", 52 * s), fill="white")
        cx, cy, r = w - 220 * s, h - 200 * s, 160 * s
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(20, 20, 25), outline="white", width=4)
        a = math.radians(200 + rng.uniform(40, 140))
        d.line([(cx, cy), (cx + r * 0.85 * math.cos(a), cy + r * 0.85 * math.sin(a))], fill=(255, 60, 30), width=6)
        d.text((cx - 60 * s, cy + 40 * s), f"{rng.randint(90, 280)} km/h", font=font("arialb", 34 * s), fill="white")


# ======================================================================================= applis
THEMES = {"dark": {"bg": (31, 31, 31), "panel": (37, 37, 38), "bar": (51, 51, 51), "fg": (212, 212, 212),
                   "muted": (140, 140, 140), "line": (60, 60, 60), "title": (32, 32, 32)},
          "light": {"bg": (255, 255, 255), "panel": (243, 243, 243), "bar": (230, 230, 230), "fg": (30, 30, 30),
                    "muted": (110, 110, 110), "line": (215, 215, 215), "title": (238, 238, 238)}}


class App:
    """Fenetre d'appli : chrome + contenu. render(k) -> image de la fenetre ; video : rectangle local ou None."""

    proc = "app.exe"
    cls = "other"

    def __init__(self, rng: random.Random, w: int, h: int, theme: str, s: float, variant: int) -> None:
        self.rng, self.w, self.h, self.theme, self.s, self.variant = rng, w, h, theme, s, variant
        self.t = THEMES[theme]
        self.video = None  # (x, y, w, h) local
        self.clip: Clip | None = None
        self.title = "Application"
        self.dynamic = False
        self._static: Image.Image | None = None
        self.frameless = False

    def fs(self, n):
        return max(8, int(n * self.s))

    # --- a surcharger
    def draw(self, im: Image.Image, d: ImageDraw.ImageDraw, x0: int, y0: int, w: int, h: int) -> None:
        pass

    def overlay(self, im: Image.Image, k: int, x0: int, y0: int) -> None:
        """Parties qui changent d'une capture a l'autre (video, curseur, defilement...)."""
        if self.clip is not None and self.video is not None:
            vx, vy, vw, vh = self.video
            im.paste(self.clip.frame(k, vw, vh), (vx, vy))
            self.player_controls(im, k)

    def player_controls(self, im, k):
        vx, vy, vw, vh = self.video
        d = ImageDraw.Draw(im)
        if getattr(self, "paused", False) and k == 0:
            pass
        y = vy + vh - self.fs(44)
        d.rectangle([vx + 12, y, vx + vw - 12, y + self.fs(4)], fill=(120, 120, 120))
        prog = getattr(self, "prog", 0.3) + 0.004 * k * (0 if getattr(self, "paused", False) else 1)
        d.rectangle([vx + 12, y, vx + 12 + int((vw - 24) * prog), y + self.fs(4)], fill=(230, 30, 30))
        t0 = int(prog * 640)
        d.text((vx + self.fs(70), y + self.fs(12)), f"{t0 // 60}:{t0 % 60:02d} / 10:40", font=font("ui", self.fs(15)), fill="white")
        if getattr(self, "paused", False):
            cx, cy = vx + vw // 2, vy + vh // 2
            r = self.fs(40)
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(0, 0, 0))
            d.polygon([(cx - r // 3, cy - r // 2), (cx - r // 3, cy + r // 2), (cx + r // 2, cy)], fill="white")
        else:
            d.polygon([(vx + 24, y + self.fs(12)), (vx + 24, y + self.fs(30)), (vx + 24 + self.fs(14), y + self.fs(21))], fill="white")

    # --- chrome commun
    def render(self, k: int) -> Image.Image:
        if self._static is None:
            im = Image.new("RGB", (self.w, self.h), self.t["bg"])
            d = ImageDraw.Draw(im)
            if self.frameless:
                self.draw(im, d, 0, 0, self.w, self.h)
                self.cx, self.cy = 0, 0
            else:
                th = self.fs(32)
                d.rectangle([0, 0, self.w, th], fill=self.titlebar_color())
                d.text((self.fs(44), self.fs(7)), self.title[:90], font=font("ui", self.fs(13)), fill=self.titlebar_fg())
                d.rounded_rectangle([self.fs(12), self.fs(8), self.fs(28), self.fs(24)], radius=3, fill=self.icon_color())
                for i, g in enumerate(["—", "☐", "✕"]):
                    d.text((self.w - self.fs(46) * (3 - i) + self.fs(16), self.fs(6)), g, font=font("ui", self.fs(13)), fill=self.titlebar_fg())
                self.draw(im, d, 0, th, self.w, self.h - th)
                self.cx, self.cy = 0, th
                d.rectangle([0, 0, self.w - 1, self.h - 1], outline=(90, 90, 90) if self.theme == "dark" else (180, 180, 180))
            self._static = im
        if not self.dynamic and self.clip is None:
            return self._static
        im = self._static.copy()
        self.overlay(im, k, self.cx, self.cy)
        return im

    def titlebar_color(self):
        return self.t["title"]

    def titlebar_fg(self):
        return self.t["fg"]

    def icon_color(self):
        return (0, 120, 215)


# ---------------------------------------------------------------- navigateur
SITES_VIDEO = ["VidTube", "Flux", "StreamBox", "Kinetic", "ClipZone"]
SITES_NEWS = ["Le Quotidien", "Morning Post", "L'Écho du Jour", "Daily Ledger", "Info Express"]
SITES_SHOP = ["MegaStore", "Boutik", "ShopNow", "La Halle Tech", "Marché Plus"]
BROWSER_PROCS = ["chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe"]


class Browser(App):
    cls = "browse"

    def __init__(self, *a, page: str = "news", **kw) -> None:
        super().__init__(*a, **kw)
        self.proc = self.rng.choice(BROWSER_PROCS)
        self.page = page
        self.frameless = True
        self.scroll = 0
        self.ad = None
        site = {"watch": SITES_VIDEO, "news": SITES_NEWS, "shop": SITES_SHOP}.get(page, ["Web"])
        self.site = self.rng.choice(site)
        self.title = f"{sentence(self.rng, 3, 7)} - {self.site}"

    def draw(self, im, d, x0, y0, w, h):
        t, s = self.t, self.s
        tab_h, bar_h = self.fs(38), self.fs(44)
        d.rectangle([0, 0, w, tab_h], fill=t["title"] if self.variant != 2 else (t["panel"]))
        n = self.rng.randint(2, 6)
        tw = min(self.fs(240), (w - self.fs(160)) // n)
        for i in range(n):
            x = self.fs(10) + i * tw
            sel = i == 0
            d.rounded_rectangle([x, self.fs(6), x + tw - 4, tab_h + 4], radius=self.fs(8), fill=t["bg"] if sel else t["title"])
            d.rectangle([x + self.fs(10), self.fs(14), x + self.fs(26), self.fs(30)], fill=(self.rng.randint(0, 255), self.rng.randint(0, 255), self.rng.randint(0, 255)))
            d.text((x + self.fs(34), self.fs(12)), (self.title if sel else sentence(self.rng, 2, 5))[:max(4, tw // self.fs(8))], font=font("ui", self.fs(12)), fill=t["fg"])
        d.rectangle([0, tab_h, w, tab_h + bar_h], fill=t["bg"])
        for i in range(3):
            d.ellipse([self.fs(12 + 34 * i), tab_h + self.fs(10), self.fs(36 + 34 * i), tab_h + self.fs(34)], outline=t["muted"], width=2)
        d.rounded_rectangle([self.fs(130), tab_h + self.fs(7), w - self.fs(140), tab_h + bar_h - self.fs(7)], radius=self.fs(16), fill=t["panel"])
        url = f"https://www.{self.site.lower().replace(' ', '').replace(chr(39), '')}.com/{words(self.rng, 2).replace(' ', '-')}"
        d.text((self.fs(160), tab_h + self.fs(13)), url, font=font("ui", self.fs(14)), fill=t["fg"])
        for i in range(4):
            d.rounded_rectangle([w - self.fs(130) + i * self.fs(30), tab_h + self.fs(14), w - self.fs(112) + i * self.fs(30), tab_h + self.fs(32)], radius=4, fill=t["muted"])
        top = tab_h + bar_h
        d.line([(0, top), (w, top)], fill=t["line"])
        self.page_top = top
        page = Image.new("RGB", (w, h - top + (self.fs(900) if self.page in ("news", "shop", "social", "search", "wiki") else 0)), t["bg"])
        self.draw_page(page, ImageDraw.Draw(page), w, page.height)
        self.page_img = page
        im.paste(page.crop((0, 0, w, h - top)), (0, top))

    def overlay(self, im, k, x0, y0):
        if self.scroll:
            off = min(self.page_img.height - (self.h - self.page_top), self.scroll * k)
            im.paste(self.page_img.crop((0, off, self.w, off + self.h - self.page_top)), (0, self.page_top))
        if self.ad is not None:
            ax, ay, aw, ah = self.ad
            c = [(230, 60, 60), (60, 160, 230), (250, 200, 40), (120, 200, 90)][k % 4]
            d = ImageDraw.Draw(im)
            d.rectangle([ax, ay, ax + aw, ay + ah], fill=c)
            d.text((ax + 10, ay + ah // 3), ["-50% !", "SOLDES", "Jouez gratuitement", "Offre limitée"][k % 4], font=font("uib", self.fs(22)), fill="white")
        super().overlay(im, k, x0, y0)

    # --- pages
    def draw_page(self, im, d, w, h):
        getattr(self, "page_" + self.page)(im, d, w, h)

    def header(self, d, w, name, color=None):
        d.rectangle([0, 0, w, self.fs(64)], fill=color or self.t["bg"])
        d.text((self.fs(30), self.fs(14)), name, font=font("serifb" if self.page == "news" else "uib", self.fs(28)), fill=self.t["fg"] if color is None else "white")
        d.rounded_rectangle([w * 0.3, self.fs(14), w * 0.62, self.fs(50)], radius=self.fs(18), outline=self.t["line"], width=2)
        d.text((w * 0.3 + self.fs(16), self.fs(22)), "Rechercher", font=font("ui", self.fs(15)), fill=self.t["muted"])

    def thumb(self, im, x, y, w, h):
        r = self.rng.random()
        if r < 0.6:
            a = landscape(self.rng.randint(0, 10**6), max(16, w // 4), max(9, h // 4))
            im.paste(to_img(a).resize((w, h), Image.BICUBIC), (int(x), int(y)))
        elif r < 0.8:
            im.paste(game_view(self.rng.randint(0, 10**6), self.rng.choice(["tps", "fps", "platformer"]), max(16, w), max(9, h), 0, hud=False), (int(x), int(y)))
        else:
            im.paste(slide(self.rng.randint(0, 10**6), max(16, w), max(9, h)), (int(x), int(y)))

    def page_watch(self, im, d, w, h):
        t = self.t
        self.header(d, w, "▶ " + self.site)
        top = self.fs(80)
        theater = getattr(self, "theater", False)
        if self.variant == 2:  # lecteur centre, pas de colonne de suggestions (type Vimeo)
            pw = int(w * 0.7)
            px = (w - pw) // 2
        elif theater:
            pw, px = w, 0
            top = self.fs(64)
        else:
            pw, px = int(w * 0.66), self.fs(30)
        ph = int(pw * 9 / 16)
        if theater:
            ph = min(ph, int(h * 0.62))
        d.rectangle([px, top, px + pw, top + ph], fill=(0, 0, 0))
        self.video = (px, top + self.page_top, pw, ph)
        y = top + ph + self.fs(16)
        d.text((px + self.fs(8), y), sentence(self.rng, 5, 11), font=font("uib", self.fs(22)), fill=t["fg"])
        y += self.fs(44)
        d.ellipse([px + self.fs(8), y, px + self.fs(52), y + self.fs(44)], fill=(self.rng.randint(50, 250), 120, 90))
        d.text((px + self.fs(64), y + self.fs(4)), self.rng.choice(NAMES) + " TV", font=font("uib", self.fs(16)), fill=t["fg"])
        d.rounded_rectangle([px + self.fs(260), y + self.fs(4), px + self.fs(380), y + self.fs(40)], radius=self.fs(18), fill=t["fg"])
        d.text((px + self.fs(276), y + self.fs(10)), "S'abonner", font=font("uib", self.fs(15)), fill=t["bg"])
        y += self.fs(64)
        d.rounded_rectangle([px, y, px + pw, y + self.fs(120)], radius=self.fs(12), fill=t["panel"])
        for i in range(3):
            d.text((px + self.fs(16), y + self.fs(12 + 30 * i)), sentence(self.rng, 8, 16), font=font("ui", self.fs(15)), fill=t["fg"])
        if self.variant != 2 and not theater:
            cx = px + pw + self.fs(30)
            tw2 = self.fs(180)
            for i in range(14):
                yy = top + i * self.fs(110)
                if yy + self.fs(100) > h:
                    break
                self.thumb(im, cx, yy, tw2, int(tw2 * 9 / 16))
                d.text((cx + tw2 + self.fs(10), yy), sentence(self.rng, 3, 7)[:34], font=font("uisb", self.fs(14)), fill=t["fg"])
                d.text((cx + tw2 + self.fs(10), yy + self.fs(24)), f"{self.rng.choice(NAMES)} · {self.rng.randint(1, 900)} k vues", font=font("ui", self.fs(13)), fill=t["muted"])

    def page_news(self, im, d, w, h):
        t = self.t
        self.header(d, w, self.site, color=self.rng.choice([(150, 20, 30), (20, 40, 90), None]))
        y = self.fs(80)
        for i, m in enumerate(["International", "Politique", "Économie", "Culture", "Sport", "Sciences"]):
            d.text((self.fs(30) + i * self.fs(140), y), m, font=font("uisb", self.fs(15)), fill=t["fg"])
        y += self.fs(44)
        hw = int(w * 0.6)
        self.thumb(im, self.fs(30), y, hw, int(hw * 0.45))
        d.text((self.fs(30), y + int(hw * 0.45) + self.fs(14)), sentence(self.rng, 6, 12), font=font("serifb", self.fs(30)), fill=t["fg"])
        yy = y + int(hw * 0.45) + self.fs(64)
        while yy < h - self.fs(30):
            d.text((self.fs(30), yy), sentence(self.rng, 10, 18), font=font("serif", self.fs(16)), fill=t["fg"])
            yy += self.fs(28)
        sx = hw + self.fs(70)
        yy = y
        while yy < h - self.fs(150):
            self.thumb(im, sx, yy, self.fs(200), self.fs(120))
            d.text((sx + self.fs(214), yy), sentence(self.rng, 4, 8)[:40], font=font("serifb", self.fs(17)), fill=t["fg"])
            d.text((sx + self.fs(214), yy + self.fs(30)), sentence(self.rng, 5, 9)[:46], font=font("ui", self.fs(14)), fill=t["muted"])
            yy += self.fs(150)
        if self.rng.random() < 0.25:
            self.ad = (sx, self.page_top + y + self.fs(20), self.fs(300), self.fs(250))
            self.dynamic = True

    def page_shop(self, im, d, w, h):
        t = self.t
        self.header(d, w, self.site, color=self.rng.choice([(255, 153, 0), (0, 90, 160), (30, 30, 30)]))
        y = self.fs(90)
        cw, ch = self.fs(260), self.fs(380)
        cols = max(1, (w - self.fs(60)) // (cw + self.fs(24)))
        i = 0
        while y + ch < h:
            for c in range(cols):
                x = self.fs(30) + c * (cw + self.fs(24))
                d.rounded_rectangle([x, y, x + cw, y + ch], radius=8, outline=t["line"], width=1)
                bx = x + self.fs(30)
                col = tuple(self.rng.randint(30, 230) for _ in range(3))
                shape = self.rng.random()
                if shape < 0.3:
                    d.rounded_rectangle([bx, y + self.fs(30), bx + cw - self.fs(60), y + self.fs(200)], radius=12, fill=col)
                elif shape < 0.6:
                    d.ellipse([bx, y + self.fs(30), bx + cw - self.fs(60), y + self.fs(200)], fill=col)
                else:
                    self.thumb(im, x + 2, y + 2, cw - 4, self.fs(210))
                d.text((x + self.fs(14), y + self.fs(230)), sentence(self.rng, 2, 5)[:26], font=font("ui", self.fs(15)), fill=t["fg"])
                d.text((x + self.fs(14), y + self.fs(262)), "★★★★☆", font=font("ui", self.fs(15)), fill=(240, 160, 0))
                d.text((x + self.fs(14), y + self.fs(296)), f"{self.rng.randint(5, 900)},{self.rng.randint(0, 99):02d} €", font=font("uib", self.fs(22)), fill=t["fg"])
                i += 1
            y += ch + self.fs(24)

    def page_search(self, im, d, w, h):
        t = self.t
        self.header(d, w, self.rng.choice(["Trouvtou", "Seekr", "Qwerk"]))
        y = self.fs(100)
        while y < h - self.fs(120):
            d.text((self.fs(180), y), f"www.{words(self.rng, 1, 'en')}.fr › {words(self.rng, 1)}", font=font("ui", self.fs(13)), fill=(0, 128, 60))
            d.text((self.fs(180), y + self.fs(22)), sentence(self.rng, 4, 9), font=font("ui", self.fs(20)), fill=(26, 13, 171) if self.theme == "light" else (140, 180, 250))
            d.text((self.fs(180), y + self.fs(54)), sentence(self.rng, 12, 20), font=font("ui", self.fs(14)), fill=t["muted"])
            y += self.fs(130)

    def page_wiki(self, im, d, w, h):  # style tenu a l'ecart (variante 2 du web)
        t = self.t
        d.text((self.fs(240), self.fs(30)), sentence(self.rng, 1, 3), font=font("serif", self.fs(34)), fill=t["fg"])
        d.line([(self.fs(240), self.fs(84)), (w - self.fs(40), self.fs(84))], fill=t["line"])
        for i in range(12):
            d.text((self.fs(20), self.fs(30 + 26 * i)), words(self.rng, 2), font=font("ui", self.fs(13)), fill=(51, 102, 204))
        bx = w - self.fs(420)
        d.rectangle([bx, self.fs(110), w - self.fs(40), self.fs(640)], outline=t["line"], fill=t["panel"])
        self.thumb(im, bx + self.fs(20), self.fs(130), self.fs(340), self.fs(220))
        y = self.fs(110)
        while y < h - self.fs(40):
            d.text((self.fs(240), y), sentence(self.rng, 9, 15), font=font("serif", self.fs(15)), fill=t["fg"])
            y += self.fs(26)

    def page_social(self, im, d, w, h):
        t = self.t
        self.header(d, w, self.rng.choice(["Pixelgram", "Chirp", "Mosaic"]))
        x0 = int(w * 0.3)
        y = self.fs(90)
        while y < h - self.fs(300):
            d.ellipse([x0, y, x0 + self.fs(44), y + self.fs(44)], fill=(self.rng.randint(50, 250), 100, 160))
            d.text((x0 + self.fs(56), y + self.fs(10)), self.rng.choice(NAMES), font=font("uib", self.fs(16)), fill=t["fg"])
            d.text((x0, y + self.fs(56)), sentence(self.rng, 6, 14), font=font("ui", self.fs(16)), fill=t["fg"])
            if self.rng.random() < 0.7:
                self.thumb(im, x0, y + self.fs(90), int(w * 0.4), self.fs(300))
                y += self.fs(420)
            else:
                y += self.fs(120)

    def page_docs(self, im, d, w, h):  # Google Docs-like dans le navigateur (work_docs)
        draw_doc_page(d, self.rng, self.t, self.s, 0, 0, w, h, self.fs)

    def page_sheet(self, im, d, w, h):
        draw_grid(d, self.rng, self.t, 0, self.fs(40), w, h, self.fs)

    def page_webchat(self, im, d, w, h):
        draw_chat(im, d, self.rng, "discord", 0, 0, w, h, self.fs)


def draw_doc_page(d, rng, t, s, x0, y0, w, h, fs):
    d.rectangle([x0, y0, x0 + w, y0 + fs(90)], fill=(248, 249, 250))
    for i in range(18):
        d.rounded_rectangle([x0 + fs(20) + i * fs(36), y0 + fs(52), x0 + fs(46) + i * fs(36), y0 + fs(78)], radius=4, fill=(205, 210, 220))
    d.text((x0 + fs(20), y0 + fs(12)), sentence(rng, 2, 4), font=font("ui", fs(20)), fill=(40, 40, 40))
    d.rectangle([x0, y0 + fs(90), x0 + w, y0 + h], fill=(240, 242, 245))
    pw = min(fs(816), int(w * 0.8))
    px = x0 + (w - pw) // 2
    d.rectangle([px, y0 + fs(110), px + pw, y0 + h], fill="white", outline=(220, 220, 220))
    y = y0 + fs(180)
    d.text((px + fs(90), y), sentence(rng, 3, 7), font=font("docb", fs(26)), fill=(20, 20, 20))
    y += fs(60)
    while y < y0 + h - fs(40):
        if rng.random() < 0.12:
            y += fs(22)
        d.text((px + fs(90), y), sentence(rng, 9, 15)[: max(20, pw // fs(8))], font=font("doc", fs(16)), fill=(30, 30, 30))
        y += fs(26)


def draw_grid(d, rng, t, x0, y0, w, h, fs):
    cw, rh = fs(100), fs(24)
    d.rectangle([x0, y0, x0 + w, y0 + rh], fill=(240, 240, 240))
    d.text((x0 + fs(8), y0 + fs(3)), "fx", font=font("ui", fs(14)), fill=(90, 90, 90))
    y0 += rh + fs(6)
    d.rectangle([x0, y0, x0 + w, y0 + rh], fill=(230, 230, 230))
    for c in range(w // cw + 1):
        d.text((x0 + fs(40) + c * cw + cw // 2, y0 + fs(3)), chr(65 + c % 26), font=font("ui", fs(13)), fill=(60, 60, 60))
    r = 0
    y = y0 + rh
    while y < y0 + h:
        d.text((x0 + fs(8), y + fs(3)), str(r + 1), font=font("ui", fs(13)), fill=(90, 90, 90))
        d.line([(x0, y), (x0 + w, y)], fill=(225, 225, 225))
        for c in range(w // cw + 1):
            x = x0 + fs(40) + c * cw
            d.line([(x, y), (x, y + rh)], fill=(225, 225, 225))
            if c < 7 and rng.random() < 0.75:
                v = rng.choice([f"{rng.randint(1, 9999)}", f"{rng.uniform(0, 999):.2f}", words(rng, 1), f"{rng.randint(1, 100)} %"])
                d.text((x + fs(6), y + fs(4)), v, font=font("doc", fs(14)), fill=(20, 20, 20))
        y += rh
        r += 1


def draw_chat(im, d, rng, style, x0, y0, w, h, fs):
    if style == "discord":
        bg, side, side2, fg, mut = (49, 51, 56), (30, 31, 34), (43, 45, 49), (220, 221, 222), (148, 155, 164)
    elif style == "slack":
        bg, side, side2, fg, mut = (255, 255, 255), (63, 14, 64), (63, 14, 64), (29, 28, 29), (97, 96, 97)
    else:  # whatsapp (tenu a l'ecart)
        bg, side, side2, fg, mut = (239, 234, 226), (255, 255, 255), (240, 242, 245), (17, 27, 33), (102, 119, 129)
    d.rectangle([x0, y0, x0 + w, y0 + h], fill=bg)
    if style == "discord":
        d.rectangle([x0, y0, x0 + fs(72), y0 + h], fill=side)
        for i in range(10):
            d.ellipse([x0 + fs(12), y0 + fs(12 + 60 * i), x0 + fs(60), y0 + fs(60 + 60 * i)], fill=(rng.randint(60, 240), rng.randint(60, 240), rng.randint(60, 240)))
        d.rectangle([x0 + fs(72), y0, x0 + fs(312), y0 + h], fill=side2)
        for i in range(16):
            d.text((x0 + fs(90), y0 + fs(60 + 32 * i)), "# " + words(rng, 1), font=font("ui", fs(15)), fill=mut)
        mx = x0 + fs(330)
    elif style == "slack":
        d.rectangle([x0, y0, x0 + fs(260), y0 + h], fill=side)
        for i in range(18):
            d.text((x0 + fs(20), y0 + fs(60 + 30 * i)), "# " + words(rng, 1), font=font("ui", fs(15)), fill=(220, 200, 220))
        mx = x0 + fs(280)
    else:
        d.rectangle([x0, y0, x0 + fs(420), y0 + h], fill=side)
        for i in range(12):
            yy = y0 + fs(70 + 72 * i)
            d.ellipse([x0 + fs(14), yy, x0 + fs(62), yy + fs(48)], fill=(rng.randint(60, 240), 160, 120))
            d.text((x0 + fs(76), yy + fs(4)), rng.choice(NAMES), font=font("uib", fs(16)), fill=fg)
            d.text((x0 + fs(76), yy + fs(28)), rng.choice(CHAT)[:30], font=font("ui", fs(14)), fill=mut)
        d.rectangle([x0 + fs(420), y0, x0 + w, y0 + fs(60)], fill=side2)
        mx = x0 + fs(440)
    y = y0 + fs(80)
    while y < y0 + h - fs(140):
        if style == "whatsapp":
            mine = rng.random() < 0.5
            txt = rng.choice(CHAT)
            tw = font("ui", fs(16)).getlength(txt) + fs(30)
            bx = x0 + w - fs(40) - tw if mine else mx
            d.rounded_rectangle([bx, y, bx + tw, y + fs(40)], radius=fs(8), fill=(217, 253, 211) if mine else (255, 255, 255))
            d.text((bx + fs(12), y + fs(9)), txt, font=font("ui", fs(16)), fill=fg)
            y += fs(56)
        else:
            d.ellipse([mx, y, mx + fs(40), y + fs(40)], fill=(rng.randint(60, 240), rng.randint(60, 240), rng.randint(60, 240)))
            d.text((mx + fs(56), y), rng.choice(NAMES), font=font("uib", fs(16)), fill=(rng.randint(120, 255), rng.randint(120, 255), 200) if style == "discord" else fg)
            d.text((mx + fs(56) + fs(110), y + fs(3)), f"{rng.randint(8, 23)}:{rng.randint(0, 59):02d}", font=font("ui", fs(12)), fill=mut)
            d.text((mx + fs(56), y + fs(24)), rng.choice(CHAT), font=font("ui", fs(16)), fill=fg)
            y += fs(70)
    d.rounded_rectangle([mx, y0 + h - fs(70), x0 + w - fs(30), y0 + h - fs(22)], radius=fs(8), fill=(56, 58, 64) if style == "discord" else (240, 240, 240))
    d.text((mx + fs(16), y0 + h - fs(58)), "Envoyer un message", font=font("ui", fs(16)), fill=mut)


# ---------------------------------------------------------------- applis de bureau
class CodeEditor(App):
    cls = "work_code"

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.proc = "idea64.exe" if self.variant == 2 else self.rng.choice(["code.exe", "code.exe", "cursor.exe"])
        self.lang = self.rng.choice(list(CODE))
        self.file = f"{self.rng.choice(['player', 'inventory', 'world', 'api', 'main', 'utils'])}.{self.lang}"
        self.title = f"{self.file} - {self.rng.choice(['pompom', 'jeu-2d', 'backend'])} - Visual Studio Code" if self.variant != 2 else f"backend – {self.file}"
        self.dynamic = True
        self.terminal = self.rng.random() < 0.35

    def titlebar_color(self):
        return (60, 63, 65) if self.variant == 2 else self.t["title"]

    def draw(self, im, d, x0, y0, w, h):
        t, fs = self.t, self.fs
        dark = self.theme == "dark"
        if self.variant == 2:
            bg, side, fg = (43, 43, 43), (60, 63, 65), (169, 183, 198)
        else:
            bg, side, fg = (t["bg"], t["panel"], t["fg"])
        d.rectangle([x0, y0, x0 + w, y0 + h], fill=bg)
        d.rectangle([x0, y0, x0 + fs(48), y0 + h], fill=side)
        for i in range(6):
            d.rounded_rectangle([x0 + fs(12), y0 + fs(14 + 52 * i), x0 + fs(36), y0 + fs(38 + 52 * i)], radius=4, outline=t["muted"], width=2)
        sw = fs(260)
        d.rectangle([x0 + fs(48), y0, x0 + fs(48) + sw, y0 + h], fill=side)
        for i in range(24):
            ind = fs(16) * self.rng.randint(0, 2)
            d.text((x0 + fs(60) + ind, y0 + fs(40 + 24 * i)), self.rng.choice(["src", "tests", "assets", "README.md", "main", "player", "utils", "config.json", "world", "ui"]) + ("" if self.rng.random() < 0.4 else "." + self.lang), font=font("ui", fs(13)), fill=fg)
        ex = x0 + fs(48) + sw
        d.rectangle([ex, y0, x0 + w, y0 + fs(36)], fill=side)
        d.rectangle([ex, y0, ex + fs(180), y0 + fs(36)], fill=bg)
        d.text((ex + fs(14), y0 + fs(9)), self.file, font=font("ui", fs(13)), fill=fg)
        lh = fs(20)
        y = y0 + fs(48)
        lines = CODE[self.lang]
        start = self.rng.randrange(len(lines))
        n = 0
        bottom = y0 + h - (fs(260) if self.terminal else fs(30))
        cols = {"kw": (86, 156, 214) if dark else (0, 0, 255), "str": (206, 145, 120) if dark else (163, 21, 21),
                "com": (106, 153, 85) if dark else (0, 128, 0), "num": (181, 206, 168) if dark else (9, 134, 88),
                "fn": (220, 220, 170) if dark else (121, 94, 38)}
        if self.variant == 2:
            cols = {"kw": (204, 120, 50), "str": (106, 135, 89), "com": (128, 128, 128), "num": (104, 151, 187), "fn": (255, 198, 109)}
        f = font("mono", fs(15))
        while y < bottom:
            line = lines[(start + n) % len(lines)]
            d.text((ex + fs(10), y), f"{n + 1:>4}", font=f, fill=t["muted"])
            x = ex + fs(70)
            import re as _re
            for tok in _re.findall(r"\s+|\"[^\"]*\"|'[^']*'|#.*|//.*|\w+|.", line):
                c = fg
                if tok.startswith(("#", "//")):
                    c = cols["com"]
                elif tok[:1] in "\"'":
                    c = cols["str"]
                elif tok in KW:
                    c = cols["kw"]
                elif tok.isdigit():
                    c = cols["num"]
                elif tok[:1].isalpha() and line[line.find(tok) + len(tok):][:1] == "(":
                    c = cols["fn"]
                d.text((x, y), tok, font=f, fill=c)
                x += f.getlength(tok)
            y += lh
            n += 1
        mm = x0 + w - fs(90)
        for i in range(120):
            d.line([(mm, y0 + fs(48) + i * 4), (mm + self.rng.randint(10, 70), y0 + fs(48) + i * 4)], fill=t["muted"], width=1)
        if self.terminal:
            ty = bottom
            d.rectangle([ex, ty, x0 + w, y0 + h - fs(24)], fill=(24, 24, 24) if dark else (250, 250, 250))
            d.text((ex + fs(10), ty + fs(6)), "TERMINAL   PROBLÈMES   SORTIE", font=font("ui", fs(12)), fill=t["muted"])
            for i, l in enumerate(TERM[self.rng.randrange(8):][:9]):
                d.text((ex + fs(10), ty + fs(30) + i * fs(20)), l, font=font("mono", fs(14)), fill=(204, 204, 204) if dark else (30, 30, 30))
        d.rectangle([x0, y0 + h - fs(24), x0 + w, y0 + h], fill=(0, 122, 204) if self.variant != 2 else (60, 63, 65))
        d.text((x0 + fs(10), y0 + h - fs(21)), f"main  Ln {self.rng.randint(1, 300)}, Col {self.rng.randint(1, 80)}   UTF-8   {self.lang}", font=font("ui", fs(12)), fill="white")
        self.cursor = (ex + fs(70) + fs(120), y0 + fs(48) + lh * self.rng.randint(2, 20))

    def overlay(self, im, k, x0, y0):
        if k % 2 == 0:
            d = ImageDraw.Draw(im)
            cx, cy = self.cursor
            d.rectangle([cx, cy, cx + 2, cy + self.fs(18)], fill=(220, 220, 220) if self.theme == "dark" else (0, 0, 0))
        super().overlay(im, k, x0, y0)


class Terminal(App):
    cls = "work_code"
    proc = "windowsterminal.exe"

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.title = self.rng.choice(["Windows PowerShell", "Ubuntu", "Invite de commandes", "pwsh"])
        self.dynamic = True

    def draw(self, im, d, x0, y0, w, h):
        bg = self.rng.choice([(12, 12, 12), (1, 36, 86), (40, 42, 54), (30, 30, 30)])
        d.rectangle([x0, y0, x0 + w, y0 + h], fill=bg)
        y = y0 + self.fs(10)
        i = self.rng.randrange(len(TERM))
        f = font("mono", self.fs(16))
        while y < y0 + h - self.fs(24):
            d.text((x0 + self.fs(10), y), TERM[i % len(TERM)], font=f, fill=self.rng.choice([(204, 204, 204), (204, 204, 204), (22, 198, 12), (97, 214, 214)]))
            y += self.fs(21)
            i += 1
        self.cursor = (x0 + self.fs(300), y - self.fs(21))

    def overlay(self, im, k, x0, y0):
        if k % 2 == 0:
            d = ImageDraw.Draw(im)
            d.rectangle([self.cursor[0], self.cursor[1], self.cursor[0] + self.fs(9), self.cursor[1] + self.fs(18)], fill=(204, 204, 204))


class Word(App):
    cls = "work_docs"

    def __init__(self, *a, kind="word", **kw):
        super().__init__(*a, **kw)
        self.kind = kind
        self.proc = {"word": "winword.exe", "excel": "excel.exe", "ppt": "powerpnt.exe", "pdf": "acrobat.exe"}[kind]
        ext = {"word": "docx", "excel": "xlsx", "ppt": "pptx", "pdf": "pdf"}[kind]
        self.title = f"{sentence(self.rng, 1, 3)}.{ext} - " + {"word": "Word", "excel": "Excel", "ppt": "PowerPoint", "pdf": "Adobe Acrobat"}[kind]

    def titlebar_color(self):
        return {"word": (43, 87, 154), "excel": (33, 115, 70), "ppt": (183, 71, 42), "pdf": (50, 50, 50)}[self.kind]

    def titlebar_fg(self):
        return (255, 255, 255)

    def draw(self, im, d, x0, y0, w, h):
        fs = self.fs
        col = self.titlebar_color()
        if self.kind != "pdf":
            d.rectangle([x0, y0, x0 + w, y0 + fs(30)], fill=col)
            for i, tab in enumerate(["Fichier", "Accueil", "Insertion", "Création", "Mise en page", "Références", "Révision", "Affichage"]):
                d.text((x0 + fs(16) + i * fs(96), y0 + fs(6)), tab, font=font("ui", fs(13)), fill="white")
            d.rectangle([x0, y0 + fs(30), x0 + w, y0 + fs(130)], fill=(243, 243, 243))
            for g in range(7):
                gx = x0 + fs(10) + g * fs(230)
                for i in range(6):
                    d.rounded_rectangle([gx + (i % 3) * fs(64), y0 + fs(40) + (i // 3) * fs(38), gx + (i % 3) * fs(64) + fs(54), y0 + fs(72) + (i // 3) * fs(38)], radius=3, fill=(205, 210, 218))
                d.line([(gx + fs(212), y0 + fs(40)), (gx + fs(212), y0 + fs(120))], fill=(200, 200, 200))
            top = y0 + fs(130)
        else:
            d.rectangle([x0, y0, x0 + w, y0 + fs(48)], fill=(56, 56, 56))
            top = y0 + fs(48)
        if self.kind == "word":
            d.rectangle([x0, top, x0 + w, y0 + h], fill=(235, 235, 235))
            draw_doc_page(d, self.rng, self.t, self.s, x0, top - fs(90), w, h - (top - y0) + fs(90), fs)
        elif self.kind == "excel":
            draw_grid(d, self.rng, self.t, x0, top, w, h - (top - y0), fs)
            if self.rng.random() < 0.5:
                cx, cy = x0 + int(w * 0.55), top + fs(120)
                d.rectangle([cx, cy, cx + fs(520), cy + fs(320)], fill="white", outline=(150, 150, 150))
                for i in range(8):
                    bh = self.rng.randint(30, 260)
                    d.rectangle([cx + fs(30) + i * fs(60), cy + fs(300) - fs(bh), cx + fs(70) + i * fs(60), cy + fs(300)], fill=(68, 114, 196))
        elif self.kind == "ppt":
            d.rectangle([x0, top, x0 + w, y0 + h], fill=(230, 230, 230))
            for i in range(6):
                d.rectangle([x0 + fs(20), top + fs(20) + i * fs(130), x0 + fs(200), top + fs(120) + i * fs(130)], fill="white", outline=(180, 180, 180))
            sw = min(w - fs(300), int((h - (top - y0) - fs(80)) * 16 / 9))
            sh = int(sw * 9 / 16)
            im.paste(slide(self.rng.randint(0, 10**6), sw, sh), (x0 + fs(260), top + fs(30)))
        else:  # lecteur PDF (tenu a l'ecart)
            d.rectangle([x0, top, x0 + w, y0 + h], fill=(82, 86, 89))
            pw = min(fs(900), int(w * 0.7))
            px = x0 + (w - pw) // 2
            d.rectangle([px, top + fs(20), px + pw, y0 + h], fill="white")
            y = top + fs(90)
            while y < y0 + h - fs(30):
                d.text((px + fs(70), y), sentence(self.rng, 10, 16)[: pw // fs(8)], font=font("serif", fs(15)), fill=(20, 20, 20))
                y += fs(24)


class ChatApp(App):
    cls = "chat"

    def __init__(self, *a, style="discord", **kw):
        super().__init__(*a, **kw)
        self.style = style
        self.proc = {"discord": "discord.exe", "slack": "slack.exe", "whatsapp": "whatsapp.exe", "mail": "outlook.exe"}[style]
        self.title = {"discord": "#général - Discord", "slack": "équipe - Slack", "whatsapp": "WhatsApp", "mail": "Boîte de réception - Outlook"}[style]
        self.dynamic = self.rng.random() < 0.5
        self.new_at = self.rng.randint(1, 4)

    def draw(self, im, d, x0, y0, w, h):
        if self.style == "mail":
            fs, t = self.fs, THEMES["light"]
            d.rectangle([x0, y0, x0 + w, y0 + fs(48)], fill=(0, 120, 212))
            d.rectangle([x0, y0 + fs(48), x0 + fs(240), y0 + h], fill=(243, 242, 241))
            for i, f in enumerate(["Boîte de réception", "Éléments envoyés", "Brouillons", "Archive", "Courrier indésirable"]):
                d.text((x0 + fs(20), y0 + fs(70 + 34 * i)), f, font=font("ui", fs(14)), fill=(30, 30, 30))
            lx = x0 + fs(240)
            for i in range(22):
                yy = y0 + fs(60 + 76 * i)
                if yy > y0 + h - fs(70):
                    break
                d.text((lx + fs(16), yy), self.rng.choice(NAMES) + " " + self.rng.choice(["Martin", "Durand", "Petit"]), font=font("uib" if i < 4 else "ui", fs(15)), fill=(30, 30, 30))
                d.text((lx + fs(16), yy + fs(22)), sentence(self.rng, 3, 7)[:40], font=font("ui", fs(14)), fill=(0, 90, 160))
                d.text((lx + fs(16), yy + fs(44)), sentence(self.rng, 6, 10)[:50], font=font("ui", fs(13)), fill=(100, 100, 100))
            rx = lx + fs(420)
            d.line([(rx, y0 + fs(48)), (rx, y0 + h)], fill=(220, 220, 220))
            d.text((rx + fs(30), y0 + fs(70)), sentence(self.rng, 4, 8), font=font("uisb", fs(22)), fill=(30, 30, 30))
            y = y0 + fs(130)
            while y < y0 + h - fs(40):
                d.text((rx + fs(30), y), sentence(self.rng, 9, 16), font=font("ui", fs(15)), fill=(40, 40, 40))
                y += fs(26)
        else:
            draw_chat(im, d, self.rng, self.style, x0, y0, w, h, self.fs)

    def overlay(self, im, k, x0, y0):
        if k >= self.new_at and self.style != "mail":  # un message arrive (changement ponctuel)
            d = ImageDraw.Draw(im)
            y = y0 + self.h - self.cy - self.fs(150)
            d.rectangle([x0 + self.fs(340), y, x0 + self.w - self.fs(40), y + self.fs(64)], fill=(49, 51, 56) if self.style == "discord" else (255, 255, 255))
            d.text((x0 + self.fs(400), y + self.fs(20)), CHAT[k % len(CHAT)], font=font("ui", self.fs(16)), fill=(220, 220, 220) if self.style == "discord" else (20, 20, 20))


class Explorer(App):
    cls = "other"
    proc = "explorer.exe"

    def __init__(self, *a, settings=False, **kw):
        super().__init__(*a, **kw)
        self.settings = settings
        if settings:
            self.proc = "systemsettings.exe"
        self.title = "Paramètres" if settings else self.rng.choice(["Documents", "Téléchargements", "Images", "Ce PC"])

    def draw(self, im, d, x0, y0, w, h):
        t, fs = self.t, self.fs
        if self.settings:
            d.rectangle([x0, y0, x0 + w, y0 + h], fill=t["panel"])
            for i, s in enumerate(["Système", "Bluetooth et appareils", "Réseau et Internet", "Personnalisation", "Applications", "Comptes", "Heure et langue", "Jeux", "Accessibilité", "Confidentialité", "Windows Update"]):
                d.text((x0 + fs(30), y0 + fs(120 + 44 * i)), s, font=font("ui", fs(15)), fill=t["fg"])
            d.text((x0 + fs(360), y0 + fs(40)), "Système", font=font("uisb", fs(30)), fill=t["fg"])
            for i in range(8):
                yy = y0 + fs(110 + 76 * i)
                d.rounded_rectangle([x0 + fs(360), yy, x0 + w - fs(40), yy + fs(66)], radius=fs(6), fill=t["bg"])
                d.text((x0 + fs(400), yy + fs(10)), sentence(self.rng, 1, 3), font=font("ui", fs(15)), fill=t["fg"])
                d.text((x0 + fs(400), yy + fs(34)), sentence(self.rng, 4, 8), font=font("ui", fs(12)), fill=t["muted"])
                d.rounded_rectangle([x0 + w - fs(120), yy + fs(22), x0 + w - fs(76), yy + fs(44)], radius=fs(11), fill=(0, 103, 192) if self.rng.random() < 0.5 else t["muted"])
            return
        d.rectangle([x0, y0, x0 + w, y0 + fs(48)], fill=t["panel"])
        d.rounded_rectangle([x0 + fs(140), y0 + fs(10), x0 + w - fs(330), y0 + fs(38)], radius=4, fill=t["bg"])
        d.text((x0 + fs(150), y0 + fs(14)), f"Ce PC > Documents > {words(self.rng, 1)}", font=font("ui", fs(13)), fill=t["fg"])
        d.rectangle([x0, y0 + fs(48), x0 + fs(220), y0 + h], fill=t["panel"])
        for i, n in enumerate(["Accueil", "Galerie", "Bureau", "Téléchargements", "Documents", "Images", "Musique", "Vidéos", "Ce PC", "Réseau"]):
            d.text((x0 + fs(20), y0 + fs(70 + 30 * i)), n, font=font("ui", fs(14)), fill=t["fg"])
        y = y0 + fs(90)
        d.text((x0 + fs(240), y0 + fs(60)), "Nom                                     Modifié le              Type            Taille", font=font("ui", fs(13)), fill=t["muted"])
        while y < y0 + h - fs(30):
            d.rectangle([x0 + fs(240), y + fs(3), x0 + fs(256), y + fs(17)], fill=self.rng.choice([(255, 200, 60), (40, 110, 200), (200, 60, 60), (60, 160, 80)]))
            d.text((x0 + fs(266), y), words(self.rng, 2).replace(" ", "_") + self.rng.choice(["", ".pdf", ".docx", ".png", ".zip", ".mp4"]), font=font("ui", fs(14)), fill=t["fg"])
            d.text((x0 + fs(560), y), f"{self.rng.randint(1, 28):02d}/0{self.rng.randint(1, 9)}/2026 {self.rng.randint(8, 22)}:{self.rng.randint(0, 59):02d}", font=font("ui", fs(13)), fill=t["muted"])
            y += fs(28)


class Player(App):
    """Lecteur video de bureau (VLC-like) ou fenetre de jeu / video plein ecran."""

    def __init__(self, *a, clip=None, game=None, **kw):
        super().__init__(*a, **kw)
        self.clipkind = clip
        self.game = game
        if game:
            self.cls = "game"
            self.proc = self.rng.choice(["game.exe", "eldenquest.exe", "javaw.exe", "unity_game.exe", "racer.exe"])
            self.title = self.rng.choice(["Eldenquest", "Minecrafty", "Starfall", "Pixel Hero", "Turbo Rush"])
            self.dynamic = True
            self.seed = self.rng.randint(0, 10**6)
        else:
            self.cls = "video"
            self.proc = self.rng.choice(["vlc.exe", "mpc-hc64.exe", "video.ui.exe", "mpv.exe"])
            self.title = f"{words(self.rng, 2).replace(' ', '_')}.mp4 - Lecteur multimédia"

    def draw(self, im, d, x0, y0, w, h):
        if self.game:
            self.gy0 = y0
            return
        ctrl = self.fs(56) if not self.frameless else 0
        d.rectangle([x0, y0, x0 + w, y0 + h], fill=(0, 0, 0))
        self.video = (x0, y0, w, h - ctrl)
        if ctrl:
            d.rectangle([x0, y0 + h - ctrl, x0 + w, y0 + h], fill=(30, 30, 30))

    def overlay(self, im, k, x0, y0):
        if self.game:
            gh = self.h - self.gy0
            im.paste(game_view(self.seed, self.game, self.w, gh, k), (0, self.gy0))
            return
        super().overlay(im, k, x0, y0)


# ======================================================================================= ecran complet
def wallpaper(rng: random.Random) -> Image.Image:
    if rng.random() < 0.55:
        return to_img(landscape(rng.randint(0, 10**6), 640, 360)).resize((W, H), Image.BICUBIC)
    a = np.zeros((90, 160, 3), np.float32)
    c1, c2 = np.array([rng.randint(0, 255) for _ in range(3)]), np.array([rng.randint(0, 255) for _ in range(3)])
    yy, xx = np.mgrid[0:90, 0:160]
    t = ((np.sin(xx / rng.uniform(10, 40)) + np.cos(yy / rng.uniform(8, 30))) * 0.25 + 0.5)[..., None]
    a = c1 * (1 - t) + c2 * t
    return to_img(a).resize((W, H), Image.BICUBIC).filter(ImageFilter.GaussianBlur(20))


def desktop_icons(im, rng, s):
    d = ImageDraw.Draw(im)
    for i in range(rng.randint(3, 14)):
        x, y = int(20 * s), int((20 + i * 100) * s)
        if y > H - 200:
            break
        d.rounded_rectangle([x + 18 * s, y, x + 66 * s, y + 48 * s], radius=6, fill=(rng.randint(30, 250), rng.randint(30, 250), rng.randint(30, 250)))
        d.text((x, y + 54 * s), words(rng, 1)[:10], font=font("ui", int(12 * s)), fill="white")


def taskbar(im, rng, theme, s):
    d = ImageDraw.Draw(im)
    th = int(48 * s)
    t = THEMES[theme]
    d.rectangle([0, H - th, W, H], fill=(32, 32, 32) if theme == "dark" else (238, 238, 238))
    n = rng.randint(5, 10)
    x = W // 2 - n * int(44 * s) // 2
    for i in range(n):
        d.rounded_rectangle([x + i * 44 * s + 6 * s, H - th + 8 * s, x + i * 44 * s + 38 * s, H - 8 * s], radius=6,
                            fill=(0, 120, 215) if i == 0 else (rng.randint(30, 250), rng.randint(30, 250), rng.randint(30, 250)))
    d.text((W - 110 * s, H - th + 6 * s), f"{rng.randint(8, 23)}:{rng.randint(0, 59):02d}", font=font("ui", int(12 * s)), fill=t["fg"])
    d.text((W - 120 * s, H - th + 24 * s), "07/10/2026", font=font("ui", int(12 * s)), fill=t["fg"])


def shadow(im, x, y, w, h):
    d = ImageDraw.Draw(im, "RGBA")
    for i in range(1, 6):
        d.rectangle([x - i + 4, y - i + 6, x + w + i + 4, y + h + i + 6], outline=(0, 0, 0, 22))


def make_app(rng, cls, theme, s, variant, w, h):
    """Fenetre au premier plan pour une classe donnee (+ sous-type)."""
    a = (rng, w, h, theme, s, variant)
    if cls == "video":
        r = rng.random()
        if r < 0.7:
            app = Browser(*a, page="watch")
            app.cls = "video"
            return app, "browser_watch"
        return Player(*a, clip="file"), "player"
    if cls == "game":
        kinds = ["tps", "fps", "platformer", "strategy"] + (["racing"] if variant == 2 else [])
        return Player(*a, game=rng.choice(kinds)), "game"
    if cls == "work_code":
        if rng.random() < 0.3:
            return Terminal(*a), "terminal"
        return CodeEditor(*a), "editor"
    if cls == "work_docs":
        if rng.random() < 0.2:
            app = Browser(*a, page=rng.choice(["docs", "sheet"]))
            app.cls = "work_docs"
            return app, "browser_docs"
        kind = "pdf" if variant == 2 else rng.choice(["word", "word", "excel", "ppt"])
        return Word(*a, kind=kind), kind
    if cls == "browse":
        page = "wiki" if variant == 2 else rng.choice(["news", "news", "shop", "search", "social"])
        return Browser(*a, page=page), "browser_" + page
    if cls == "chat":
        if rng.random() < 0.15:
            app = Browser(*a, page="webchat")
            app.cls = "chat"
            return app, "browser_chat"
        style = "whatsapp" if variant == 2 else rng.choice(["discord", "discord", "slack", "mail"])
        return ChatApp(*a, style=style), style
    if variant == 2:
        return Explorer(*a, settings=True), "settings"
    return (Explorer(*a), "explorer") if rng.random() < 0.7 else (None, "desktop")


CLASS_WEIGHTS = {"video": 0.24, "game": 0.14, "work_code": 0.13, "work_docs": 0.13, "browse": 0.14, "chat": 0.12, "other": 0.10}
VIDEO_KINDS = ["landscape", "city", "underwater", "sports", "cartoon", "gameplay", "talking", "slides", "landscape2"]


def scenario(seed: int, split: str) -> dict:
    rng = random.Random(seed)
    cls = rng.choices(list(CLASS_WEIGHTS), weights=list(CLASS_WEIGHTS.values()))[0]
    variant = rng.choice([0, 1, 2] if split == "eval" else [0, 1])
    if split == "eval" and variant == 2 and rng.random() < 0.5:
        variant = rng.choice([0, 1])  # ~1/6 des ecrans eval en style tenu a l'ecart
    theme = rng.choice(["dark", "light"])
    s = rng.choice([1.0, 1.25, 1.25, 1.5])
    th = int(48 * s)
    layout = rng.choices(["max", "snap", "float", "full"], weights=[0.55, 0.15, 0.2, 0.1])[0]
    if cls == "game":
        layout = rng.choices(["full", "max", "float"], weights=[0.6, 0.2, 0.2])[0]
    vmode = None
    if cls == "video":
        vmode = rng.choices(["normal", "theater", "full", "pip"], weights=[0.45, 0.2, 0.2, 0.15])[0]
        if vmode == "full":
            layout = "full"
    work_h = H if layout == "full" else H - th
    if layout in ("max", "full"):
        rect = (0, 0, W, work_h)
    elif layout == "snap":
        half = rng.choice([0, 1])
        rect = (half * W // 2, 0, W // 2, work_h)
    else:
        ww, hh = rng.randint(1100, 2100), rng.randint(700, work_h - 60)
        rect = (rng.randint(0, W - ww), rng.randint(0, work_h - hh), ww, hh)
    base = wallpaper(rng)
    desktop_icons(base, rng, s)
    windows = []
    # fenetres d'arriere-plan
    if layout in ("snap", "float") or rng.random() < 0.2:
        for _ in range(rng.randint(1, 2)):
            bcls = rng.choice([c for c in CLASS_WEIGHTS if c not in ("game",)])
            bw, bh = rng.randint(900, 1800), rng.randint(600, work_h - 80)
            bapp, _ = make_app(rng, bcls, rng.choice(["dark", "light"]), s, rng.choice([0, 1]), bw, bh)
            if bapp is None:
                continue
            if isinstance(bapp, Browser) and bapp.page == "watch":
                continue  # pas de video cachee derriere une autre fenetre (etiquette ambigue)
            if isinstance(bapp, Player) and not bapp.game:
                continue
            bx, by = rng.randint(0, W - bw), rng.randint(0, work_h - bh)
            windows.append((bapp, (bx, by, bw, bh)))
    # cote a cote : une video ou un autre document dans l'autre moitie (non masque)
    side_video = None
    if layout == "snap" and rng.random() < 0.35 and cls != "video":
        other_x = W // 2 if rect[0] == 0 else 0
        sapp = Browser(rng, W // 2, work_h, rng.choice(["dark", "light"]), s, rng.choice([0, 1]), page="watch")
        sapp.cls = "video"
        windows.append((sapp, (other_x, 0, W // 2, work_h)))
        side_video = sapp
    if cls == "video" and vmode == "pip":
        fg_cls = rng.choice(["work_code", "work_docs", "browse", "chat"])
        app, sub = make_app(rng, fg_cls, theme, s, variant, rect[2], rect[3])
        label_cls = fg_cls
    else:
        app, sub = make_app(rng, cls, theme, s, variant, rect[2], rect[3])
        label_cls = cls
    vkind = None
    if app is not None:
        if layout == "full":
            app.frameless = True
            if isinstance(app, Browser) and vmode == "full":
                app.page = "full"
        if isinstance(app, Browser) and app.page == "watch" and vmode == "theater":
            app.theater = True
    clips = []

    def attach_clip(a):
        nonlocal vkind
        k = rng.choice(VIDEO_KINDS)
        motion = "static" if k == "slides" else ("talking" if k == "talking" else "moving")
        if motion == "moving" and rng.random() < 0.12:
            motion = "static"  # video en pause
            a.paused = True
        a.clip = Clip(rng.randint(0, 10**6), k, motion if motion != "talking" else "moving")
        a.prog = rng.uniform(0.05, 0.9)
        clips.append(a)
        return k, motion

    if app is not None:
        if isinstance(app, Browser) and app.page == "full":
            # video plein ecran dans le navigateur : toute la surface est le lecteur
            app.page = "watch"
            app.frameless = True
            app._static = Image.new("RGB", (app.w, app.h), (0, 0, 0))
            app.cx = app.cy = 0
            app.video = (0, 0, app.w, app.h)
            app.dynamic = True
        app.render(0)  # dessine le statique (fixe app.video pour les pages video)
        if label_cls == "video" and app.video is not None:
            vkind = attach_clip(app)
        elif isinstance(app, Player) and not app.game and app.video is not None:
            vkind = attach_clip(app)
        if label_cls == "browse" and isinstance(app, Browser) and rng.random() < 0.3:
            app.scroll = rng.randint(40, 160)
            app.dynamic = True
    if side_video is not None:
        side_video.render(0)
        k2 = attach_clip(side_video)
        vkind = vkind or k2
    for bapp, _ in windows:
        bapp.render(0)
    pip = None
    if cls == "video" and vmode == "pip":
        pw = rng.randint(400, 720)
        ph = int(pw * 9 / 16)
        pip_app = Player(rng, pw, ph, "dark", s, 0, clip="pip")
        pip_app.frameless = True
        pip_app.render(0)
        vkind = attach_clip(pip_app)
        pip = (pip_app, (W - pw - rng.randint(20, 80), work_h - ph - rng.randint(20, 120), pw, ph))
    frames = []
    for k in range(N_FRAMES):
        im = base.copy()
        for bapp, (bx, by, bw, bh) in windows:
            shadow(im, bx, by, bw, bh)
            im.paste(bapp.render(k), (bx, by))
        if app is not None:
            if layout != "full":
                shadow(im, *rect)
            im.paste(app.render(k), (rect[0], rect[1]))
        if pip is not None:
            im.paste(pip[0].render(k), (pip[1][0], pip[1][1]))
        if layout != "full":
            taskbar(im, rng if k == 0 else random.Random(seed), theme, s)
        frames.append(im)
    # rectangle video (coordonnees ecran)
    vrect = None
    if pip is not None:
        vrect = list(pip[1])
    elif side_video is not None and side_video.video is not None:
        sx = [r for a, r in windows if a is side_video][0]
        vx, vy, vw, vh = side_video.video
        vrect = [sx[0] + vx, sx[1] + vy, vw, vh]
    elif app is not None and label_cls == "video" and app.video is not None:
        vx, vy, vw, vh = app.video
        vrect = [rect[0] + vx, rect[1] + vy, vw, vh]
    fullscreen = layout == "full"
    return {"frames": frames, "cls": label_cls, "video_rect": vrect,
            "video_kind": None if vkind is None else vkind[0], "video_motion": None if vkind is None else vkind[1],
            "fullscreen": fullscreen, "layout": layout, "sub": sub, "variant": variant, "held_out_style": variant == 2,
            "theme": theme, "scale": s, "vmode": vmode,
            "foreground": {"process": app.proc if app is not None else "explorer.exe", "rect": list(rect),
                           "title": app.title if app is not None else "Bureau"}}


def motion_thumbs(frames) -> np.ndarray:
    return np.stack([np.asarray(f.convert("L").resize((MW, MH), Image.BILINEAR), dtype=np.uint8) for f in frames])


def generate(split: str, n: int, out: Path, start: int = 0, quality: int = 82) -> None:
    out.mkdir(parents=True, exist_ok=True)
    base_seed = {"eval": 9_000_000, "train": 1_000_000}[split]
    labels_path = out / "labels.jsonl"
    done = set()
    if labels_path.exists():
        done = {json.loads(line)["id"] for line in labels_path.open(encoding="utf-8")}
    motions = {}
    mpath = out / "motion.npz"
    if mpath.exists():
        motions = dict(np.load(mpath))
    with labels_path.open("a", encoding="utf-8", newline="\n") as lf:
        for i in range(start, n):
            sid = f"{split[0]}{i:04d}"
            if sid in done:
                continue
            sc = scenario(base_seed + i, split)
            frames = sc.pop("frames")
            frames[-1].save(out / f"{sid}.jpg", quality=quality, optimize=True)
            motions[sid] = motion_thumbs(frames)
            sc["id"] = sid
            lf.write(json.dumps(sc, ensure_ascii=False) + "\n")
            lf.flush()
            if i % 20 == 0:
                np.savez_compressed(mpath, **motions)
                print(f"  {sid} {sc['cls']:9} {sc['sub']:14} video={sc['video_rect']} {sc['video_motion']}", flush=True)
    np.savez_compressed(mpath, **motions)


def preview(n: int, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for i in range(n):
        sc = scenario(9_000_000 + i, "eval")
        f = sc["frames"][-1].copy()
        if sc["video_rect"]:
            x, y, w, h = sc["video_rect"]
            ImageDraw.Draw(f).rectangle([x, y, x + w, y + h], outline=(255, 0, 255), width=6)
        f.resize((1280, 720)).save(out / f"p{i:02d}_{sc['cls']}_{sc['sub']}.jpg", quality=80)
        print(i, sc["cls"], sc["sub"], sc["layout"], sc["vmode"], sc["video_rect"], sc["video_motion"])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", choices=["eval", "train"], default="eval")
    ap.add_argument("--n", type=int, default=360)
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--preview", type=int, default=0)
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    sys.path.insert(0, str(ROOT))
    from pompom_assist.lowprio import set_low_priority

    set_low_priority(idle=True)  # IDLE : ne gene pas les jeux
    if a.preview:
        preview(a.preview, Path(a.out or (ROOT / "dev" / "screens_preview")))
        return
    out = Path(a.out) if a.out else (HERE / "eval_v2" / "vision" if a.split == "eval" else ROOT / "dev" / "vision_train")
    generate(a.split, a.n, out, a.start)


import os  # noqa: E402

if __name__ == "__main__":
    main()
