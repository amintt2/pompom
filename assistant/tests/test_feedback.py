"""Tests de la boucle de retour : POST /embed (encodeurs simules) + vocabulaire commun jeu / service / serveur.

  .venv\\Scripts\\python.exe -m unittest tests.test_feedback -v
  set POMPOM_TEST_HEADS=1  pour ajouter un test avec le vrai encodeur SigLIP (models/, ~3 s)
"""

from __future__ import annotations

import base64
import http.client
import json
import os
import re
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent
sys.path.insert(0, str(ROOT))

import service  # noqa: E402
from pompom_assist import feedback  # noqa: E402

TOKEN = "t0ken-test"


class FakeEyes:
    path = "siglip_vision.fp16.onnx"

    def embed_images(self, images):
        rng = np.random.default_rng(1)
        v = rng.normal(size=(len(images), 768)).astype(np.float32) * 5.0  # non normalise expres
        return v


class FakeRt:
    cls, sep = 2, 1
    _lock = threading.Lock()

    class enc:  # noqa: N801
        _model_path = "laya_encoder.mixed.onnx"

        @staticmethod
        def run(_names, feeds):
            n = feeds["input_ids"].shape[1]
            return [np.arange(n * 16, dtype=np.float32).reshape(1, n, 16) + 1.0]

    def _ids(self, text):
        return [10 + (ord(c) % 50) for c in text][:40]


class FakeState:
    def __init__(self):
        self.vision = None
        self.decider = type("D", (), {"heads": type("H", (), {"rt": FakeRt()})()})()
        self.heads_state = "ready"

    def use_heads(self):
        pass


def start(state):
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), None)
    port = httpd.server_address[1]
    httpd.RequestHandlerClass = service.make_handler(state, TOKEN, port)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, port


def post(port, path, body, token=TOKEN):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    data = json.dumps(body).encode()
    h = {"content-type": "application/json", "host": f"127.0.0.1:{port}"}
    if token:
        h["x-pompom-token"] = token
    c.request("POST", path, data, h)
    r = c.getresponse()
    out = r.status, json.loads(r.read() or b"{}")
    c.close()
    return out


class Embed(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PIL import Image

        cls.state = FakeState()
        cls.httpd, cls.port = start(cls.state)
        cls.patches = [
            mock.patch.object(feedback.Embedder, "_own_eyes", lambda self: FakeEyes()),
            mock.patch.object(feedback.Embedder, "grab_screen", lambda self: Image.new("RGB", (64, 36))),
            mock.patch("pompom_assist.vision.foreground_info", lambda _own: {"process": "chrome.exe"}),
        ]
        for p in cls.patches:
            p.start()

    @classmethod
    def tearDownClass(cls):
        for p in cls.patches:
            p.stop()
        cls.httpd.shutdown()

    def test_needs_token(self):
        code, _ = post(self.port, "/embed", {}, token="")
        self.assertEqual(code, 401)

    def test_screen_embedding_is_unit_and_tagged(self):
        code, r = post(self.port, "/embed", {})
        self.assertEqual(code, 200)
        self.assertTrue(r["ok"])
        s = r["screen"]
        self.assertEqual(s["dim"], 768)
        self.assertEqual(r["dim"], 768)
        self.assertEqual(s["dtype"], "float32")
        self.assertEqual(r["model_id"], "siglip-b16-224.fp16")
        self.assertTrue(s["model_version"])
        v = feedback.unpack(s)
        self.assertEqual(v.size, 768)
        self.assertAlmostEqual(float(np.linalg.norm(v)), 1.0, places=4)
        self.assertEqual(len(base64.b64decode(s["b64"])), 768 * 4)
        self.assertIsNone(r["text"])

    def test_field_text_embedding_without_title_or_password(self):
        f = {"process": "Chrome.exe", "window_title": "Lea Martin - secret", "control_type": "edit",
             "name": "Adresse e-mail", "is_password": False}
        txt = feedback.field_text(f)
        self.assertNotIn("Lea", txt)
        self.assertNotIn("window", txt)
        code, r = post(self.port, "/embed", {"screen": False, "field": f})
        self.assertEqual(code, 200)
        self.assertIsNone(r["screen"])
        self.assertEqual(r["text"]["dim"], 16)
        self.assertEqual(r["model_id"], "laya-multi-meanpool.mixed")
        self.assertAlmostEqual(float(np.linalg.norm(feedback.unpack(r["text"]))), 1.0, places=4)
        f["is_password"] = True
        code, r = post(self.port, "/embed", {"screen": False, "field": f})
        self.assertIsNone(r["text"])

    def test_private_foreground_is_not_captured(self):
        with mock.patch("pompom_assist.vision.foreground_info", lambda _own: {"process": "Bitwarden.exe"}):
            code, r = post(self.port, "/embed", {})
        self.assertEqual(code, 200)
        self.assertIsNone(r["screen"])
        self.assertEqual(r["errors"]["screen"], "private")
        self.assertFalse(r["ok"])

    def test_float16_roundtrip(self):
        v = feedback.l2(np.arange(1, 129, dtype=np.float32))
        d = {"b64": base64.b64encode(v.astype("<f2").tobytes()).decode(), "dtype": "float16"}
        self.assertTrue(np.allclose(feedback.unpack(d), v, atol=1e-3))


@unittest.skipUnless(os.environ.get("POMPOM_TEST_HEADS") == "1" and (ROOT / "models" / "siglip_prompts.npz").exists(),
                     "POMPOM_TEST_HEADS=1 + models/ pour le vrai encodeur")
class RealEncoder(unittest.TestCase):
    def test_real_siglip(self):
        from PIL import Image

        e = feedback.Embedder(FakeState())
        s = e.screen(Image.new("RGB", (1280, 720), "white"))
        self.assertEqual(s["dim"], 768)
        self.assertTrue(s["model_id"].startswith("siglip-b16-224."))


def _gd_list(src: str, name: str) -> list[str]:
    m = re.search(name + r"\s*:?=\s*\[(.*?)\]", src, re.S)
    return re.findall(r'"([a-z_]+)"', m.group(1)) if m else []


class Vocabulary(unittest.TestCase):
    """Le jeu, le service et le serveur doivent avoir exactement les memes etiquettes."""

    def test_godot_matches(self):
        p = REPO / "godot" / "scripts" / "feedback" / "feedback_store.gd"
        if not p.exists():
            self.skipTest("feedback_store.gd absent")
        src = p.read_text(encoding="utf-8")
        self.assertEqual(_gd_list(src, "ACTIVITY_LABELS"), list(feedback.ACTIVITY_LABELS))
        self.assertEqual(_gd_list(src, "GAME_EVENT_LABELS"), list(feedback.GAME_EVENT_LABELS))
        self.assertEqual(_gd_list(src, "FIELD_KIND_LABELS"), list(feedback.FIELD_KIND_LABELS))

    def test_server_matches(self):
        p = REPO / "server" / "feedback" / "app.py"
        if not p.exists():
            self.skipTest("server absent")
        src = p.read_text(encoding="utf-8")
        for task, labels in feedback.TASKS.items():
            m = re.search(r'"%s":\s*\((.*?)\)' % task, src, re.S)
            self.assertIsNotNone(m, task)
            self.assertEqual(re.findall(r'"([a-z_]+)"', m.group(1)), list(labels), task)


if __name__ == "__main__":
    unittest.main()
