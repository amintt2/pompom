"""Regles rapides (regex / mots-cles) : typage des textes copies et pre-classement des champs.

Tout ici tourne en < 1 ms. Les regles ne tranchent que quand c'est evident ; sinon elles
renvoient une confiance faible et le modele local (llama-server) decide.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

FIELD_KINDS = (
    "email", "phone", "address", "url", "search", "name", "code",
    "chat_message", "username", "number", "date", "other",
)

# Types de contenu d'un texte copie.
CONTENT_TYPES = (
    "email", "phone", "url", "address", "number", "date", "code", "name", "username", "text",
)

# Ce que chaque sorte de champ accepte, avec un score de compatibilite 0..1.
COMPAT: dict[str, dict[str, float]] = {
    "email": {"email": 1.0},
    "phone": {"phone": 1.0},
    "url": {"url": 1.0},
    "address": {"address": 1.0},
    "number": {"number": 1.0},
    "date": {"date": 1.0},
    "name": {"name": 1.0},
    "username": {"username": 1.0},
    "code": {"code": 1.0},
    "search": {"text": 0.6, "name": 0.6, "address": 0.6, "url": 0.4, "number": 0.3, "code": 0.25,
               "username": 0.4},
    "chat_message": {"text": 0.7, "url": 0.6, "address": 0.5, "name": 0.4, "email": 0.4, "phone": 0.4,
                     "code": 0.4, "date": 0.3, "number": 0.3, "username": 0.3},
    "other": {"text": 0.3, "name": 0.3, "address": 0.3, "url": 0.3, "email": 0.3, "phone": 0.3},
}

# Types qui identifient a eux seuls la bonne case (on peut proposer sans hesiter).
STRICT_KINDS = {"email", "phone", "url", "address", "number", "date", "name", "username", "code"}


def fold(s: str) -> str:
    """minuscules sans accents, pour comparer des mots-cles FR/EN."""
    s = unicodedata.normalize("NFKD", s or "")
    return "".join(c for c in s if not unicodedata.combining(c)).lower()


# --------------------------------------------------------------------------- textes copies
RE_EMAIL = re.compile(r"^[\w.+-]+@[\w-]+(\.[\w-]+)+$", re.UNICODE)
RE_URL = re.compile(r"^(https?://|www\.)\S+$|^[\w-]+(\.[\w-]+)+/\S*$", re.IGNORECASE)
RE_PHONE = re.compile(r"^\+?[\d\s().-]{8,20}$")
RE_DATE = re.compile(
    r"^(\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}|\d{4}-\d{2}-\d{2}"
    r"|\d{1,2}\s+(janv|fevr|mars|avr|mai|juin|juil|aout|sept|oct|nov|dec|jan|feb|mar|apr|may|jun|jul|aug|sep)\w*\.?\s+\d{2,4})$",
    re.IGNORECASE,
)
RE_NUMBER = re.compile(r"^[-+]?[\d\s]*[\d]([.,]\d+)?\s*(€|\$|%|eur|kg|g|km|m|cm)?$", re.IGNORECASE)
RE_ADDRESS = re.compile(
    r"\b\d{1,4}\s*(bis|ter)?\s*,?\s*(rue|avenue|av\.?|boulevard|bd|chemin|allee|impasse|place|route|quai|cours"
    r"|square|street|st\.?|road|rd\.?|lane|drive|dr\.?|way|calle|strasse|via)\b"
    r"|\b\d{5}\s+[a-z][a-z' -]+$",
    re.IGNORECASE,
)
RE_USERNAME = re.compile(r"^@?[A-Za-z0-9][A-Za-z0-9_.-]{2,30}$")
RE_NAME = re.compile(r"^[A-ZÀ-Ý][a-zà-ÿ'-]+( [A-ZÀ-Ý][a-zà-ÿ'-]+| [A-ZÀ-Ý]{2,}){1,3}$")
CODE_HINTS = re.compile(
    r"(\bdef |\bfunc |\bfunction\b|\breturn\b|=>|\bimport\b|\bclass\b|#include|\bvar |\bconst |\blet "
    r"|;\s*$|\{\s*$|^\s*}|\bif\s*\(|\bfor\s*\(|</\w+>|\bSELECT\b|\$\w+\s*=|\bprint\("
    r"|^\s*(for|while|if|elif|else|try|except|with)\b[^\n]*:\s*$|\w\.\w+\([^)]*\))",
    re.MULTILINE,
)


def content_type(text: str) -> str:
    """Type d'un texte copie : email, phone, url, address, number, date, code, name, username ou text."""
    t = (text or "").strip()
    if not t:
        return "text"
    one_line = "\n" not in t
    if one_line and len(t) <= 254 and RE_EMAIL.match(t):
        return "email"
    if one_line and len(t) <= 2048 and RE_URL.match(t):
        return "url"
    if one_line and RE_DATE.match(fold(t)):
        return "date"
    if one_line and RE_PHONE.match(t) and sum(c.isdigit() for c in t) >= 9:
        return "phone"
    if one_line and len(t) <= 40 and RE_NUMBER.match(t):
        return "number"
    if len(CODE_HINTS.findall(t)) >= 2 or (not one_line and len(CODE_HINTS.findall(t)) >= 1 and t.count(";") + t.count("{") >= 2):
        return "code"
    if len(t) <= 200 and t.count("\n") <= 3 and RE_ADDRESS.search(fold(t)):
        return "address"
    if one_line and len(t) <= 60 and RE_NAME.match(t):
        return "name"
    if one_line and len(t) <= 31 and RE_USERNAME.match(t) and (any(c.isdigit() for c in t) or "_" in t or t.startswith("@") or "." in t):
        return "username"
    return "text"


# --------------------------------------------------------------------------- champs
# mot-cle (replie, sans accent) -> sorte de champ. Ordre = priorite.
FIELD_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("email", ("adresse e-mail", "adresse email", "adresse mail", "adresse electronique", "e-mail address",
               "email address", "e-mail", "email", "courriel", "mail address", "adresse mail", "adresse electronique", "@ ",
               "destinataire", "destinataires", "recipient", "recipients")),
    ("phone", ("numero de telephone", "numero de portable", "numero de mobile", "phone number", "mobile number",
               "telephone", "phone", "mobile", "portable", "tel.", "tel ", "numero de tel", "cellulaire", "gsm")),
    ("url", ("adresse web", "adresse du site", "web address", "url", "website", "site web", "site internet", "lien", "link", "adresse web", "homepage")),
    ("username", ("username", "user name", "nom d'utilisateur", "identifiant", "login", "pseudo", "user id", "handle",
                  "nom de compte", "account name")),
    ("date", ("date", "birthday", "naissance", "jj/mm", "dd/mm", "mm/dd", "aaaa", "yyyy", "echeance")),
    ("address", ("adresse", "address", "street", "rue", "code postal", "zip", "postal", "ville", "city", "destination",
                 "itineraire", "directions")),
    ("name", ("nom complet", "full name", "first name", "last name", "prenom", "surname", "nom de famille", "your name",
              "votre nom", "titulaire", "nom")),
    ("number", ("quantite", "quantity", "montant", "amount", "prix", "price", "nombre", "number", "age", "qty", "iban")),
    ("search", ("search", "recherche", "rechercher", "chercher", "find", "query", "filtrer", "filter", "trouver")),
    ("chat_message", ("message", "envoyer un message", "send a message", "write a message", "ecrire un message",
                      "type a message", "reply", "repondre", "chat", "commentaire", "comment", "tweet", "post")),
]
CODE_APPS = ("code.exe", "devenv.exe", "idea64.exe", "pycharm64.exe", "notepad++.exe", "sublime_text.exe",
             "godot", "cursor.exe", "windowsterminal.exe", "wt.exe", "rider64.exe", "clion64.exe")
MAIL_HEADER_NAMES = {"a", "to", "cc", "cci", "bcc"}  # champs "A :" / "To:" d'un client mail
RE_CODE_TITLE = re.compile(r"\w\.(py|js|ts|tsx|jsx|cs|cpp|cc|c|h|hpp|gd|java|rs|go|rb|php|sql|sh|ps1|lua|kt|swift|vue)\b")
CHAT_APPS = ("discord.exe", "slack.exe", "teams.exe", "ms-teams.exe", "whatsapp.exe", "telegram.exe", "signal.exe",
             "messenger.exe")


@dataclass
class RuleGuess:
    kind: str
    confidence: float
    why: str


def split_ident(s: str) -> str:
    """'txtEmailAddress' / 'user_email' -> 'txt Email Address' / 'user email'."""
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", str(s or ""))
    return re.sub(r"[_\-.:\[\]]+", " ", s)


def field_text(field: dict) -> str:
    """Texte descriptif d'un champ (sans jamais son contenu)."""
    parts = [field.get(k, "") for k in ("name", "help_text", "label", "aria_properties", "localized_type",
                                          "placeholder")]
    parts.append(split_ident(field.get("automation_id", "")))
    return fold(" | ".join(str(p) for p in parts if p))


def guess_field_kind(field: dict) -> RuleGuess:
    """Classement rapide d'un champ. confidence >= 0.9 : sur ; < 0.6 : laisser decider le modele."""
    if field.get("is_password"):
        return RuleGuess("other", 1.0, "password")
    aria = fold(str(field.get("aria_properties", "")))
    for t in ("email", "tel", "url", "search", "date", "number"):
        if f"type={t}" in aria or f"inputtype={t}" in aria or f"autocomplete={t}" in aria:
            return RuleGuess({"tel": "phone"}.get(t, t), 0.97, f"aria:{t}")
    if fold(str(field.get("name", ""))).strip(" :*") in MAIL_HEADER_NAMES:
        return RuleGuess("email", 0.9, "mail-header")
    proc = fold(str(field.get("process", "")))
    ctype = fold(str(field.get("control_type", "")))
    txt = field_text(field)
    hits = []
    for kind, words in FIELD_KEYWORDS:
        for w in words:
            if _has_word(txt, w):
                hits.append((kind, w))
                # la locution est consommee : "adresse e-mail" ne compte pas aussi comme "adresse"
                txt = _strip_word(txt, w)
                break
    if len(hits) == 1:
        kind, w = hits[0]
        conf = 0.9
        return RuleGuess(kind, conf, f"kw:{w}")
    if len(hits) > 1:
        # plusieurs mots-cles : ambigu (ex. "Rechercher une adresse") -> au modele
        return RuleGuess(hits[0][0], 0.5, "kw:" + ",".join(h[1] for h in hits))
    title = fold(str(field.get("window_title", "")))
    if ctype in ("document", "edit", "pane", "custom") and RE_CODE_TITLE.search(title):
        return RuleGuess("code", 0.9, "title:code-file")
    if any(a in proc for a in CODE_APPS) and ctype in ("document", "edit", "pane", "custom"):
        return RuleGuess("code", 0.85, "app:code")
    if any(a in proc for a in CHAT_APPS):
        return RuleGuess("chat_message", 0.85, "app:chat")
    return RuleGuess("other", 0.2, "none")


def _word_re(w: str) -> str:
    return (r"(?<![a-z0-9])" if w[0].isalnum() else "") + re.escape(w) + (r"(?![a-z0-9])" if w[-1].isalnum() else "")


def _has_word(txt: str, w: str) -> bool:
    return re.search(_word_re(w), txt) is not None


def _strip_word(txt: str, w: str) -> str:
    return re.sub(_word_re(w), " ", txt)


# --------------------------------------------------------------------------- libelles FR
LABELS_FR = {
    "email": "Coller ton email ?",
    "phone": "Coller ton numéro ?",
    "address": "Coller l'adresse ?",
    "url": "Coller le lien ?",
    "search": "Chercher « {snip} » ?",
    "name": "Coller « {snip} » ?",
    "code": "Coller ton bout de code ?",
    "chat_message": "Envoyer « {snip} » ?",
    "username": "Coller ton identifiant ?",
    "number": "Coller {snip} ?",
    "date": "Coller la date ({snip}) ?",
    "other": "Coller « {snip} » ?",
}


def label_fr(kind: str, text: str) -> str:
    snip = " ".join((text or "").split())
    if len(snip) > 22:
        snip = snip[:20].rstrip() + "…"
    return LABELS_FR.get(kind, LABELS_FR["other"]).format(snip=snip)
