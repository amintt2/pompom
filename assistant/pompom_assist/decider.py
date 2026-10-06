"""Couche de decision : field_kind (quel genre de champ) + best_candidate (quel texte copie coller).

Strategie hybride, derriere une seule interface :
  1. regles (< 1 ms) : mot de passe -> rien ; mots-cles evidents ("email", "telephone"...) -> sorte sure ;
     type de chaque texte copie par regex (email, url, telephone, adresse, date, code...).
  2. modele local (llama-server, sortie contrainte par grammaire) seulement quand c'est ambigu :
     sorte de champ incertaine, ou champ "libre" (recherche, message, code) avec plusieurs textes possibles.
Si le modele n'est pas pret (demarrage, absent, erreur), on retombe sur les regles seules.
"""

from __future__ import annotations

import re
import time
from dataclasses import asdict, dataclass

from . import rules
from .llm import Choice, LlamaClient

KIND_SYSTEM = (
    "You label the text input field that has keyboard focus on a Windows PC, from its accessibility "
    "description (app, window title, field name, placeholder, id). Field text may be French or English.\n"
    "Labels:\n"
    "email: e-mail address or recipient field\n"
    "phone: telephone number\n"
    "address: postal/street address, city, postcode, map destination\n"
    "url: web address / link field\n"
    "search: search box, find, filter, browser address bar\n"
    "name: person's first/last/full name\n"
    "code: code editor, terminal, script or query editor\n"
    "chat_message: message, chat, comment, reply, post or email body\n"
    "username: login, user id, pseudo, handle\n"
    "number: quantity, amount, price, age, numeric value\n"
    "date: date or birthday\n"
    "other: anything else (title, subject, notes, document text)\n"
    "Answer with the label only."
)

_KIND_EXAMPLE_FIELDS = [
    ({"process": "chrome.exe", "window_title": "Créer un compte - Fnac", "control_type": "edit", "name": "Adresse e-mail"}, "email"),
    ({"process": "discord.exe", "window_title": "#général - Discord", "control_type": "edit",
      "name": "Envoyer un message dans #général"}, "chat_message"),
    ({"process": "msedge.exe", "window_title": "Google Maps", "control_type": "combobox",
      "name": "Rechercher dans Google Maps"}, "search"),
    ({"process": "code.exe", "window_title": "main.py - projet - Visual Studio Code", "control_type": "edit",
      "name": "The editor is not accessible at this time."}, "code"),
    ({"process": "firefox.exe", "window_title": "Livraison - Commande", "control_type": "edit", "name": "Ville"}, "address"),
    ({"process": "chrome.exe", "window_title": "Connexion", "control_type": "edit", "name": "Pseudo ou identifiant"}, "username"),
    ({"process": "winword.exe", "window_title": "Document1 - Word", "control_type": "document", "name": "Page 1 contenu"}, "other"),
]

PICK_SYSTEM = (
    "The user focused a text field and copied several kinds of text. Which kind of copied text would they "
    "most likely paste into this field, given the app and window? Kinds: address = postal address or place, "
    "text = words or a sentence, url = web link, name = a person's name, code = source code, "
    "email, phone, number, date, username. Answer with the kind only."
)

# Exemples du jeu "dev" uniquement (le jeu "test" n'a servi qu'a mesurer).
PICK_EXAMPLES = [
    ("Field: search | app: chrome.exe | window: Google Maps | name: Rechercher dans Google Maps\n"
     "Copied: text: \"idées cadeau anniversaire\" ; address: \"14 rue des Lilas, 69003 Lyon\"", "address"),
    ("Field: search | app: msedge.exe | window: YouTube | name: Rechercher\n"
     "Copied: address: \"3 avenue Jean Jaurès 75019 Paris\" ; text: \"tuto blender cheveux\"", "text"),
    ("Field: search | app: msedge.exe | window: Itinéraire - Mappy | name: Rechercher\n"
     "Copied: text: \"chaussures de randonnée\" ; address: \"27 boulevard Victor Hugo, Nice\"", "address"),
    ("Field: search | app: explorer.exe | window: Documents | name: Rechercher dans Documents\n"
     "Copied: address: \"14 rue des Lilas, 69003 Lyon\" ; text: \"facture edf mars\"", "text"),
]


PLAUSIBLE = 0.5  # compatibilite minimale d'un texte avec un champ libre
TIE = 0.05


@dataclass
class Suggestion:
    kind: str
    index: int  # -1 = rien a proposer
    confidence: float
    label_fr: str
    kind_source: str  # rules | llm | rules-fallback
    pick_source: str  # rules | llm | none
    candidate_types: list[str]
    ms: float
    llm_ms: float = 0.0
    skip: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


_BROWSER_SUFFIX = re.compile(r"\s+[-–—]\s+(Google Chrome|Mozilla Firefox|Opera|Brave|Vivaldi|"
                             r"(Personnel|Personal|Profil \d+|Profile \d+)?\s*-?\s*Microsoft.{0,2}Edge)\s*$")


def app_name(field: dict) -> str:
    return str(field.get("process", "") or "")


def window_title(field: dict) -> str:
    return _BROWSER_SUFFIX.sub("", str(field.get("window_title", "") or "")).strip()[:60]


def describe_field(field: dict) -> str:
    """Description du champ pour le modele (chaque token coute ~1 ms sur GPU, ~5 ms sur CPU ; une version
    plus compacte, sans ".exe" ni "control: edit", gagnait ~15 ms mais perdait 3 points sur le jeu test)."""
    parts = [f"app: {app_name(field)}", f"window: {window_title(field)}",
             f"control: {field.get('control_type', '')}"]
    for k, lab in (("name", "name"), ("label", "label"), ("help_text", "placeholder"),
                   ("automation_id", "id"), ("aria_role", "role")):
        v = str(field.get(k, "") or "").strip()
        if v and not (k == "aria_role" and v == "textbox") and not (k == "label" and v == field.get("name")):
            parts.append(f"{lab}: {v[:60]}")
    if "multiline=true" in str(field.get("aria_properties", "")):
        parts.append("multiline")
    return " | ".join(parts)


KIND_EXAMPLES = [(describe_field(f), k) for f, k in _KIND_EXAMPLE_FIELDS]


def _snip(text: str, n: int = 70) -> str:
    s = " ".join(str(text).split())
    return s if len(s) <= n else s[: n - 1] + "…"


class Decider:
    """Interface stable : suggest(field, candidates) -> Suggestion ; field_kind(field) ; choose(...)."""

    def __init__(self, llm: LlamaClient | None = None, kind_threshold: float = 0.85) -> None:
        self.llm = llm
        self.kind_threshold = kind_threshold
        self.use_llm = True

    def llm_ready(self) -> bool:
        return self.llm is not None and self.use_llm

    # ---------------------------------------------------------------- field_kind
    def field_kind(self, field: dict) -> tuple[str, float, str, float]:
        """(sorte, confiance, source, ms_modele)."""
        g = rules.guess_field_kind(field)
        if g.confidence >= self.kind_threshold or not self.llm_ready():
            return g.kind, g.confidence, ("rules" if g.confidence >= self.kind_threshold else "rules-fallback"), 0.0
        try:
            c = self.llm.choose(KIND_SYSTEM, describe_field(field), list(rules.FIELD_KINDS), KIND_EXAMPLES, slot=0)  # type: ignore[union-attr]
        except Exception:
            return g.kind, g.confidence, "rules-fallback", 0.0
        conf = c.confidence
        # Les regles avaient un indice (plusieurs mots-cles) et le modele est d'accord : plus sur.
        if g.confidence >= 0.5 and g.kind == c.answer:
            conf = max(conf, 0.9)
        return c.answer, conf, "llm", c.latency_ms

    # ---------------------------------------------------------------- best_candidate
    def best_candidate(self, field: dict, kind: str, candidates: list[str], types: list[str]) -> tuple[int, float, str, float]:
        """(index ou -1, confiance, source, ms_modele). candidates : du plus recent au plus ancien."""
        if not candidates:
            return -1, 1.0, "none", 0.0
        compat = rules.COMPAT.get(kind, {})
        scored = [(compat.get(t, 0.0), -i, i) for i, t in enumerate(types)]
        scored.sort(reverse=True)
        best_score = scored[0][0]
        if best_score <= 0.0:
            return -1, 0.9, "rules", 0.0
        if kind in rules.STRICT_KINDS:
            # le plus recent texte du bon type
            return scored[0][2], 0.95 * best_score, "rules", 0.0
        # Champ libre (recherche, message, code...) : on garde les textes vraiment plausibles.
        plausible = [x for x in scored if x[0] >= PLAUSIBLE]
        if not plausible:
            return -1, 0.8, "rules", 0.0
        top = plausible[0][0]
        tied = sorted(i for sc, _, i in plausible if sc >= top - TIE)
        if len({types[i] for i in tied}) == 1:
            return tied[0], 0.5 + 0.4 * top, "rules", 0.0  # un seul type en tete : le plus recent
        # Egalite entre types differents (ex. recherche : une adresse ou une phrase ?) : le contexte decide.
        if not self.llm_ready():
            return tied[0], 0.5, "rules", 0.0
        # On demande le TYPE de texte voulu (etiquettes semantiques : pas de biais de position),
        # puis on prend le plus recent texte de ce type.
        newest: dict[str, int] = {}
        for i in tied:
            newest.setdefault(types[i], i)
        opts = list(newest)
        shown = " ; ".join(f'{t}: "{_snip(candidates[i], 50)}"' for t, i in newest.items())
        user = (f"Field: {kind} | app: {app_name(field)} | window: {window_title(field)}"
                + (f" | name: {str(field.get('name', ''))[:60]}" if field.get("name") else "")
                + f"\nCopied: {shown}")
        try:
            c: Choice = self.llm.choose(PICK_SYSTEM, user, opts, PICK_EXAMPLES, slot=1)  # type: ignore[union-attr]
        except Exception:
            return tied[0], 0.5, "rules", 0.0
        return newest[c.answer], c.confidence, "llm", c.latency_ms

    # ---------------------------------------------------------------- tout
    def suggest(self, field: dict, candidates: list[str]) -> Suggestion:
        t0 = time.perf_counter()
        if not field or field.get("skip") or field.get("is_password"):
            return Suggestion("other", -1, 1.0, "", "rules", "none", [], 0.0,
                              skip=str(field.get("skip", "password") if field else "no_field"))
        types = [rules.content_type(c) for c in candidates]
        kind, kconf, ksrc, kms = self.field_kind(field)
        idx, pconf, psrc, pms = self.best_candidate(field, kind, candidates, types)
        conf = kconf * pconf if idx >= 0 else kconf
        label = rules.label_fr(kind, candidates[idx]) if idx >= 0 else ""
        return Suggestion(kind, idx, round(conf, 3), label, ksrc, psrc, types,
                          round((time.perf_counter() - t0) * 1000.0, 2), round(kms + pms, 2))

    # ---------------------------------------------------------------- generique (jeu, etc.)
    def choose(self, question: str, options: list[str], context: str = "", system: str = "",
               examples: list[tuple[str, str]] | None = None) -> Choice:
        """Decision typee generique (ex. choix d'une action du compagnon). Leve RuntimeError sans modele."""
        if not self.llm_ready():
            raise RuntimeError("llm-not-ready")
        sys_msg = system or "Answer with exactly one of the allowed options."
        user = (context + "\n" if context else "") + question + "\nOptions: " + ", ".join(options)
        return self.llm.choose(sys_msg, user, options, examples, slot=2)  # type: ignore[union-attr]
