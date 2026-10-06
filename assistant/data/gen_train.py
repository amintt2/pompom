"""Grand jeu d'entrainement des tetes stuntd (plusieurs milliers de lignes par site de decision).

Vocabulaire COMPOSE (applis x sites x pages x libelles FR/EN x id x placeholders), disjoint du jeu
"test" (data/test.jsonl) : on retire toute ligne qui reprend un libelle, un titre, un id, une aide, un
site ou une appli du jeu test. Les etiquettes viennent du meme oracle que gen_synthetic.make().

Sorties (format `stuntd import` : {"text", "answer"}) :
  data/train_field_kind.jsonl   texte = description du champ            -> sorte de champ (12)
  data/train_text_kind.jsonl    texte = sorte + description + types copies -> type de texte a coller ou none
  data/train.jsonl              lignes brutes (meme format que dev/test)

  python data/gen_train.py [--n 4800]
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import gen_synthetic as gs  # noqa: E402
from pompom_assist.heads import field_text_for_head, text_kind_input  # noqa: E402

BROWSERS = ["chrome.exe", "msedge.exe", "firefox.exe", "opera.exe", "brave.exe", "vivaldi.exe"]
SUFFIX = {"chrome.exe": " - Google Chrome", "msedge.exe": " - Microsoft Edge", "firefox.exe": " — Mozilla Firefox",
          "opera.exe": " - Opera", "brave.exe": " - Brave", "vivaldi.exe": " - Vivaldi"}

SHOP_SITES = ["Fnac", "Amazon.fr", "Darty", "Decathlon", "IKEA", "Zalando", "Boulanger", "La Redoute", "Etsy",
              "AliExpress", "eBay", "Rakuten", "Back Market", "Sephora", "Carrefour", "Auchan", "Leroy Merlin",
              "Castorama", "Nature & Découvertes", "Steam", "Epic Games", "Nintendo eShop", "Shopify", "Asos"]
SERVICE_SITES = ["GitHub", "GitLab", "Notion", "Trello", "Canva", "Dropbox", "Figma", "Airbnb", "Booking", "BlaBlaCar",
                 "Doctolib", "Ameli", "impots.gouv.fr", "CAF", "Pôle emploi", "LinkedIn", "Indeed", "Welcome to the Jungle",
                 "Deezer", "Netflix", "Disney+", "Duolingo", "Strava", "Meetup", "Eventbrite", "Calendly", "Typeform",
                 "Google Forms", "Mairie de Lyon", "SNCF", "Air France", "Free Mobile", "Orange", "SFR", "EDF", "La Poste"]
SEARCH_SITES = ["Google", "Bing", "DuckDuckGo", "Qwant", "Ecosia", "YouTube", "Twitch", "Amazon.fr", "Fnac", "IMDb",
                "Allociné", "Marmiton", "GitHub", "Stack Overflow", "Pinterest", "Reddit", "Wikipédia", "Le Monde",
                "Steam", "Etsy", "Vinted", "Deezer", "Netflix", "Doctolib"]
MAP_SITES = ["Google Maps", "Mappy", "ViaMichelin", "Bing Maps", "Here WeGo", "Citymapper", "Géoportail", "Apple Plans"]
WEB_CHATS = [("WhatsApp Web", "Écrivez un message"), ("Messenger", "Écrivez un message..."), ("Discord", "Envoyer un message"),
             ("Slack", "Envoyer un message à #général"), ("Google Chat", "Message"), ("Instagram", "Votre message…"),
             ("X", "Publier votre réponse"), ("Mastodon", "Qu'avez-vous en tête ?"), ("LinkedIn", "Écrire un message…"),
             ("YouTube", "Ajouter un commentaire…"), ("Twitch", "Envoyer un message"), ("Zendesk", "Répondre au client")]
CHAT_APPS = [("discord.exe", "{chan} - Discord", ["Envoyer un message dans {chan}", "Message {chan}"]),
             ("slack.exe", "{chan} (Canal) - Slack", ["Envoyer un message à {chan}", "Message {chan}"]),
             ("teams.exe", "Conversation | Microsoft Teams", ["Tapez un nouveau message", "Type a new message"]),
             ("ms-teams.exe", "Chat | Microsoft Teams", ["Tapez un message", "Répondre"]),
             ("whatsapp.exe", "WhatsApp", ["Tapez un message", "Type a message"]),
             ("zoom.exe", "Zoom Chat", ["Tapez un message ici…", "Type message here…"]),
             ("skype.exe", "Skype", ["Tapez un message", "Type a message"])]
CHANNELS = ["#général", "#random", "#dev", "#jeux", "#musique", "#annonces", "#support", "#aide", "@Julie", "@Max"]
CODE_APPS = [("code.exe", "{f} - {p} - Visual Studio Code", ["The editor is not accessible at this time.", "Editor content", ""]),
             ("notepad++.exe", "{f} - Notepad++", ["", "Éditeur"]),
             ("sublime_text.exe", "{f} - {p} - Sublime Text", ["", "Editor"]),
             ("idea64.exe", "{p} – {f}", ["Editor", ""]),
             ("windowsterminal.exe", "{shell}", ["", "Terminal"]),
             ("godot.windows.editor.x86_64.exe", "{p} - Godot Engine", ["Éditeur de script", "Script Editor"]),
             ("chrome.exe", "{f} · {p} · GitHub", ["Edit file", "Code editor"]),
             ("rider64.exe", "{p} – {f}", ["Editor"])]
CODE_FILES = ["main.py", "app.js", "index.ts", "player.gd", "server.go", "lib.rs", "query.sql", "build.sh", "Main.java",
              "style.css", "utils.cpp", "deploy.ps1", "views.py", "App.vue", "routes.rb", "api.php"]
PROJECTS = ["pompom", "site-perso", "backend", "jeu-2d", "scripts", "api", "portfolio", "outils"]
SHELLS = ["PowerShell", "Invite de commandes", "Ubuntu", "Git Bash", "Windows PowerShell", "cmd"]

FIELD_LABELS = {
    "email": (["Adresse e-mail", "E-mail", "Email", "Votre adresse mail", "Adresse électronique", "Courriel",
               "Email address", "Your email", "E-mail address", "Mail", "Votre e-mail", "Entrez votre email",
               "Adresse email de contact", "Email de facturation", "Confirmez votre e-mail", "Recipient email",
               "Destinataire", "Email du destinataire"],
              ["email", "emailAddress", "user_email", "txtEmail", "contact-email", "input-email", "mail", "customer_email",
               "login_email", "newsletter-email"],
              ["nom@exemple.fr", "you@example.com", "exemple@domaine.com", "prenom.nom@mail.com", ""]),
    "phone": (["Téléphone", "Numéro de téléphone", "Mobile", "Téléphone portable", "Phone", "Phone number", "Tél",
               "Numéro de mobile", "Portable", "Téléphone fixe", "Contact phone", "Votre numéro", "Numéro de contact",
               "Cell phone", "Téléphone (facultatif)"],
              ["phone", "phoneNumber", "tel", "mobile", "txtPhone", "telephone", "contact_phone", "phone-input", "msisdn"],
              ["06 12 34 56 78", "+33 6 00 00 00 00", "(555) 555-5555", "0X XX XX XX XX", ""]),
    "address": (["Adresse", "Adresse de livraison", "Adresse de facturation", "Rue", "N° et rue", "Street", "Address",
                 "Address line 1", "Code postal", "Ville", "City", "Postal code", "ZIP", "Complément d'adresse",
                 "Adresse postale", "Billing address", "Delivery address", "Lieu de départ", "Arrivée", "Destination"],
                ["address", "street", "address1", "addr", "shipping_address", "billing-street", "zip", "city",
                 "postcode", "txtAddress", "line1"],
                ["12 rue de la Paix", "Numéro et nom de rue", "Ville ou code postal", "Start typing an address", ""]),
    "url": (["Site web", "URL", "Lien", "Website", "Adresse du site", "Lien vers votre profil", "Votre site",
             "Link", "Web address", "Page web", "URL de la vidéo", "Lien de la boutique", "Homepage", "Profile URL"],
            ["url", "website", "link", "homepage", "txtUrl", "site_url", "profile_link", "web"],
            ["https://", "https://exemple.com", "www.", ""]),
    "search": (["Rechercher", "Recherche", "Search", "Rechercher sur {site}", "Search {site}", "Que recherchez-vous ?",
                "Chercher un produit", "Rechercher une vidéo", "Find", "Filtrer", "Rechercher des articles",
                "Search for anything", "Rechercher dans {site}", "Tapez votre recherche"],
               ["search", "q", "query", "searchbox", "search-input", "srch", "global-search", "txtSearch", "searchInput"],
               ["Rechercher", "Search", "Que cherchez-vous ?", "Mots-clés", ""]),
    "name": (["Prénom", "Nom", "Nom complet", "Nom de famille", "First name", "Last name", "Full name", "Your name",
              "Votre nom", "Nom et prénom", "Name", "Titulaire de la carte", "Nom sur la carte", "Surname",
              "Nom du destinataire", "Contact name"],
             ["firstName", "lastName", "fullname", "name", "given-name", "family-name", "txtNom", "prenom", "cardholder"],
             ["Jean Dupont", "Prénom", "Nom", "John Doe", ""]),
    "username": (["Nom d'utilisateur", "Identifiant", "Login", "Username", "Pseudo", "User name", "Nom de compte",
                  "Votre pseudo", "Identifiant de connexion", "User ID", "Handle", "Account name", "Gamertag"],
                 ["username", "login", "user", "userId", "txtLogin", "pseudo", "account", "handle", "login_field_name"],
                 ["Pseudo", "Identifiant", "Username", ""]),
    "number": (["Quantité", "Montant", "Prix", "Nombre de personnes", "Âge", "Amount", "Quantity", "Price",
                "Nombre", "Montant du virement", "Budget", "Poids (kg)", "Surface (m²)", "Number of guests",
                "Nombre d'enfants", "Salaire annuel"],
               ["qty", "amount", "price", "quantity", "nb", "age", "budget", "txtMontant", "guests", "weight"],
               ["0", "0,00 €", "1", "Montant", ""]),
    "date": (["Date", "Date de naissance", "Date d'arrivée", "Date de départ", "Birthday", "Date of birth",
              "Arrival date", "Departure", "Échéance", "Date du rendez-vous", "Date de début", "Date de fin",
              "Start date", "End date", "Retour le"],
             ["date", "dob", "birthdate", "startDate", "endDate", "arrival", "departure", "datepicker", "txtDate"],
             ["JJ/MM/AAAA", "DD/MM/YYYY", "MM/DD/YYYY", "jj/mm/aaaa", ""]),
}
PAGES = {
    "email": ["Inscription", "Créer un compte", "Newsletter", "Contact", "Sign up", "Mot de passe oublié", "Paiement",
              "Mon compte", "Abonnement", "Register", "Nous contacter"],
    "phone": ["Livraison", "Contact", "Mon profil", "Rendez-vous", "Paiement", "Inscription", "Rappel gratuit"],
    "address": ["Livraison", "Adresse de livraison", "Checkout", "Paiement", "Mon compte", "Itinéraire", "Shipping"],
    "url": ["Profil", "Paramètres", "Nouvelle annonce", "Partager", "Insérer un lien", "Mon portfolio", "Settings"],
    "name": ["Inscription", "Paiement", "Réservation", "Contact", "Checkout", "Mon profil", "Candidature"],
    "username": ["Connexion", "Se connecter", "Login", "Sign in", "Créer un compte", "Inscription"],
    "number": ["Panier", "Virement", "Simulateur", "Réservation", "Devis", "Budget", "Calculatrice"],
    "date": ["Réservation", "Inscription", "Rendez-vous", "Billets", "Mon profil", "Booking", "Location"],
}
OTHER_FIELDS = [
    ("winword.exe", "{doc}.docx - Word", "document", ["Page 1 contenu", "Zone de texte du document", ""]),
    ("notepad.exe", "{doc}.txt - Bloc-notes", "document", ["Éditeur de texte", "Text Editor", ""]),
    ("wordpad.exe", "{doc} - WordPad", "document", ["Zone de texte enrichie", ""]),
    ("outlook.exe", "Nouveau message", "edit", ["Objet", "Subject"]),
    ("chrome.exe", "Nouveau message - Gmail", "edit", ["Objet", "Sujet"]),
    ("excel.exe", "{doc}.xlsx - Excel", "edit", ["Barre de formule", "Formula Bar"]),
    ("chrome.exe", "{doc} - Google Docs", "document", ["Contenu du document", ""]),
    ("chrome.exe", "Nouvelle annonce", "edit", ["Titre de l'annonce", "Titre"]),
    ("explorer.exe", "Renommer", "edit", ["Nom du fichier", "Nom"]),
    ("chrome.exe", "Créer un ticket - Jira", "edit", ["Résumé", "Summary"]),
    ("obsidian.exe", "{doc} - Obsidian", "document", ["", "Éditeur"]),
]
DOCS = ["Rapport", "CV", "Lettre", "Notes", "Budget 2026", "Compte rendu", "Liste de courses", "Mémoire", "Facture"]


def _title(proc: str, page: str, site: str) -> str:
    t = f"{page} - {site}" if page else site
    return t + (SUFFIX.get(proc, "") if random.random() < 0.5 else "")


def build_train_fields(rng: random.Random, per_kind: int) -> dict[str, list[tuple]]:
    random.seed(rng.random())
    out: dict[str, list[tuple]] = {k: [] for k in gs.FIELDS["test"]}
    for kind, (labels, aids, phs) in FIELD_LABELS.items():
        sites = (SEARCH_SITES + MAP_SITES) if kind == "search" else (SHOP_SITES + SERVICE_SITES)
        pages = PAGES.get(kind, [""])
        for _ in range(per_kind):
            proc = rng.choice(BROWSERS) if rng.random() < 0.9 else rng.choice(["outlook.exe", "thunderbird.exe", "explorer.exe"] if kind == "email" else BROWSERS)
            site = rng.choice(sites)
            page = rng.choice(pages) if kind != "search" else rng.choice(["", "Accueil", "Résultats", "Home"])
            name = rng.choice(labels).format(site=site)
            r = rng.random()
            if r < 0.12:
                name = ""  # champ sans nom : il reste l'id / l'aide
            elif r < 0.25:
                name += rng.choice(["*", " *", " :", " (obligatoire)", " (optional)"])
            aid = rng.choice(aids) if rng.random() < 0.6 else ""
            ph = rng.choice(phs) if rng.random() < 0.5 else ""
            if not (name or aid or ph):
                aid = rng.choice(aids)
            ctype = "combobox" if kind in ("search", "address") and rng.random() < 0.3 else "edit"
            if kind == "email" and proc in ("outlook.exe",):
                name, page, site = rng.choice(["À", "Cc", "Cci", "To"]), "Nouveau message", "Outlook"
                out[kind].append((proc, "Sans titre - Message (HTML)", "edit", name, "", ""))
                continue
            out[kind].append((proc, _title(proc, page, site), ctype, name, ph, aid))
    for _ in range(per_kind):
        proc, tpl, names = rng.choice(CODE_APPS)
        title = tpl.format(f=rng.choice(CODE_FILES), p=rng.choice(PROJECTS), shell=rng.choice(SHELLS))
        out["code"].append((proc, title, rng.choice(["edit", "document"]), rng.choice(names), "", ""))
        if rng.random() < 0.6:
            proc, tpl, names = rng.choice(CHAT_APPS)
            chan = rng.choice(CHANNELS)
            out["chat_message"].append((proc, tpl.format(chan=chan), "edit", rng.choice(names).format(chan=chan), "", ""))
        else:
            site, ph = rng.choice(WEB_CHATS)
            proc = rng.choice(BROWSERS)
            out["chat_message"].append((proc, _title(proc, "", site), rng.choice(["edit", "document"]),
                                        rng.choice([ph, "Message", "Commentaire", "Répondre", ph]), "", ""))
        proc, tpl, ctype, names = rng.choice(OTHER_FIELDS)
        out["other"].append((proc, tpl.format(doc=rng.choice(DOCS)), ctype, rng.choice(names), "", ""))
    return out


def _test_vocab() -> set[str]:
    v: set[str] = set()
    for specs in gs.FIELDS["test"].values():
        for proc, title, _ct, name, help_text, aid in specs:
            v.update(x.lower() for x in (proc, name, help_text, aid) if x)
            v.update(p.strip().lower() for p in title.split(" - ") if p.strip())
    v -= {"chrome.exe", "msedge.exe", "firefox.exe", "edit", "message", "email", "pseudo", "chercher", "date"}
    return v


def leaks(spec: tuple, vocab: set[str]) -> bool:
    proc, title, _ct, name, help_text, aid = spec
    if any(x and x.lower() in vocab for x in (proc, name, help_text, aid)):
        return True
    return any(p.strip().lower() in vocab for p in title.split(" - "))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4800, help="lignes par site")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    fields = build_train_fields(rng, per_kind=max(60, a.n // 6))
    vocab = _test_vocab()
    dropped = 0
    for k in fields:
        before = len(fields[k])
        fields[k] = [s for s in fields[k] if not leaks(s, vocab)]
        dropped += before - len(fields[k])
    gs.FIELDS["train"] = fields
    gs.TEXTS["train"] = gs.TEXTS["dev"]
    for site in MAP_SITES:
        gs.FREE_TARGET["search"].setdefault(site, "address")
    rows = gs.make("train", a.n, a.seed)
    rng.shuffle(rows)
    with open(HERE / "train.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    seen_fk, seen_tk = set(), set()
    with open(HERE / "train_field_kind.jsonl", "w", encoding="utf-8") as fk, \
         open(HERE / "train_text_kind.jsonl", "w", encoding="utf-8") as tk:
        for r in rows:
            t = field_text_for_head(r["field"])
            if (t, r["kind"]) not in seen_fk:
                seen_fk.add((t, r["kind"]))
                fk.write(json.dumps({"text": t, "answer": r["kind"]}, ensure_ascii=False) + "\n")
            ans = r["types"][r["best"]] if r["best"] >= 0 else "none"
            t2 = text_kind_input(r["kind"], r["field"], r["types"])
            if (t2, ans) not in seen_tk:
                seen_tk.add((t2, ans))
                tk.write(json.dumps({"text": t2, "answer": ans}, ensure_ascii=False) + "\n")
    print(f"train rows {len(rows)}, field_kind unique {len(seen_fk)}, text_kind unique {len(seen_tk)}, "
          f"specs dropped for test overlap {dropped}")


if __name__ == "__main__":
    main()
