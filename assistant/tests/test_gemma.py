"""Tests du backend EmbeddingGemma 2 (ASSIST_BACKEND=gemma2), sans PyTorch.

  .venv\\Scripts\\python.exe -m unittest tests.test_gemma -v
  (les tests avec le modele sont sautes si models/gemma2/ est absent ; POMPOM_TEST_GEMMA=1 pour les forcer)
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from pompom_assist import vision_strategies as vs  # noqa: E402
from pompom_assist.gemma_onnx import patchify, target_size  # noqa: E402

HAVE = (ROOT / "models" / "gemma2" / "gemma2.json").exists() and (ROOT / "models" / "gemma2" / "text_heads.npz").exists()


class Preprocess(unittest.TestCase):
    def test_target_size_matches_gemma4(self):
        # meme calcul que transformers Gemma4ImageProcessor (budget 70 -> 630 carres max, multiples de 48)
        self.assertEqual(target_size(1440, 2560, 70), (288, 528))
        self.assertEqual(target_size(1440, 2560, 280), (576, 1056))
        th, tw = target_size(480, 853, 70)
        self.assertTrue(th % 48 == 0 and tw % 48 == 0 and (th // 16) * (tw // 16) <= 630)

    def test_patchify_shapes(self):
        from PIL import Image

        pv, pos, n = patchify(Image.new("RGB", (2560, 1440), (10, 20, 30)), 70)
        self.assertEqual(pv.shape, (1, 18 * 33, 768))
        self.assertEqual(pos.shape, (1, 18 * 33, 2))
        self.assertEqual(n, 18 * 33 // 9)
        self.assertAlmostEqual(float(pv[0, 0, 0]), 10 / 255, places=5)
        self.assertEqual(pos[0, 34].tolist(), [1, 1])  # (x, y)


class Strategies(unittest.TestCase):
    def test_rect_from_tiles(self):
        sc = np.zeros(9)
        sc[[0, 1, 3, 4]] = 0.9
        self.assertEqual(vs.rect_from_tiles(sc, 2400, 1200, 3), [0, 0, 1600, 800])
        self.assertIsNone(vs.rect_from_tiles(np.zeros(9), 2400, 1200, 3))

    def test_iou_and_overlap(self):
        self.assertAlmostEqual(vs.iou([0, 0, 10, 10], [0, 0, 10, 10]), 1.0)
        self.assertEqual(vs.iou([0, 0, 10, 10], [20, 20, 5, 5]), 0.0)
        ov = vs.tile_overlap([0, 0, 800, 400], 2400, 1200, 3)
        self.assertAlmostEqual(float(ov[0]), 1.0)
        self.assertAlmostEqual(float(ov[4]), 0.0)


@unittest.skipUnless(HAVE or os.environ.get("POMPOM_TEST_GEMMA"), "models/gemma2 absent (export_gemma_onnx.py)")
class WithGemma(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from pompom_assist.gemma_onnx import GemmaHeads

        cls.heads = GemmaHeads(gpu=False, threads=2)
        cls.heads.warm()

    def test_heads_are_classifiers(self):
        from pompom_assist import rules

        a = self.heads.ask("field_kind", "app: chrome.exe | window: Inscription | control: edit | name: Adresse e-mail")
        self.assertEqual(a.label, "email")
        self.assertIn(a.label, rules.FIELD_KINDS)
        self.assertAlmostEqual(sum(a.probs.values()), 1.0, places=3)
        a = self.heads.ask("text_kind", "field: search | app: chrome.exe | window: Google Maps | control: edit"
                           " | name: Rechercher | copied: text, address", allowed=["text", "address"])
        self.assertIn(a.label, ["text", "address"])

    def test_decider_same_interface(self):
        from pompom_assist.decider import Decider

        d = Decider(self.heads)
        s = d.suggest({"name": "Ton adresse courriel", "process": "chrome.exe", "window_title": "Inscription",
                       "control_type": "edit", "is_password": False}, ["salut", "bob@exemple.fr"])
        self.assertEqual((s.kind, s.index), ("email", 1))
        s = d.suggest({"name": "Code PIN", "process": "chrome.exe", "control_type": "edit", "is_password": False}, ["1234"])
        self.assertEqual(s.index, -1)

    def test_generic_choice(self):
        c = self.heads.choose("Le compagnon a très faim. Que fait-il ?", ["manger", "dormir", "jouer"])
        self.assertIn(c.label, ["manger", "dormir", "jouer"])
        self.assertAlmostEqual(sum(c.probs.values()), 1.0, places=3)


if __name__ == "__main__":
    unittest.main()
