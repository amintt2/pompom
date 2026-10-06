"""Tests unitaires de la couche de decision.

  .venv\\Scripts\\python.exe -m unittest discover -s tests -v
  set POMPOM_TEST_LLM=gpu   (ou cpu) pour inclure les tests avec le modele local (plus lents)
"""

from __future__ import annotations

import json
import os
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from pompom_assist import rules  # noqa: E402
from pompom_assist.decider import Decider  # noqa: E402


def load(split: str) -> list[dict]:
    with open(ROOT / "data" / f"{split}.jsonl", encoding="utf-8") as f:
        return [json.loads(line) for line in f]


def field(name="", title="", proc="chrome.exe", ctype="edit", **kw) -> dict:
    return dict({"name": name, "window_title": title, "process": proc, "control_type": ctype, "is_password": False}, **kw)


class ContentTypes(unittest.TestCase):
    def test_types(self):
        cases = {
            "lea.martin@gmail.com": "email", "https://example.org/a?b=1": "url", "www.site.fr/x": "url",
            "06 12 34 56 78": "phone", "+33 6 45 12 78 90": "phone", "12/03/1994": "date", "2026-11-02": "date",
            "42": "number", "1 250,00 €": "number", "14 rue des Lilas, 69003 Lyon": "address",
            "def f(x):\n    return x": "code", "SELECT a FROM b WHERE c > 1;": "code", "Léa Martin": "name",
            "dark_kitty92": "username", "on se voit demain ?": "text", "": "text",
        }
        for text, want in cases.items():
            with self.subTest(text=text):
                self.assertEqual(rules.content_type(text), want)


class FieldKinds(unittest.TestCase):
    def test_keywords(self):
        cases = [
            (field("Adresse e-mail"), "email"), (field("Numéro de téléphone"), "phone"),
            (field("Site web"), "url"), (field("Prénom"), "name"), (field("Nom d'utilisateur"), "username"),
            (field("Date de naissance"), "date"), (field("Code postal"), "address"), (field("Montant"), "number"),
            (field("Rechercher"), "search"), (field("Envoyer un message"), "chat_message"),
            (field("", automation_id="txtEmailAddress"), "email"), (field("À", proc="outlook.exe"), "email"),
            (field("", "main.py - Visual Studio Code", "code.exe"), "code"),
        ]
        for f, want in cases:
            with self.subTest(f=f):
                g = rules.guess_field_kind(f)
                self.assertEqual(g.kind, want)
                self.assertGreaterEqual(g.confidence, 0.85)

    def test_ambiguous_goes_low(self):
        g = rules.guess_field_kind(field("Rechercher une adresse"))
        self.assertLess(g.confidence, 0.85)  # deux mots-cles -> le modele tranchera

    def test_password_never_suggested(self):
        d = Decider(None)
        s = d.suggest(field("Mot de passe", is_password=True), ["hunter2", "a@b.fr"])
        self.assertEqual(s.index, -1)
        s = d.suggest({"skip": "password"}, ["hunter2"])
        self.assertEqual((s.index, s.skip), (-1, "password"))


class Suggest(unittest.TestCase):
    def test_email_label(self):
        s = Decider(None).suggest(field("Votre courriel"), ["salut", "bob@exemple.fr", "0612345678"])
        self.assertEqual((s.kind, s.index, s.label_fr), ("email", 1, "Coller ton email ?"))

    def test_newest_matching(self):
        s = Decider(None).suggest(field("Téléphone"), ["06 11 11 11 11", "texte", "07 22 22 22 22"])
        self.assertEqual(s.index, 0)

    def test_none_when_nothing_fits(self):
        s = Decider(None).suggest(field("Adresse e-mail"), ["06 11 11 11 11", "un texte"])
        self.assertEqual(s.index, -1)

    def test_rules_fast(self):
        d = Decider(None)
        rows = load("test")
        t0 = time.perf_counter()
        for r in rows:
            d.suggest(r["field"], r["candidates"])
        per = (time.perf_counter() - t0) * 1000 / len(rows)
        self.assertLess(per, 5.0)

    def test_rules_accuracy_heldout(self):
        d = Decider(None)
        rows = load("test")
        ok = sum(1 for r in rows if (lambda s: s.kind == r["kind"] and s.index == r["best"])(d.suggest(r["field"], r["candidates"])))
        acc = ok / len(rows)
        print(f"\n  regles seules, jeu test : {acc:.3f} ({ok}/{len(rows)})")
        self.assertGreaterEqual(acc, 0.85)


@unittest.skipUnless(os.environ.get("POMPOM_TEST_LLM"), "POMPOM_TEST_LLM non defini")
class WithModel(unittest.TestCase):
    server = None
    dec = None

    @classmethod
    def setUpClass(cls):
        from pompom_assist.llm import LlamaClient, LlamaServer, ServerConfig

        cls.server = LlamaServer(ServerConfig(gpu=os.environ["POMPOM_TEST_LLM"] == "gpu"))
        assert cls.server.start() and cls.server.wait_ready(120), cls.server.error
        cls.dec = Decider(LlamaClient(cls.server.base, 30, cls.server.api_key))

    @classmethod
    def tearDownClass(cls):
        if cls.server:
            cls.server.stop()

    def test_hybrid_accuracy_heldout(self):
        rows = load("test")
        ok = 0
        lat = []
        for r in rows:
            t = time.perf_counter()
            s = self.dec.suggest(r["field"], r["candidates"])
            lat.append((time.perf_counter() - t) * 1000)
            ok += s.kind == r["kind"] and s.index == r["best"]
        lat.sort()
        acc = ok / len(rows)
        print(f"\n  hybride ({self.server.backend}), jeu test : {acc:.3f}  p50={lat[len(lat) // 2]:.1f} ms  "
              f"p95={lat[int(len(lat) * 0.95)]:.1f} ms")
        self.assertGreaterEqual(acc, 0.93)

    def test_generic_choice(self):
        c = self.dec.choose("Le compagnon a très faim. Que fait-il ?", ["manger", "dormir", "jouer"])
        self.assertIn(c.answer, ["manger", "dormir", "jouer"])
        self.assertAlmostEqual(sum(c.probs.values()), 1.0, places=3)


if __name__ == "__main__":
    unittest.main()
