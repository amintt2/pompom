"""Tests des outils de donnees reelles (tools/) : etiqueteur (appel OpenAI SIMULE, aucune cle utilisee),
construction du jeu de donnees (decoupage par jour, doublons, modeles) et entrainement des tetes.

  .venv\\Scripts\\python.exe -m unittest tests.test_real_tools -v      (numpy + pillow suffisent)
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT))

import build_real_dataset as brd  # noqa: E402
import label_screens as ls  # noqa: E402
import train_real_heads as trh  # noqa: E402
from pompom_assist.feedback import ACTIVITY_LABELS, pack  # noqa: E402

SECRET = "sk-test-NE-JAMAIS-AFFICHER-1234"


def make_screens(d: Path, n: int = 3) -> None:
    from PIL import Image

    d.mkdir(parents=True, exist_ok=True)
    for i in range(n):
        name = f"2026-10-0{i + 1}_12-00-00"
        Image.new("RGB", (128, 72), (40 * i, 80, 120)).save(d / f"{name}.webp", quality=70)
        (d / f"{name}.json").write_text(json.dumps({"proc": "spotify", "title": "Daft Punk", "category": "media",
                                                    "day": f"2026-10-0{i + 1}", "fullscreen": False}), encoding="utf-8")


def fake_openai_response(activity="music"):
    lab = {"activity": activity, "activity_confidence": 0.93, "video_present": False, "video_rect": None,
           "game": None, "hud_event": "none", "hud_event_confidence": 0.9}
    return {"output": [{"type": "message", "content": [{"type": "output_text", "text": json.dumps(lab)}]}],
            "usage": {"input_tokens": 1200, "output_tokens": 90}}


class LabelScreens(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        make_screens(self.dir / "screens")
        self.out = self.dir / "labels.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, *extra):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = ls.main(["--screens", str(self.dir / "screens"), "--out", str(self.out), "--pause", "0", *extra])
        return code, buf.getvalue()

    def test_dry_run_makes_no_call_and_needs_no_key(self):
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": ""}), mock.patch.object(ls, "post_json") as pj:
            code, txt = self.run_main("--dry-run")
        self.assertEqual(code, 0)
        pj.assert_not_called()
        self.assertIn("3 image(s)", txt)
        self.assertIn("$", txt)  # estimation du cout
        self.assertIn("json_schema", txt)
        self.assertFalse(self.out.exists())

    def test_labels_are_written_resumable_and_key_never_printed(self):
        calls = []

        def fake(url, body, headers, timeout=60.0):
            calls.append((url, body, headers))
            return fake_openai_response()

        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": SECRET}), mock.patch.object(ls, "post_json", fake):
            code, txt = self.run_main("--yes")
            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 3)
            url, body, headers = calls[0]
            self.assertEqual(url, "https://api.openai.com/v1/responses")
            self.assertEqual(body["model"], "gpt-6-luna")
            self.assertTrue(body["text"]["format"]["strict"])
            img = body["input"][0]["content"][1]
            self.assertEqual(img["type"], "input_image")
            self.assertTrue(img["image_url"].startswith("data:image/webp;base64,"))
            base64.b64decode(img["image_url"].split(",", 1)[1])
            self.assertEqual(headers["authorization"], "Bearer " + SECRET)
            self.assertNotIn(SECRET, txt)
            rows = [json.loads(x) for x in self.out.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(len(rows), 3)
            self.assertEqual(rows[0]["label"]["activity"], "music")
            self.assertNotIn(SECRET, self.out.read_text(encoding="utf-8"))
            # reprise : rien a refaire
            code, txt = self.run_main("--yes")
        self.assertEqual(len(calls), 3)
        self.assertIn("0 image(s)", txt)

    def test_bad_output_is_rejected(self):
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": SECRET}), \
                mock.patch.object(ls, "post_json", lambda *a, **k: fake_openai_response("cinema")):
            code, txt = self.run_main("--yes", "--limit", "1")
        self.assertEqual(code, 1)
        self.assertIn("hors vocabulaire", txt)
        self.assertFalse(self.out.exists())

    def test_cost_guard(self):
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": SECRET}), mock.patch.object(ls, "post_json") as pj:
            code, _ = self.run_main("--yes", "--max-usd", "0.0000001")
        self.assertEqual(code, 2)
        pj.assert_not_called()

    def test_schema_is_strict(self):
        def walk(s):
            if s.get("type") == "object":
                self.assertFalse(s["additionalProperties"])
                self.assertEqual(set(s["required"]), set(s["properties"]))
                for v in s["properties"].values():
                    walk(v)
            for alt in s.get("anyOf", []):
                walk(alt)
        walk(ls.SCHEMA)


MODELS = {"screen": {"model_id": "siglip-b16-224.fp16", "model_version": "abc"},
          "text": {"model_id": "laya-multi-meanpool.mixed", "model_version": "def"}}


def vec(seed: int, dim: int = 32) -> np.ndarray:
    v = np.random.default_rng(seed).normal(size=dim).astype(np.float32)
    return v / np.linalg.norm(v)


class BuildDataset(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        ds = self.d / "dataset"
        make_screens(ds / "screens")
        labels = []
        for i, img in enumerate(sorted((ds / "screens").glob("*.webp"))):
            labels.append({"file": img.name, "sha1": f"s{i}", "label": {"activity": "music", "activity_confidence": 0.9,
                           "game": None, "hud_event": "none", "hud_event_confidence": 0.9},
                           "meta": json.loads(img.with_suffix(".json").read_text())})
        (self.d / "labels.jsonl").write_text("\n".join(json.dumps(x) for x in labels), encoding="utf-8")
        fb = []
        for i in range(6):
            e = pack(vec(100 + i), **MODELS["screen"])
            fb.append({"id": f"f{i}", "task": "activity", "label": "video", "day": f"2026-10-1{i % 3}", "app": "chrome",
                       "emb": e, "local": {"title": "x"}})
        fb.append({"id": "old", "task": "activity", "label": "video", "day": "2026-10-10",
                   "emb": pack(vec(7), "siglip-b16-224.fp16", "ANCIENNE")})
        fb.append(dict(fb[0], id="dup"))  # doublon exact
        (ds / "feedback.jsonl").write_text("\n".join(json.dumps(x) for x in fb) + "\n{tronque", encoding="utf-8")
        exp = []
        for i in range(4):
            v = vec(200 + i).astype("<f2")
            exp.append({"id": i, "day": "2026-10-2%d" % i, "task": "game_event", "label": "goal", "app": "rocketleague",
                        "model_id": "siglip-b16-224.fp16", "model_version": "abc", "dim": 32, "dtype": "float16",
                        "emb": base64.b64encode(v.tobytes()).decode()})
        (self.d / "export.jsonl").write_text("\n".join(json.dumps(x) for x in exp), encoding="utf-8")
        self.args = argparse.Namespace(dataset=str(ds), labels=str(self.d / "labels.jsonl"),
                                       export=[str(self.d / "export.jsonl")], out=str(self.d / "real"), eval_frac=0.3,
                                       min_conf=0.5)

    def tearDown(self):
        self.tmp.cleanup()

    def test_build(self):
        enc = lambda path, key: vec(abs(hash(key)) % 1000)  # noqa: E731
        m = brd.build(self.args, MODELS, enc)
        self.assertEqual(m["skipped"].get("duplicates"), 1)
        self.assertEqual(m["skipped"].get("feedback_model_mismatch"), 1)
        act = m["tasks"]["activity"]
        n = act.get("train", {}).get("n", 0) + act.get("eval", {}).get("n", 0)
        self.assertEqual(n, 3 + 6)
        self.assertIn("game_event", m["tasks"])
        # aucun jour a la fois en entrainement et en evaluation
        out = Path(self.args.out)
        for task in ("activity", "game_event"):
            tr, ev = out / f"{task}_train.npz", out / f"{task}_eval.npz"
            if tr.exists() and ev.exists():
                with np.load(tr) as a, np.load(ev) as b:
                    self.assertFalse(set(a["day"]) & set(b["day"]))
        self.assertTrue(m["eval_days"])
        p = out / "activity_train.npz" if (out / "activity_train.npz").exists() else out / "activity_eval.npz"
        with np.load(p) as z:
            self.assertTrue(np.allclose(np.linalg.norm(z["X"], axis=1), 1.0, atol=1e-4))
            self.assertEqual(list(z["labels"]), list(ACTIVITY_LABELS))

    def test_split_days(self):
        days = [f"2026-10-{i:02d}" for i in range(1, 31)]
        ev = brd.split_days(days, 0.2)
        self.assertTrue(0 < len(ev) < 30)
        self.assertEqual(ev, brd.split_days(list(reversed(days)), 0.2))  # deterministe
        self.assertEqual(len(brd.split_days(["2026-10-01", "2026-10-02"], 0.0)), 1)


class TrainHeads(unittest.TestCase):
    def test_probe_learns_and_reports(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            rng = np.random.default_rng(0)
            centers = np.stack([vec(i, 64) for i in range(len(ACTIVITY_LABELS))])

            def make(n, days):
                y = rng.integers(0, 5, n)
                X = centers[y] + rng.normal(0, 0.08, (n, 64))
                X /= np.linalg.norm(X, axis=1, keepdims=True)
                return X.astype(np.float32), y

            for split, n in (("train", 300), ("eval", 100)):
                X, y = make(n, None)
                np.savez(d / f"game_event_{split}.npz", X=X, y=y % 9, labels=np.array(trh.TASKS["game_event"]),
                         day=np.array(["d"] * n), source=np.array(["x"] * n), app=np.array([""] * n),
                         text=np.array([""] * n))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                trh.main(["--data", str(d), "--task", "game_event", "--out", str(d / "probes"), "--models",
                          str(d / "nomodels"), "--epochs", "200"])
            rep = json.loads((d / "probes" / "report.json").read_text(encoding="utf-8"))[0]
            self.assertGreater(rep["new_acc"], 0.9)
            self.assertGreater(rep["new_acc"], rep["current_acc"])
            with np.load(d / "probes" / "probe_game_event.npz") as z:
                self.assertEqual(z["W"].shape, (9, 64))
            self.assertIn("game_event", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
