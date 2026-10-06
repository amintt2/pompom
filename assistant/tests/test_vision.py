"""Tests de la vision : carte de mouvement (sans modele) + encodeur SigLIP (si present).

  .venv\\Scripts\\python.exe -m unittest tests.test_vision -v
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from pompom_assist import vision  # noqa: E402
from pompom_assist.vision import MOTION_H, MOTION_W, motion_region  # noqa: E402


def frames_with_video(x0, y0, x1, y1, n=5, seed=0, noise_elsewhere=False):
    rng = np.random.default_rng(seed)
    base = rng.uniform(0, 255, (MOTION_H, MOTION_W)).astype(np.float32)
    out = []
    for _ in range(n):
        f = base.copy()
        f[y0:y1, x0:x1] = rng.uniform(0, 255, (y1 - y0, x1 - x0))
        if noise_elsewhere:
            yy, xx = rng.integers(0, MOTION_H), rng.integers(0, MOTION_W)
            f[yy, xx] = 255 - f[yy, xx]  # un curseur qui clignote
        out.append(f)
    return out


class Motion(unittest.TestCase):
    def test_static_screen_has_no_video(self):
        f = np.full((MOTION_H, MOTION_W), 128, np.float32)
        self.assertIsNone(motion_region([f, f.copy(), f.copy(), f.copy()]))

    def test_finds_moving_rectangle(self):
        r = motion_region(frames_with_video(20, 10, 60, 35, noise_elsewhere=True))
        self.assertIsNotNone(r)
        x0, y0, x1, y1, share, dens = r
        self.assertLessEqual(abs(x0 - 20), 1)
        self.assertLessEqual(abs(y0 - 10), 1)
        self.assertLessEqual(abs(x1 - 60), 1)
        self.assertLessEqual(abs(y1 - 35), 1)
        self.assertAlmostEqual(share, 40 * 25 / (MOTION_W * MOTION_H), delta=0.03)

    def test_fullscreen_motion(self):
        r = motion_region(frames_with_video(0, 0, MOTION_W, MOTION_H))
        self.assertGreater(r[4], 0.95)

    def test_one_off_change_is_not_video(self):
        f = np.full((MOTION_H, MOTION_W), 128, np.float32)
        g = f.copy()
        g[10:30, 10:50] = 0  # une fenetre qui s'ouvre une fois
        self.assertIsNone(motion_region([f, g, g.copy(), g.copy(), g.copy()]))

    def test_needs_three_frames(self):
        self.assertIsNone(motion_region(frames_with_video(5, 5, 50, 40, n=2)))


@unittest.skipUnless((ROOT / "models" / "siglip_vision.fp16.onnx").exists(), "models/ absent (setup.ps1)")
class Encoder(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.eyes = vision.SiglipEyes(gpu=False, threads=2)

    def test_probs_are_distribution(self):
        from PIL import Image

        im = Image.fromarray(np.zeros((360, 640, 3), np.uint8) + 255)
        p = self.eyes.class_probs(self.eyes.embed_images([im])[0], vision.ACTIVITIES, temperature=2.0)
        self.assertEqual(set(p), set(vision.ACTIVITIES))
        self.assertAlmostEqual(sum(p.values()), 1.0, places=4)

    def test_text_screenshot_is_not_video(self):
        from PIL import Image, ImageDraw

        im = Image.new("RGB", (1280, 720), "white")
        d = ImageDraw.Draw(im)
        for i in range(30):
            d.text((40, 20 + i * 22), "def update(self, delta):  return self.speed * delta  # ligne %d" % i, fill="black")
        p = self.eyes.class_probs(self.eyes.embed_images([im])[0], {"video": vision.VIDEO_PROMPTS, "ui": vision.UI_PROMPTS})
        self.assertGreater(p["ui"], p["video"])


if __name__ == "__main__":
    unittest.main()
