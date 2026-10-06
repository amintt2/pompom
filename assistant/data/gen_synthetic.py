"""Jeu de donnees synthetique : (description de champ, textes copies) -> (sorte de champ, meilleur texte).

Deux vocabulaires DISJOINTS :
  - "dev"  : sert a regler les regles et les exemples du prompt ;
  - "test" : jamais vu pendant le reglage (libelles, sites, applis et textes differents) -> mesure honnete.
Les etiquettes "or" sont fixees par le generateur (intention du scenario), pas par les regles.

Usage : python data/gen_synthetic.py  -> data/dev.jsonl, data/test.jsonl
"""

from __future__ import annotations

import json
import random
from pathlib import Path

HERE = Path(__file__).resolve().parent

# ----------------------------------------------------------------------------------- champs
# sorte -> liste de (process, titre de fenetre, control_type, name, help_text, automation_id)
FIELDS = {
    "dev": {
        "email": [
            ("chrome.exe", "Créer un compte - Fnac", "edit", "Adresse e-mail", "", "email"),
            ("msedge.exe", "Newsletter - Le Monde", "edit", "Votre courriel", "exemple@mail.com", ""),
            ("firefox.exe", "Sign up - GitHub", "edit", "Email*", "", "user_email"),
            ("outlook.exe", "Nouveau message", "edit", "À", "", "toField"),
            ("chrome.exe", "Nouveau message - Gmail", "combobox", "Destinataires", "", ""),
        ],
        "phone": [
            ("chrome.exe", "Livraison - Amazon.fr", "edit", "Numéro de téléphone", "", "address-ui-widgets-enterPhoneNumber"),
            ("msedge.exe", "Prendre rendez-vous - Doctolib", "edit", "Téléphone portable", "06 00 00 00 00", ""),
            ("firefox.exe", "Contact us", "edit", "Phone", "", "phone"),
        ],
        "address": [
            ("chrome.exe", "Livraison - Commande", "edit", "Adresse", "N° et nom de rue", "street"),
            ("firefox.exe", "Checkout", "edit", "Street address", "", "address1"),
            ("msedge.exe", "Itinéraire - Mappy", "edit", "Destination", "", ""),
        ],
        "url": [
            ("chrome.exe", "Profil - LinkedIn", "edit", "Site web", "https://", ""),
            ("firefox.exe", "Insérer un lien", "edit", "URL", "", "linkUrl"),
        ],
        "search": [
            ("chrome.exe", "Google Maps", "combobox", "Rechercher dans Google Maps", "", "searchboxinput"),
            ("msedge.exe", "YouTube", "combobox", "Rechercher", "", "search"),
            ("chrome.exe", "Amazon.fr : livres, DVD, jeux vidéo", "edit", "Rechercher Amazon.fr", "", "twotabsearchtextbox"),
            ("explorer.exe", "Téléchargements", "edit", "Rechercher dans Téléchargements", "", "SearchEditBox"),
        ],
        "name": [
            ("chrome.exe", "Inscription - Club", "edit", "Prénom", "", "firstname"),
            ("firefox.exe", "Checkout", "edit", "Full name", "", "name"),
            ("msedge.exe", "Paiement", "edit", "Nom du titulaire", "", ""),
        ],
        "code": [
            ("code.exe", "main.py - projet - Visual Studio Code", "edit", "The editor is not accessible at this time.", "", ""),
            ("windowsterminal.exe", "PowerShell", "document", "", "", "TermControl"),
            ("notepad++.exe", "script.js - Notepad++", "document", "", "", ""),
        ],
        "chat_message": [
            ("discord.exe", "#général - Discord", "edit", "Envoyer un message dans #général", "", ""),
            ("slack.exe", "équipe - Slack", "edit", "Message #random", "", ""),
            ("chrome.exe", "WhatsApp", "edit", "Taper un message", "", ""),
            ("teams.exe", "Chat | Microsoft Teams", "edit", "Tapez un message", "", ""),
        ],
        "username": [
            ("chrome.exe", "Connexion - Steam", "edit", "Nom de compte Steam", "", ""),
            ("firefox.exe", "Log in", "edit", "Username", "", "login_field"),
        ],
        "number": [
            ("chrome.exe", "Virement", "edit", "Montant", "0,00 €", "amount"),
            ("excel.exe", "Budget.xlsx - Excel", "edit", "Quantité", "", ""),
        ],
        "date": [
            ("chrome.exe", "Réservation - SNCF Connect", "edit", "Date de départ", "JJ/MM/AAAA", ""),
            ("firefox.exe", "Profile", "edit", "Date of birth", "DD/MM/YYYY", "dob"),
        ],
        "other": [
            ("winword.exe", "Document1 - Word", "document", "Page 1 contenu", "", ""),
            ("chrome.exe", "Nouveau message - Gmail", "edit", "Objet", "", ""),
            ("notepad.exe", "Sans titre - Bloc-notes", "document", "Éditeur de texte", "", ""),
        ],
    },
    "test": {
        "email": [
            ("chrome.exe", "Mot de passe oublié - Leboncoin", "edit", "Saisissez votre e-mail", "", "forgot_email"),
            ("msedge.exe", "Inscription - Vinted", "edit", "Adresse électronique", "", ""),
            ("thunderbird.exe", "Rédaction : (pas de sujet)", "edit", "Pour", "", ""),
            ("firefox.exe", "Join the waitlist", "edit", "Work email", "you@company.com", "wl-mail"),
        ],
        "phone": [
            ("chrome.exe", "Paiement - Uber Eats", "edit", "Mobile number", "", "mobile"),
            ("firefox.exe", "Contact - Garage Dupont", "edit", "Tél.", "", "tel"),
            ("msedge.exe", "Ouvrir un compte - Boursorama", "edit", "Numéro de portable", "", ""),
        ],
        "address": [
            ("chrome.exe", "Adresse de livraison - Cdiscount", "edit", "Adresse postale", "", "addr_line"),
            ("firefox.exe", "Shipping info", "edit", "Address line 1", "", "shipping-address"),
            ("msedge.exe", "Waze", "combobox", "Où allez-vous ?", "Choisir une destination", ""),
        ],
        "url": [
            ("chrome.exe", "Nouvelle annonce - Malt", "edit", "Lien vers votre portfolio", "", ""),
            ("firefox.exe", "Add bookmark", "edit", "Location", "https://", "editBMPanel_locationField"),
        ],
        "search": [
            ("chrome.exe", "Spotify - Web Player", "edit", "Que souhaitez-vous écouter ?", "", ""),
            ("firefox.exe", "Leboncoin, site de petites annonces", "combobox", "Rechercher sur leboncoin", "", ""),
            ("msedge.exe", "Wikipédia, l'encyclopédie libre", "combobox", "Search Wikipedia", "", "searchInput"),
            ("chrome.exe", "Plans - OpenStreetMap", "edit", "Chercher", "", "query"),
        ],
        "name": [
            ("chrome.exe", "Réserver une table - TheFork", "edit", "Nom de famille", "", "lastName"),
            ("firefox.exe", "Registration", "edit", "Your name", "", ""),
        ],
        "code": [
            ("pycharm64.exe", "utils.py – PyCharm", "edit", "Editor", "", ""),
            ("devenv.exe", "Program.cs - Microsoft Visual Studio", "document", "Program.cs", "", ""),
            ("cursor.exe", "app.ts - Cursor", "edit", "The editor is not accessible at this time.", "", ""),
        ],
        "chat_message": [
            ("telegram.exe", "Telegram", "edit", "Écrire un message…", "", ""),
            ("chrome.exe", "Messenger | Facebook", "edit", "Aa", "", ""),
            ("signal.exe", "Signal", "edit", "Message", "", ""),
            ("chrome.exe", "Reddit - r/france", "document", "Ajouter un commentaire", "", ""),
        ],
        "username": [
            ("chrome.exe", "Se connecter - Twitch", "edit", "Nom d'utilisateur", "", "login-username"),
            ("firefox.exe", "Battle.net Login", "edit", "Pseudo", "", ""),
        ],
        "number": [
            ("chrome.exe", "Simulateur de prêt", "edit", "Prix du bien", "", "price"),
            ("msedge.exe", "Panier", "edit", "Qty", "", "quantity"),
        ],
        "date": [
            ("chrome.exe", "Billets - Ouigo", "edit", "Aller le", "jj/mm/aaaa", "date-aller"),
            ("firefox.exe", "Booking.com", "edit", "Check-in date", "", "checkin"),
        ],
        "other": [
            ("powerpnt.exe", "Présentation1 - PowerPoint", "document", "Cliquez pour ajouter un titre", "", ""),
            ("onenote.exe", "Notes - OneNote", "document", "Zone de texte", "", ""),
            ("chrome.exe", "Google Docs", "document", "Zone de texte du document", "", ""),
        ],
    },
}

# ----------------------------------------------------------------------------------- textes copies
TEXTS = {
    "dev": {
        "email": ["lea.martin@gmail.com", "j.dupont@orange.fr", "contact@boulangerie-paul.fr"],
        "phone": ["06 12 34 56 78", "+33 7 81 22 90 14", "01.45.67.89.10"],
        "url": ["https://github.com/godotengine/godot", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "www.leroymerlin.fr/produits"],
        "address": ["14 rue des Lilas, 69003 Lyon", "3 avenue Jean Jaurès 75019 Paris", "27 boulevard Victor Hugo, Nice"],
        "number": ["42", "1 250,00 €", "3,5"],
        "date": ["12/03/1994", "2026-11-02", "5 juin 2026"],
        "code": ["def add(a, b):\n    return a + b", "const x = items.map(i => i.id);\nconsole.log(x);",
                 "for i in range(10):\n    print(i)"],
        "name": ["Léa Martin", "Jean Dupont", "Sophie Bernard"],
        "username": ["dark_kitty92", "@lea.m", "pixel_hunter"],
        "text": ["tuto blender cheveux", "chaussures de randonnée", "on se retrouve à 18h devant le cinéma ?",
                 "merci pour hier soir, c'était top"],
    },
    "test": {
        "email": ["marc.petit@free.fr", "s.nguyen@entreprise.com", "hello@studio-lune.io"],
        "phone": ["07 98 76 54 32", "+33 6 45 12 78 90", "04 78 12 34 56"],
        "url": ["https://fr.wikipedia.org/wiki/Lyon", "https://www.instagram.com/p/C9xYz", "https://docs.python.org/3/"],
        "address": ["8 place Bellecour 69002 Lyon", "102 route de Narbonne, 31400 Toulouse", "5 impasse des Roses 44000 Nantes"],
        "number": ["18", "249,99 €", "1500"],
        "date": ["24/12/2026", "03-07-1988", "14 juillet 2027"],
        "code": ["SELECT name, age FROM users WHERE age > 18;", "if (x > 0) {\n  return x;\n}",
                 "import os\nprint(os.getcwd())"],
        "name": ["Marc Petit", "Camille Nguyen", "Hugo Lefèvre"],
        "username": ["moonwalker_77", "lucie.dev", "@zorglub42"],
        "text": ["recette lasagnes végétariennes", "playlist lo-fi pour travailler", "tu peux m'envoyer le doc avant midi ?",
                 "vélo électrique occasion"],
    },
}

STRICT = {"email", "phone", "url", "address", "number", "date", "name", "username", "code"}
# Pour un champ libre : quel type de texte l'utilisateur veut y coller (selon le contexte).
FREE_TARGET = {
    "search": {"Google Maps": "address", "Mappy": "address", "OpenStreetMap": "address", "Waze": "address"},
    "chat_message": {},
}


def _field(kind: str, spec: tuple) -> dict:
    proc, title, ctype, name, help_text, aid = spec
    return {"control_type": ctype, "name": name, "help_text": help_text, "automation_id": aid,
            "process": proc, "window_title": title, "is_password": False, "class_name": "", "label": ""}


def _search_target(title: str) -> str:
    for k, v in FREE_TARGET["search"].items():
        if k in title:
            return v
    return "text"


def make(split: str, n: int, seed: int) -> list[dict]:
    rng = random.Random(seed)
    fields, texts = FIELDS[split], TEXTS[split]
    all_types = list(texts.keys())
    rows = []
    kinds = list(fields.keys())
    for i in range(n):
        kind = kinds[i % len(kinds)]
        spec = rng.choice(fields[kind])
        field = _field(kind, spec)
        # type du texte "voulu"
        if kind in STRICT:
            want = kind
        elif kind == "search":
            want = _search_target(spec[1])
        elif kind == "chat_message":
            want = rng.choice(["text", "url"])
        else:  # other : rien a proposer
            want = None
        n_cand = rng.randint(1, 4)
        has_target = want is not None and rng.random() < 0.8
        distract_types = [t for t in all_types if t != want and not (want in ("text", "url") and t in ("text", "url"))
                          and not (kind == "search" and t in ("text", "name"))]
        if kind == "chat_message":
            distract_types = [t for t in distract_types if t in ("email", "phone", "code", "number", "date")]
        if kind == "search" and want == "address":
            distract_types = [t for t in distract_types if t in ("email", "phone", "code", "date", "number")]
        if kind == "search" and want == "text":
            distract_types = [t for t in distract_types if t in ("email", "phone", "code", "date", "number")]
        cands, types = [], []
        for _ in range(n_cand - (1 if has_target else 0)):
            t = rng.choice(distract_types)
            cands.append(rng.choice(texts[t]))
            types.append(t)
        gold = -1
        if has_target:
            pos = rng.randint(0, len(cands))
            cands.insert(pos, rng.choice(texts[want]))
            types.insert(pos, want)
            gold = pos
        # dedoublonne en gardant l'or coherent
        seen, c2, t2, g2 = set(), [], [], -1
        for j, (c, t) in enumerate(zip(cands, types)):
            if c in seen:
                continue
            if j == gold:
                g2 = len(c2)
            seen.add(c)
            c2.append(c)
            t2.append(t)
        rows.append({"field": field, "kind": kind, "candidates": c2, "types": t2, "best": g2})
    return rows


def main() -> None:
    for split, n, seed in (("dev", 240, 1), ("test", 360, 2)):
        rows = make(split, n, seed)
        with open(HERE / f"{split}.jsonl", "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(split, len(rows))


if __name__ == "__main__":
    main()
