"""eval_v2 (texte) : grand jeu de test FIGE pour les suggestions de collage (field_kind, text_kind, bout en bout).

  python data/gen_eval_v2.py            -> data/eval_v2/text.jsonl (+ statistiques)
  python data/gen_eval_v2.py --check    -> verifie seulement la disjonction avec l'entrainement

Differences avec data/test.jsonl (360 cas, 36 champs) :
  - ~1 700 champs DIFFERENTS (un cas = un champ), francais + anglais + melanges ;
  - descriptions realistes, comme les renvoie focus_probe.py : name, label (<label for>), help_text
    (placeholder), automation_id (id HTML / WPF, y compris des id generes sans sens : ":r4:", "mat-input-3"),
    aria_role (searchbox...), aria_properties ("required=true;..."), localized_type FR, framework, class_name ;
  - applis de bureau et sites jamais vus a l'entrainement ; titres de fenetre avec suffixes de navigateur ;
  - bruit : fautes de frappe, majuscules, abreviations, emoji, "(facultatif)" ;
  - cas adverses / ambigus (tag "adversarial") : "Code promo", "Nom de la rue", "Ville de naissance",
    recherche de personnes, "Email ou numero de mobile", fichier .py ouvert dans le Bloc-notes... ;
  - champs SECRETS (tag "secret") : mots de passe NON marques comme tels, codes SMS / PIN / 2FA, carte, CVC,
    cles d'API, phrases de recuperation, autres langues -> la bonne reponse est TOUJOURS "rien" (index -1).

Vocabulaire DISJOINT de l'entrainement (data/gen_train.py + vocabulaire "dev" de gen_synthetic.py) : chaque
libelle / id / aide / morceau de titre / texte copie est compare (minuscules, sans accents, sans " *:.") au
vocabulaire d'entrainement ; seuls quelques mots generiques inevitables sont toleres (GENERIC_OK).
Les etiquettes "or" sont fixees par l'intention du scenario (comme gen_synthetic.make), jamais par les regles.

Format d'une ligne : {"id", "field", "kind", "candidates", "types", "best", "secret", "lang", "tags", "want"}
  kind  : sorte de champ attendue ("other" pour un champ secret) ; best : index du texte a proposer ou -1 ;
  types : type VOULU de chaque texte copie (le decideur, lui, les retrouve par regex : rules.content_type).
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "eval_v2"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import gen_synthetic as gs  # noqa: E402
import gen_train as gt  # noqa: E402
from pompom_assist import rules  # noqa: E402

SEED = 2026_10_07


def norm(s: str) -> str:
    return rules.fold(str(s or "")).strip(" *:.!?()…").strip()


# mots generiques qu'on ne peut pas eviter (un champ "Email" reste un champ "Email") ; usage rare.
GENERIC_OK = {"email", "e-mail", "message", "date", "search", "url", "nom", "adresse", "rechercher", "password",
              "mot de passe", "telephone", "phone", "pseudo", "chercher", "edit", "document", "", "name", "code",
              "editor", "terminal", "aa"}


def train_vocab() -> set[str]:
    v: set[str] = set()
    sites = (gt.SHOP_SITES + gt.SERVICE_SITES + gt.SEARCH_SITES + gt.MAP_SITES + [s for s, _ in gt.WEB_CHATS])
    for labels, aids, phs in gt.FIELD_LABELS.values():
        for x in labels:
            if "{site}" in x:
                v.update(norm(x.format(site=s)) for s in sites)
            else:
                v.add(norm(x))
        v.update(norm(x) for x in aids + phs)
    v.update(norm(s) for s in sites)
    v.update(norm(p) for _, p in gt.WEB_CHATS)
    for proc, tpl, names in gt.CHAT_APPS:
        v.add(norm(proc))
        for c in gt.CHANNELS:
            v.update(norm(n.format(chan=c)) for n in names)
            v.update(norm(p) for p in tpl.format(chan=c).split(" - "))
    v.update(norm(c) for c in gt.CHANNELS)
    for proc, tpl, names in gt.CODE_APPS:
        v.update(norm(n) for n in names)
    v.update(norm(x) for x in gt.CODE_FILES + gt.PROJECTS + gt.SHELLS + gt.DOCS)
    for pages in gt.PAGES.values():
        v.update(norm(p) for p in pages)
    for proc, tpl, ct, names in gt.OTHER_FIELDS:
        v.update(norm(n) for n in names)
        for d in gt.DOCS:
            v.update(norm(p) for p in tpl.format(doc=d).split(" - "))
    v.update(norm(x) for x in ("Accueil", "Résultats", "Home", "Outlook", "Nouveau message", "Sans titre - Message (HTML)"))
    for specs in gs.FIELDS["dev"].values():
        for proc, title, _ct, name, help_text, aid in specs:
            v.update(norm(x) for x in (name, help_text, aid) if x)
            v.update(norm(p) for p in title.split(" - "))
    for texts in gs.TEXTS["dev"].values():
        v.update(norm(t) for t in texts)
    return v - {""}


# ======================================================================================= vocabulaire eval
BROWSERS = ["chrome.exe"] * 5 + ["msedge.exe"] * 3 + ["firefox.exe"] * 2 + ["brave.exe", "opera.exe", "vivaldi.exe"]
SUFFIX = {"chrome.exe": [" - Google Chrome"], "msedge.exe": [" - Microsoft​ Edge", " - Personnel - Microsoft​ Edge",
                                                              " et 3 pages de plus - Profil 1 - Microsoft Edge"],
          "firefox.exe": [" — Mozilla Firefox", " – Navigation privée de Mozilla Firefox"], "brave.exe": [" - Brave"],
          "opera.exe": [" - Opera"], "vivaldi.exe": [" - Vivaldi"]}
SHOPS = ["Cultura", "ManoMano", "Conforama", "Kiabi", "LDLC", "Materiel.net", "Micromania", "Picard", "Lidl", "Veepee",
         "Showroomprivé", "Alltricks", "Oxybul", "Maisons du Monde", "Bricodépôt", "Monoprix", "Intersport", "Newegg",
         "Best Buy", "Uniqlo", "H&M", "Nike", "Ulule", "Vertbaudet", "Cyrillus", "Gamecash", "Leclerc Drive"]
SERVICES = ["Qonto", "Revolut", "Lydia", "Trainline", "Ryanair", "easyJet", "Vueling", "Transavia", "Getaround",
            "HelloAsso", "Doodle", "Asana", "Miro", "Coursera", "OpenClassrooms", "Udemy", "MAIF", "Crédit Agricole",
            "Société Générale", "Service-public.fr", "France Travail", "ANTS", "Pronote", "Fiverr", "Upwork",
            "Too Good To Go", "Deliveroo", "Bolt", "Lime", "Qobuz", "SoundCloud", "Patreon", "Ko-fi", "Itch.io",
            "GOG.com", "Humble Bundle", "Ubisoft Connect", "Riot Games", "Roblox", "Mutuelle Bleue", "Alan", "Swile"]
SEARCHES = ["Startpage", "Brave Search", "Yahoo", "Lilo", "Kagi", "Dailymotion", "Vimeo", "PeerTube", "Goodreads",
            "Babelio", "Doctissimo", "750g", "Cuisine AZ", "SensCritique", "Letterboxd", "MDN Web Docs", "npm", "PyPI",
            "crates.io", "Hacker News", "Medium", "Wiktionnaire", "Larousse", "Linguee", "WordReference",
            "Thingiverse", "Printables", "ProtonDB", "HowLongToBeat", "Nexus Mods", "Fandom", "Cultura", "Kiabi"]
MAPS = ["Moovit", "Google Earth", "Komoot", "Qwant Maps", "Magic Earth", "Transit", "Île-de-France Mobilités",
        "TCL Itinéraires", "Bonjour RATP", "Organic Maps", "MapQuest"]
PAGES = {
    "signup": ["Créer mon espace", "Ouvrir un compte", "Rejoindre", "Join now", "Create your account", "Get started",
               "S'enregistrer", "Devenir membre"],
    "checkout": ["Finaliser ma commande", "Validation du panier", "Coordonnées", "Mes informations", "Your details",
                 "Order summary", "Livraison et paiement", "Étape 2 sur 4"],
    "profile": ["Mon espace", "Paramètres du compte", "Account settings", "Edit profile", "Modifier mon profil",
                "Préférences"],
    "contact": ["Formulaire de contact", "Get in touch", "Écrivez-nous", "Demande de devis", "Service client"],
    "booking": ["Réserver", "Book now", "Rechercher un trajet", "Votre voyage", "Plan your trip", "Choix des dates"],
    "login": ["Connexion à votre espace", "Log in to continue", "Se connecter à mon compte", "Welcome back",
              "Identification", "Accès client"],
}
KIND_PAGES = {"email": ["signup", "checkout", "contact", "login"], "phone": ["checkout", "contact", "profile", "booking"],
              "address": ["checkout", "profile", "booking"], "url": ["profile", "signup", "contact"],
              "name": ["signup", "checkout", "booking", "contact"], "username": ["login", "signup", "profile"],
              "number": ["checkout", "booking", "profile"], "date": ["booking", "signup", "profile"]}
OPAQUE_IDS = [":r4:", ":R2b6:", "mat-input-3", "input-17", "field_8", "ember412", "react-select-2-input", "__BVID__23",
              "f-12", "a11y-input-5", "TextField42", "headlessui-input-7"]

# sorte -> ([(libelle, langue)], [automation_id], [aide / placeholder])
L = {
    "email": ([("Adresse de courriel", "fr"), ("Ton adresse e-mail", "fr"), ("Saisis ton mail", "fr"),
               ("E-mail professionnel", "fr"), ("Adresse mél", "fr"), ("Mél", "fr"), ("Courriel (requis)", "fr"),
               ("Adresse mail du parent", "fr"), ("Adresse e-mail pour la confirmation", "fr"),
               ("E-mail de connexion", "fr"), ("Votre adresse courriel", "fr"), ("Email perso", "fr"),
               ("Adresse e-mail du bénéficiaire", "fr"), ("Où envoyer le billet ? (e-mail)", "fr"),
               ("Business email", "en"), ("Email ID", "en"), ("Your e-mail address", "en"), ("Enter your email", "en"),
               ("E-mail (we'll never share it)", "en"), ("Work e-mail", "en"), ("Primary email", "en"),
               ("Email for receipt", "en"), ("Billing e-mail", "en"), ("Contact email address", "en"),
               ("Send invoice to (email)", "en"), ("Email adresse", "mix"), ("Votre email address", "mix"),
               ("Mail pro (work email)", "mix"), ("Adrese mail", "fr"), ("E-mial", "en"), ("Emial adress", "en")],
              ["fld-email", "emailInput", "inputMail", "courrielInput", "mel", "e_mail", "signupMail", "EmailAddressField",
               "ctl00$Main$txtCourriel", "user[email]", "contact_mail", "billingEmail", "workEmail"],
              ["prenom@domaine.fr", "ex. : marie.curie@exemple.org", "name@company.com", "votre.adresse@mail.fr",
               "Saisissez votre adresse", "jane.doe@acme.io"]),
    "phone": ([("Tél. mobile", "fr"), ("N° de téléphone", "fr"), ("Portable (pour le livreur)", "fr"),
               ("Téléphone du contact", "fr"), ("Numéro de GSM", "fr"), ("Téléphone domicile", "fr"),
               ("Tél. fixe", "fr"), ("Numéro où vous joindre", "fr"), ("Ligne directe", "fr"),
               ("Téléphone (pour le suivi SMS)", "fr"), ("Numéro de téléphone du conducteur", "fr"),
               ("Mobile phone", "en"), ("Phone (mobile)", "en"), ("Daytime phone", "en"), ("Contact number", "en"),
               ("Telephone no.", "en"), ("Cell", "en"), ("WhatsApp number", "en"), ("Phone for delivery updates", "en"),
               ("Phone portable", "mix"), ("Numéro phone", "mix"), ("Telephnoe", "en"), ("Numéro de télépone", "fr"),
               ("Mobil", "fr")],
              ["tel-mobile", "phoneInput", "txtTelephone", "gsm", "numTel", "mobilePhone", "contact[phone]",
               "telephone_1", "phone_number_field", "msisdn_input", "cellPhone"],
              ["Ex. 06 98 76 54 32", "+33 1 23 45 67 89", "Ex : 0612345678", "+1 (201) 555-0123", "10 chiffres",
               "07 XX XX XX XX"]),
    "address": ([("Adresse complète", "fr"), ("Adresse (numéro et voie)", "fr"), ("Voie", "fr"),
                 ("Numéro et libellé de la voie", "fr"), ("Lieu-dit", "fr"), ("Commune", "fr"),
                 ("Ville de résidence", "fr"), ("CP", "fr"), ("Code postal / Ville", "fr"),
                 ("Bâtiment, étage, digicode", "fr"), ("Adresse du domicile", "fr"), ("Adresse de l'entreprise", "fr"),
                 ("Lieu d'arrivée", "fr"), ("Point de départ", "fr"), ("Adresse de prise en charge", "fr"),
                 ("Où livrer ?", "fr"), ("Address line 2", "en"), ("Town/City", "en"), ("Post code / ZIP", "en"),
                 ("Shipping street", "en"), ("Home address", "en"), ("Pickup location", "en"),
                 ("Drop-off address", "en"), ("Company address", "en"), ("Apt, suite, unit", "en"),
                 ("Adresse street", "mix"), ("Ville / City", "mix"), ("Adrese", "fr"), ("Adresse de livriason", "fr"),
                 ("Code postale", "fr")],
                ["adresse1", "streetAddress", "addressLine2", "txtVoie", "codePostal", "cp", "villeInput", "commune",
                 "deliveryAddress", "pickup-input", "address-autocomplete", "shipping[street]"],
                ["Ex. 10 avenue Foch", "Numéro, rue", "Commencez à saisir votre adresse", "75001", "Enter a location",
                 "Rue, avenue, boulevard…"]),
    "url": ([("Lien de votre site", "fr"), ("Adresse de votre boutique en ligne", "fr"), ("URL du profil", "fr"),
             ("Lien de l'annonce", "fr"), ("Collez le lien ici", "fr"), ("Site internet de l'entreprise", "fr"),
             ("Lien GitHub", "fr"), ("Lien de parrainage", "fr"), ("URL de redirection", "fr"),
             ("Adresse de la page", "fr"), ("Website URL", "en"), ("Portfolio link", "en"), ("Paste a link", "en"),
             ("Profile link", "en"), ("Your website", "en"), ("Link to your work", "en"), ("LinkedIn URL", "en"),
             ("Video link", "en"), ("Source URL", "en"), ("Callback URL", "en"), ("Lien website", "mix"),
             ("URL du site web (link)", "mix"), ("Lein", "fr"), ("Site wbe", "fr"), ("Websit", "en")],
            ["siteWeb", "websiteUrl", "linkInput", "url_field", "portfolioLink", "profileUrl", "lienSite", "homepage_url",
             "redirect_uri", "videoLink"],
            ["https://www.", "https://monsite.fr", "Collez une URL", "http://", "https://youtu.be/…",
             "ex. https://github.com/vous"]),
    "search": ([("Rechercher un article", "fr"), ("Recherche sur le site", "fr"), ("Vous cherchez quoi ?", "fr"),
                ("Rechercher par mot-clé", "fr"), ("Trouver un produit, une marque…", "fr"),
                ("Rechercher dans la boutique", "fr"), ("Chercher une recette", "fr"),
                ("Rechercher un film, une série", "fr"), ("Rechercher dans la documentation", "fr"),
                ("Tapez pour rechercher", "fr"), ("Recherche rapide", "fr"), ("Filtrer les résultats", "fr"),
                ("Rechercher une musique", "fr"), ("Search products", "en"), ("Search the docs", "en"),
                ("Search titles, people, genres", "en"), ("Type to search", "en"), ("Search or jump to…", "en"),
                ("What are you looking for?", "en"), ("Search recipes", "en"), ("Search packages", "en"),
                ("Search this site", "en"), ("Filter by name", "en"), ("Quick search", "en"),
                ("Search produits", "mix"), ("Rechercher (search)", "mix"), ("Recherhcer", "fr"), ("Serach", "en"),
                ("Rechercer un produit", "fr")],
               ["searchBar", "site-search", "q_input", "searchTerm", "keywords", "champRecherche", "headerSearch",
                "search_query", "srchTxt", "docsearch-input", "autocomplete-0-input"],
               ["Rechercher…", "Ex : perceuse sans fil", "Search…", "Tapez un mot-clé", "Titre, auteur, ISBN",
                "Film, série, acteur"]),
    "map": ([("Rechercher un lieu", "fr"), ("Rechercher sur la carte", "fr"), ("Saisir une adresse ou un lieu", "fr"),
             ("Où voulez-vous aller ?", "fr"), ("Destination ou arrêt", "fr"), ("Chercher une adresse", "fr"),
             ("Search places", "en"), ("Search for a place or address", "en"), ("Choose destination", "en"),
             ("Where do you want to go?", "en")],
            ["searchboxMap", "places-search", "geocoder-input", "destinationInput", "omnibox", "trip-to"],
            ["Adresse, lieu, arrêt", "Search Google Earth", "Où allez-vous ?", "Enter an address"]),
    "name": ([("Prénom et nom", "fr"), ("Nom de naissance", "fr"), ("Nom d'usage", "fr"), ("Ton prénom", "fr"),
              ("Prénom(s)", "fr"), ("Nom du titulaire du compte", "fr"), ("Nom du bénéficiaire", "fr"),
              ("Nom de l'enfant", "fr"), ("Nom du conducteur", "fr"), ("Nom et prénom du patient", "fr"),
              ("Given name", "en"), ("Family name", "en"), ("First and last name", "en"), ("Legal name", "en"),
              ("Full legal name", "en"), ("Name on account", "en"), ("Recipient name", "en"),
              ("Cardholder name", "en"), ("Your full name", "en"), ("Middle name", "en"), ("Nom / Name", "mix"),
              ("First name (prénom)", "mix"), ("Prénon", "fr"), ("Nom de famile", "fr"), ("Frist name", "en")],
             ["prenomInput", "nom_famille", "givenName", "familyName", "nomComplet", "holderName", "patient_name",
              "beneficiary", "first-name-input", "lname", "fname", "contact[name]"],
             ["Ex : Marie Dupont", "Prénom Nom", "Jane Smith", "Comme sur votre pièce d'identité", "Ton nom ici"]),
    "username": ([("Ton pseudo", "fr"), ("Pseudonyme", "fr"), ("Nom de joueur", "fr"), ("Identifiant client", "fr"),
                  ("Nom de compte Riot", "fr"), ("ID utilisateur", "fr"), ("Pseudo Discord", "fr"),
                  ("Identifiant Pronote", "fr"), ("Screen name", "en"), ("Player name", "en"),
                  ("Summoner name", "en"), ("Your handle", "en"), ("Account ID", "en"), ("Login name", "en"),
                  ("Gamer tag", "en"), ("Steam ID", "en"), ("Twitch username", "en"),
                  ("Pseudo / username", "mix"), ("Login utilisateur", "mix"), ("Usernmae", "en"), ("Pseuod", "fr"),
                  ("Nom d'utlisateur", "fr")],
                 ["userNameField", "pseudoInput", "loginId", "accountName", "screen_name", "player-name", "handleInput",
                  "user_login", "uid", "nick"],
                 ["Ton pseudo", "@pseudo", "ex. darkvador_75", "Votre identifiant", "Nom d'utilisateur Twitch"]),
    "number": ([("Quantité souhaitée", "fr"), ("Nombre d'adultes", "fr"), ("Nombre de nuits", "fr"),
                ("Montant à transférer", "fr"), ("Montant (€)", "fr"), ("Somme", "fr"), ("Prix maximum", "fr"),
                ("Revenu fiscal de référence", "fr"), ("Nombre de pièces", "fr"), ("Superficie", "fr"),
                ("Kilométrage", "fr"), ("Taille (cm)", "fr"), ("Pourboire", "fr"), ("Note sur 20", "fr"),
                ("Âge de l'enfant", "fr"), ("Number of rooms", "en"), ("Amount (USD)", "en"), ("Max price", "en"),
                ("Mileage", "en"), ("Height (cm)", "en"), ("Tip amount", "en"), ("Units", "en"),
                ("How many tickets?", "en"), ("Donation amount", "en"), ("Annual income", "en"),
                ("Quantity to order", "en"), ("Montant amount", "mix"), ("Qté", "fr"), ("Quantitée", "fr"),
                ("Montnat", "fr"), ("Nombre d'adutles", "fr")],
               ["qte", "nbAdultes", "montantVirement", "price_max", "mileage", "heightCm", "tipAmount", "units",
                "donation", "income", "nb_nuits", "quantity-input"],
               ["Ex : 150", "€", "0.00", "Montant en euros", "1-10", "en cm"]),
    "date": ([("Date d'aller", "fr"), ("Date de retour", "fr"), ("Né(e) le", "fr"), ("Date de début du contrat", "fr"),
              ("Date souhaitée", "fr"), ("Date d'emménagement", "fr"), ("Jour de livraison", "fr"),
              ("Date d'achat", "fr"), ("Valable jusqu'au", "fr"), ("Date du vol", "fr"),
              ("Date de l'événement", "fr"), ("Le (jj/mm/aaaa)", "fr"), ("Check-out date", "en"),
              ("Departure date", "en"), ("Return date", "en"), ("Move-in date", "en"), ("Date of purchase", "en"),
              ("Due date", "en"), ("Event date", "en"), ("Pick a date", "en"), ("Birth date", "en"),
              ("Date de départ (departure)", "mix"), ("Birthdate / Date de naissance", "mix"),
              ("Date de naisance", "fr"), ("Date d'arrivé", "fr"), ("Dat of birth", "en")],
             ["dateAller", "date_retour", "naissanceDate", "dateDebut", "moveInDate", "purchase_date", "dueDate",
              "eventDate", "dp-input", "flatpickr-input", "react-datepicker-1"],
             ["AAAA-MM-JJ", "mm/jj/aaaa", "Sélectionnez une date", "Ex. 14/07/2027", "dd.mm.yyyy", "JJ / MM / AAAA"]),
}
# editeurs de code / terminaux : (process, modele de titre, [noms], control_type)
CODE_E = [("webstorm64.exe", "{p} – {f}", ["Editor", "Fenêtre d'édition"], "edit"),
          ("clion64.exe", "{p} – {f}", ["Editor"], "edit"),
          ("goland64.exe", "{p} – {f}", ["Editor", ""], "edit"),
          ("zed.exe", "{f} — {p}", ["", "Zone d'édition"], "edit"),
          ("vscodium.exe", "{f} - {p} - VSCodium", ["Code editor content", ""], "edit"),
          ("windsurf.exe", "{f} - {p} - Windsurf", ["Code editor content", ""], "edit"),
          ("wezterm-gui.exe", "{shell}", ["", "Terminal input"], "document"),
          ("alacritty.exe", "Alacritty", ["", "Terminal input"], "document"),
          ("mintty.exe", "MINGW64:/c/Users/lea/{p}", ["", "Console"], "document"),
          ("nvim-qt.exe", "{f} - NVIM", ["", "Texte"], "pane"),
          ("powershell_ise.exe", "Windows PowerShell ISE", ["Saisie du script", "Script pane"], "edit"),
          ("cmd.exe", "C:\WINDOWS\system32\cmd.exe - python", ["", "Console"], "document"),
          ("kate.exe", "{f} — Kate", ["", "Zone d'édition"], "edit"),
          ("chrome.exe", "{f} - Replit", ["Éditeur de code", "Monaco editor"], "edit"),
          ("msedge.exe", "{nb}.ipynb - Colab", ["Cellule de code", "Code cell"], "edit"),
          ("firefox.exe", "{p} - CodePen", ["Code editor content", "HTML editor"], "edit"),
          ("chrome.exe", "{p} - StackBlitz", ["Monaco editor", "Editor content area"], "edit"),
          ("brave.exe", "Two Sum - LeetCode", ["Code editor input", "Éditeur de solution"], "edit")]
CODE_FILES_E = ["models.py", "index.html", "game.lua", "parser.rs", "handler.go", "component.tsx", "Cargo.toml",
                "Dockerfile", "schema.graphql", "player_controller.gd", "build.gradle", "main.c", "settings.json",
                "test_api.py", "Makefile", "shader.glsl", "inventory.cs"]
PROJECTS_E = ["mon-site", "pompom-bot", "tp-algo", "infra", "jeu-plateforme", "dotfiles", "stage-2026"]
SHELLS_E = ["pwsh", "zsh", "Administrateur : Windows PowerShell", "bash", "fish"]
NOTEBOOKS = ["analyse_ventes", "TP3", "projet_ml", "brouillon"]
# discussions : (process, titre, [noms]) ; {who} = interlocuteur
CHAT_E = [("element.exe", "Element | {who}", ["Envoyer un message chiffré…", "Send an encrypted message…"]),
          ("mattermost.exe", "{who} - Mattermost", ["Écrire à {who}", "Write to {who}"]),
          ("viber.exe", "Viber", ["Saisir un message…", "Write a message…"]),
          ("wechat.exe", "WeChat", ["", "Saisie"]),
          ("line.exe", "LINE", ["Entrez un message", "Enter a message"]),
          ("rocketchat.exe", "Rocket.Chat", ["Message", "Envoyer un message à {who}"]),
          ("zulip.exe", "Zulip", ["Rédiger un message", "Compose your message"]),
          ("guilded.exe", "Guilded", ["Dire quelque chose", "Say something…"]),
          ("teamspeak.exe", "TeamSpeak", ["Chat"]),
          ("chrome.exe", "Bluesky", ["Rédiger votre réponse", "Write your reply"]),
          ("msedge.exe", "Threads", ["Répondre à {who}…", "Reply to {who}…"]),
          ("firefox.exe", "Tchap", ["Envoie un message…", "Message"]),
          ("chrome.exe", "Google Meet", ["Envoyer un message aux participants", "Send a message to everyone"]),
          ("chrome.exe", "Facebook", ["Écrivez un commentaire…", "Write a comment…"]),
          ("msedge.exe", "TikTok", ["Ajoute un commentaire...", "Add comment..."]),
          ("chrome.exe", "Kick", ["Écrire dans le chat", "Send a message"]),
          ("chrome.exe", "Gitea", ["Leave a comment", "Laisser un commentaire"]),
          ("firefox.exe", "Snapchat", ["Envoyer un chat", "Send a chat"])]
WHO = ["Maman", "Théo", "Inès", "Groupe Rando", "Projet Alpha", "Lucas", "Support client", "Équipe compta"]
# champs sans suggestion attendue (other)
OTHER_E = [("soffice.bin", "{doc}.odt - LibreOffice Writer", "document", ["Vue du document", ""]),
           ("soffice.bin", "{doc}.ods - LibreOffice Calc", "edit", ["Ligne de saisie", "Input line"]),
           ("notion.exe", "{doc}", "document", ["Contenu de la page", "Page content", ""]),
           ("typora.exe", "{doc}.md - Typora", "document", ["", "Zone d'écriture"]),
           ("olk.exe", "Message sans titre - Outlook (nouveau)", "edit", ["Ajouter un objet", "Add a subject"]),
           ("chrome.exe", "Brouillon - Proton Mail", "edit", ["Objet du mail", "Subject line"]),
           ("msedge.exe", "{doc} - Google Sheets", "edit", ["Zone de saisie de la cellule", "Cell input"]),
           ("chrome.exe", "Tableau - Wekan", "edit", ["Titre de la carte", "Card title"]),
           ("firefox.exe", "Nouveau ticket · GitLab", "edit", ["Titre du ticket", "Issue title"]),
           ("chrome.exe", "Google Agenda", "edit", ["Ajouter un titre", "Add title"]),
           ("mspaint.exe", "{doc}.png - Paint", "edit", ["Zone de texte", "Text box"]),
           ("acrord32.exe", "{doc}.pdf - Adobe Acrobat Reader", "edit", ["Champ de texte du formulaire", "Remarques"]),
           ("explorer.exe", "Enregistrer sous", "edit", ["Nom de fichier :", "File name:"]),
           ("chrome.exe", "Publier une vidéo - YouTube Studio", "edit", ["Titre (obligatoire)", "Description"]),
           ("msedge.exe", "Modifier le profil - Malt", "edit", ["Bio", "À propos de vous"]),
           ("chrome.exe", "Déposer une annonce - ParuVendu", "document", ["Description de l'annonce", "Texte de l'annonce"]),
           ("joplin.exe", "Joplin", "document", ["Éditeur de note", "Note body"]),
           ("powerpnt.exe", "{doc}.pptx - PowerPoint", "document", ["Zone de texte pour les commentaires", "Cliquez pour ajouter des notes"])]
DOCS_E = ["rapport_stage", "Mémoire M2", "Réunion lundi", "Devis cuisine", "Notes de cours", "Planning été",
          "Facture 0412", "Lettre de motivation", "Idées cadeaux"]
# secrets : (libelle, langue). Ecrits sans regarder rules.SECRET_WORDS (certains n'y sont pas, volontairement).
SECRETS = [("Mot de passe", "fr"), ("Confirmez le mot de passe", "fr"), ("Nouveau mot de passe", "fr"),
           ("Code PIN", "fr"), ("Code à 6 chiffres", "fr"), ("Code reçu par SMS", "fr"),
           ("Saisissez le code envoyé à votre téléphone", "fr"), ("Code de vérification", "fr"),
           ("Code d'authentification à deux facteurs", "fr"), ("Cryptogramme visuel", "fr"),
           ("Numéro de carte bancaire", "fr"), ("3 chiffres au dos de la carte", "fr"), ("Code de sécurité", "fr"),
           ("Clé API", "fr"), ("Jeton d'accès personnel", "fr"), ("Phrase de récupération (12 mots)", "fr"),
           ("Réponse à la question secrète", "fr"), ("Code d'accès", "fr"), ("Code confidentiel", "fr"),
           ("Mot de passe Wi-Fi", "fr"), ("Clé de sécurité réseau", "fr"), ("Code de déverrouillage", "fr"),
           ("Passphrase de la clé SSH", "fr"), ("Mot de passe actuel", "fr"), ("Mdp", "fr"),
           ("Password", "en"), ("Confirm password", "en"), ("Current password", "en"), ("Enter passcode", "en"),
           ("6-digit code", "en"), ("Authenticator code", "en"), ("Verification code", "en"),
           ("Security code (CVV)", "en"), ("Card number", "en"), ("CVC", "en"), ("API key", "en"),
           ("Personal access token", "en"), ("Secret key", "en"), ("Recovery phrase", "en"), ("Seed words", "en"),
           ("PIN", "en"), ("Master password", "en"), ("Backup code", "en"), ("Enter the code we sent you", "en"),
           ("Wi-Fi password", "en"), ("Network security key", "en"), ("One-time password", "en"),
           ("Passwort", "de"), ("Contraseña", "es"), ("Senha", "pt"), ("Kennwort", "de"), ("Codice OTP", "it")]
SECRET_IDS = ["pwd", "passwordInput", "otp-input", "cc-csc", "cardnumber", "pin_code", "apiKeyField", "totpCode",
              "mfa_code", "passcodeInput", "", "", "", ""]
SECRET_CTX = [("chrome.exe", "Connexion à votre espace - {s}"), ("msedge.exe", "Vérification en deux étapes - {s}"),
              ("firefox.exe", "Paiement sécurisé - {s}"), ("chrome.exe", "Settings · Developer tokens - {s}"),
              ("keepassxc.exe", "Base.kdbx - KeePassXC", ), ("bitwarden.exe", "Bitwarden"),
              ("epicgameslauncher.exe", "Epic Games Launcher"), ("battle.net.exe", "Battle.net"),
              ("riotclientux.exe", "Riot Client"), ("filezilla.exe", "FileZilla"), ("putty.exe", "PuTTY Configuration"),
              ("explorer.exe", "Se connecter à un réseau"), ("anydesk.exe", "AnyDesk"),
              ("metamask.exe", "MetaMask"), ("chrome.exe", "Restore wallet - {s}")]

# ======================================================================================= textes copies (eval)
TEXTS = {
    "email": ["elodie.moreau@laposte.net", "k.benali@outlook.fr", "contact@atelier-sable.com",
              "j.smith+news@proton.me", "facturation@garage-michel.fr", "nina_r@yahoo.co.uk"],
    "phone": ["06 71 23 45 98", "+33 7 52 18 64 30", "01 84 25 66 03", "+32 470 12 34 56", "+41 79 123 45 67",
              "(415) 555-0199", "0781457812", "07.12.45.78.96"],
    "url": ["https://www.lemonde.fr/sciences/article/2026/10/01/exemple.html", "https://youtu.be/aBcD3fGh1Jk",
            "github.com/pompom/assets/issues/12", "https://maps.app.goo.gl/xyz123",
            "https://shop.example.com/p/12345?ref=mail", "www.mairie-annecy.fr/demarches"],
    "address": ["17 rue du Faubourg Saint-Antoine, 75011 Paris", "4 bis chemin des Vignes 13100 Aix-en-Provence",
                "221 avenue Louise, 1050 Bruxelles", "Résidence Les Pins, bât. C\n12 allée des Cèdres\n33600 Pessac",
                "45 quai de la Fosse 44000 Nantes", "9 place du Capitole, Toulouse",
                "1600 Amphitheatre Parkway, Mountain View"],
    "number": ["3", "12 500", "0,75", "99.90 $", "15 %", "2 400 €", "7"],
    "date": ["2027-01-15", "15.01.2027", "1er mars 2027", "08/09/1991", "30 sept. 2026", "March 3, 2027"],
    "code": ["fn main() {\n    println!(\"salut\");\n}", "const res = await fetch(url);\nconst data = await res.json();",
             "git commit -m \"fix: collisions\"", "<div class=\"card\">\n  <h2>{{ title }}</h2>\n</div>",
             "func _ready():\n\tset_process(true)", "UPDATE stock SET qty = qty - 1 WHERE id = 42;",
             "docker run -p 8080:80 nginx"],
    "name": ["Élodie Moreau", "Jean-Baptiste Roux", "Anaïs Le Gall", "Karim Benali", "Sarah O'Connor",
             "Lucas Martin-Dubois"],
    "username": ["kev_du_69", "@miaou.chat", "xX_sn1per_Xx", "lea.codes", "pixelpotato42", "@nina_r"],
    "text": ["meilleur aspirateur sans fil 2026", "tu passes à quelle heure ce soir ?", "horaires piscine dimanche",
             "ok je regarde ça demain", "best budget gaming mouse", "recette pâte à crêpes sans lait",
             "Merci beaucoup pour votre aide !", "comment changer une chambre à air"],
}
OTP_LIKE = ["482913", "7731", "0000", "93 17 42"]
STRICT = {"email", "phone", "url", "address", "number", "date", "name", "username", "code"}
LOCALIZED = {"edit": "modifier", "combobox": "zone de liste déroulante", "document": "document", "pane": "volet"}


# ======================================================================================= construction
def field(proc, title, ctype="edit", name="", aid="", help_text="", label="", role="", aria="", fw="",
          cls="", is_password=False) -> dict:
    if not fw:
        fw = "Chrome" if proc in ("chrome.exe", "msedge.exe", "brave.exe", "opera.exe", "vivaldi.exe") else (
            "Gecko" if proc == "firefox.exe" else "Win32")
    return {"control_type": ctype, "localized_type": LOCALIZED.get(ctype, ctype), "name": name,
            "automation_id": aid, "class_name": cls, "help_text": help_text, "label": label, "framework": fw,
            "aria_role": role, "aria_properties": aria, "is_password": is_password, "process": proc,
            "window_title": title}


def web_title(rng: random.Random, proc: str, page: str, site: str) -> str:
    t = rng.choice([f"{page} - {site}", f"{page} | {site}", f"{site} : {page}", f"{page} – {site}"]) if page else site
    if rng.random() < 0.6:
        t += rng.choice(SUFFIX.get(proc, [""]))
    return t


def web_attrs(rng: random.Random, kind: str, labels, aids, phs) -> dict:
    lab, lang = rng.choice(labels)
    r = rng.random()
    name, label = lab, ""
    if r < 0.10:
        name = ""  # champ sans nom accessible : il reste l'id et/ou le placeholder
    elif r < 0.25:
        label, name = lab, (rng.choice(phs) if rng.random() < 0.5 else lab)  # <label for> + aria-label
    elif r < 0.38:
        name = lab + rng.choice([" *", "*", " :", " (facultatif)", " (optional)", " (obligatoire)"])
    aid = rng.choice(aids) if rng.random() < 0.55 else (rng.choice(OPAQUE_IDS) if rng.random() < 0.5 else "")
    ph = rng.choice(phs) if rng.random() < 0.45 else ""
    if not (name or label or ph):
        ph = rng.choice(phs)
    aria = rng.choice(["", "", "required=true", "required=true;invalid=false", "invalid=false",
                       "autocomplete=list;haspopup=listbox" if kind in ("address", "search") else "required=false"])
    role = ""
    if kind == "search" and rng.random() < 0.4:
        role = "searchbox"
    elif kind in ("address", "search") and rng.random() < 0.25:
        role = "combobox"
    return {"name": name, "label": label, "help_text": ph, "aid": aid, "aria": aria, "role": role, "lang": lang}


def noisy(rng: random.Random, s: str) -> str:
    """Bruit realiste sur un libelle : faute de frappe, majuscules, abreviation, emoji."""
    if not s:
        return s
    r = rng.random()
    if r < 0.35 and len(s) > 4:
        i = rng.randrange(1, len(s) - 2)
        return s[:i] + s[i + 1] + s[i] + s[i + 2:]  # deux lettres inversees
    if r < 0.55 and len(s) > 4:
        i = rng.randrange(1, len(s) - 1)
        return s[:i] + s[i + 1:]  # lettre oubliee
    if r < 0.75:
        return s.upper()
    if r < 0.88:
        return rng.choice(["📧 ", "👉 ", "✏️ ", "★ "]) + s
    return s.lower()


def candidates(rng: random.Random, kind: str, want: str | None, secret: bool = False) -> tuple[list[str], list[str], int]:
    all_types = list(TEXTS)
    if rng.random() < 0.03:
        return [], [], -1
    n_cand = rng.randint(1, 4)
    if secret:
        cands, types = [], []
        for _ in range(n_cand):
            if rng.random() < 0.35:
                cands.append(rng.choice(OTP_LIKE))
                types.append("number")
            else:
                t = rng.choice(all_types)
                cands.append(rng.choice(TEXTS[t]))
                types.append(t)
        return _dedup(cands, types, -1)
    has_target = want is not None and rng.random() < 0.8
    distract = [t for t in all_types if t != want and not (want in ("text", "url") and t in ("text", "url"))
                and not (kind == "search" and t in ("text", "name"))]
    if kind == "chat_message" or (kind == "search" and want in ("text", "address", "name")):
        distract = [t for t in distract if t in ("email", "phone", "code", "number", "date")]
    cands, types = [], []
    for _ in range(n_cand - (1 if has_target else 0)):
        t = rng.choice(distract)
        cands.append(rng.choice(TEXTS[t]))
        types.append(t)
    gold = -1
    if has_target:
        pos = rng.randint(0, len(cands))
        cands.insert(pos, rng.choice(TEXTS[want]))
        types.insert(pos, want)
        gold = pos
    return _dedup(cands, types, gold)


def _dedup(cands, types, gold):
    seen, c2, t2, g2 = set(), [], [], -1
    for j, (c, t) in enumerate(zip(cands, types)):
        if c in seen:
            continue
        if j == gold:
            g2 = len(c2)
        seen.add(c)
        c2.append(c)
        t2.append(t)
    return c2, t2, g2


def build(rng: random.Random) -> list[dict]:
    rows: list[dict] = []
    seen_desc: set[str] = set()

    def add(f: dict, kind: str, want: str | None, lang: str, tags: list[str], secret: bool = False) -> None:
        key = json.dumps({k: f[k] for k in ("process", "window_title", "control_type", "name", "automation_id",
                                             "help_text", "label", "aria_role", "is_password")}, sort_keys=True)
        if key in seen_desc:
            return
        seen_desc.add(key)
        cands, types, best = candidates(rng, kind, want, secret)
        rows.append({"field": f, "kind": kind, "candidates": cands, "types": types, "best": best,
                     "secret": secret, "lang": lang, "tags": tags, "want": want})

    def web_kind(kind: str, n: int, want: str) -> None:
        labels, aids, phs = L[kind]
        tries = 0
        start = len(rows)
        while len(rows) - start < n and tries < n * 20:
            tries += 1
            proc = rng.choice(BROWSERS)
            site = rng.choice(SHOPS + SERVICES)
            page = rng.choice(PAGES[rng.choice(KIND_PAGES[kind])])
            a = web_attrs(rng, kind, labels, aids, phs)
            tags = ["web"]
            if rng.random() < 0.18:
                a["name"] = noisy(rng, a["name"] or a["label"])
                tags.append("noisy")
            f = field(proc, web_title(rng, proc, page, site), "combobox" if (kind == "address" and rng.random() < 0.2) else "edit",
                      a["name"], a["aid"], a["help_text"], a["label"], a["role"], a["aria"])
            add(f, kind, want, a["lang"], tags)

    for kind, n in (("email", 140), ("phone", 115), ("address", 135), ("url", 100), ("name", 120),
                    ("username", 105), ("number", 115), ("date", 115)):
        web_kind(kind, n, kind)

    # recherche (sites) : on veut coller une phrase
    labels, aids, phs = L["search"]
    start = len(rows)
    while len(rows) - start < 130:
        proc = rng.choice(BROWSERS)
        site = rng.choice(SEARCHES)
        a = web_attrs(rng, "search", labels, aids, phs)
        tags = ["web"]
        if rng.random() < 0.18:
            a["name"] = noisy(rng, a["name"] or a["label"])
            tags.append("noisy")
        page = rng.choice(["", "", "Résultats de recherche", "Search results", "Tous les produits"])
        f = field(proc, web_title(rng, proc, page, site), rng.choice(["edit", "combobox"]), a["name"], a["aid"],
                  a["help_text"], a["label"], a["role"], a["aria"])
        add(f, "search", "text", a["lang"], tags)
    # recherche sur une carte : on veut coller une adresse
    labels, aids, phs = L["map"]
    start = len(rows)
    while len(rows) - start < 60:
        proc = rng.choice(BROWSERS)
        site = rng.choice(MAPS)
        a = web_attrs(rng, "search", labels, aids, phs)
        f = field(proc, web_title(rng, proc, "", site), rng.choice(["edit", "combobox"]), a["name"], a["aid"],
                  a["help_text"], a["label"], a["role"], a["aria"])
        add(f, "search", "address", a["lang"], ["web", "map"])
    # code
    start = len(rows)
    while len(rows) - start < 110:
        proc, tpl, names, ctype = rng.choice(CODE_E)
        title = tpl.format(f=rng.choice(CODE_FILES_E), p=rng.choice(PROJECTS_E), shell=rng.choice(SHELLS_E),
                           nb=rng.choice(NOTEBOOKS))
        if proc in BROWSERS and rng.random() < 0.6:
            title += rng.choice(SUFFIX.get(proc, [""]))
        nm = rng.choice(names)
        cls = {"wezterm-gui.exe": "org.wezfurlong.wezterm", "cmd.exe": "ConsoleWindowClass", "mintty.exe": "mintty",
               "powershell_ise.exe": "", "alacritty.exe": "Window Class"}.get(proc, "")
        f = field(proc, title, ctype, nm, rng.choice(["", "", "editor", "monaco-editor-textarea", "term"]),
                  "", "", "", rng.choice(["", "multiline=true", ""]), cls=cls)
        add(f, "code", "code", "en" if rng.random() < 0.5 else "fr", ["desktop" if proc not in BROWSERS else "web", "code"])
    # discussion
    start = len(rows)
    while len(rows) - start < 140:
        proc, title, names = rng.choice(CHAT_E)
        who = rng.choice(WHO)
        t = title.format(who=who)
        if proc in BROWSERS and rng.random() < 0.6:
            t += rng.choice(SUFFIX.get(proc, [""]))
        nm = rng.choice(names).format(who=who)
        tags = ["desktop" if proc not in BROWSERS else "web", "chat"]
        if rng.random() < 0.12:
            nm = noisy(rng, nm)
            tags.append("noisy")
        f = field(proc, t, rng.choice(["edit", "edit", "document"]), nm, rng.choice(["", "", "composer", "msg-input",
                                                                                     "chat-input-field"]),
                  "", "", rng.choice(["", "textbox"]), rng.choice(["", "multiline=true"]))
        add(f, "chat_message", rng.choice(["text", "text", "url"]), "fr", tags)
    # rien a proposer
    start = len(rows)
    while len(rows) - start < 120:
        proc, tpl, ctype, names = rng.choice(OTHER_E)
        t = tpl.format(doc=rng.choice(DOCS_E))
        if proc in BROWSERS and rng.random() < 0.6:
            t += rng.choice(SUFFIX.get(proc, [""]))
        f = field(proc, t, ctype, rng.choice(names), rng.choice(["", "", "mailSubject", "title-input", "cellInput"]))
        add(f, "other", None, "fr", ["desktop" if proc not in BROWSERS else "web", "other"])
    # secrets (jamais de suggestion)
    start = len(rows)
    tries = 0
    while len(rows) - start < 160 and tries < 5000:
        tries += 1
        ctx = rng.choice(SECRET_CTX)
        proc = ctx[0]
        site = rng.choice(SHOPS + SERVICES)
        title = ctx[1].format(s=site) if len(ctx) > 1 else proc
        lab, lang = rng.choice(SECRETS)
        flagged = rng.random() < 0.2  # champ bien marque "mot de passe" par l'appli (cas facile)
        r = rng.random()
        name = "" if r < 0.12 else lab
        aid = rng.choice(SECRET_IDS)
        if not name and not aid:
            name = lab
        ph = rng.choice(["", "", "", "••••••", "XXXX XXXX XXXX XXXX", "123", "_ _ _ _ _ _"])
        f = field(proc, title, "edit", name, aid, ph, "", "", rng.choice(["", "required=true"]), is_password=flagged)
        add(f, "other", None, lang, ["secret", "flagged" if flagged else "unflagged"], secret=True)
    # cas adverses / ambigus (etiquette d'intention documentee)
    adv = [
        # (kind, want, labels, contexte)
        ("search", "address", ["Rechercher une adresse", "Search an address"], "map"),
        ("email", "email", ["Email ou numéro de mobile", "Adresse e-mail ou téléphone"], "login"),
        ("username", "username", ["Nom d'utilisateur ou adresse e-mail", "Username or email address"], "login"),
        ("address", "address", ["Ville de naissance", "Nom de la rue", "Numéro de rue", "Nom de la ville"], "signup"),
        ("other", None, ["Code promo", "Code de réduction", "Coupon code", "Code cadeau"], "checkout"),
        ("other", None, ["Numéro de commande", "Référence de la commande"], "contact"),
        ("other", None, ["Instructions pour le livreur", "Motif de la demande"], "checkout"),
        ("search", "name", ["Rechercher des personnes", "Rechercher un contact", "Search people"], "people"),
        ("url", "url", ["Lien vers votre CV (URL)", "Adresse web de votre entreprise"], "signup"),
        ("number", "number", ["Numéro de SIRET", "Numéro fiscal"], "profile"),
        ("phone", "phone", ["Numéro de téléphone du destinataire", "Téléphone de la personne à prévenir"], "checkout"),
        ("date", "date", ["Date de naissance du conducteur principal", "Date d'expiration du permis"], "booking"),
    ]
    for kind, want, labs, ctx in adv:
        for lab in labs:
            for _ in range(5):
                proc = rng.choice(BROWSERS)
                site = rng.choice(MAPS if ctx == "map" else ["LinkedIn Sales", "Outlook Contacts", "Teams Annuaire"]
                                  if ctx == "people" else SHOPS + SERVICES)
                page = "" if ctx in ("map", "people") else rng.choice(PAGES[ctx if ctx in PAGES else "profile"])
                f = field(proc, web_title(rng, proc, page, site), "edit", lab,
                          rng.choice(OPAQUE_IDS + [""]), "", "", "", rng.choice(["", "required=true"]))
                add(f, kind, want, "fr" if any(c in lab for c in "éèàù") or " de " in lab else "en", ["adversarial"])
    # adverses de bureau
    for proc, title, ctype, name, kind, want in [
        ("notepad.exe", "config.py - Bloc-notes", "document", "Éditeur de texte", "code", "code"),
        ("notepad.exe", "deploy.sh - Bloc-notes", "document", "", "code", "code"),
        ("code.exe", "Rechercher - mon-site - Visual Studio Code", "edit", "Rechercher", "search", "text"),
        ("code.exe", "parser.rs - infra - Visual Studio Code", "edit", "Find", "search", "text"),
        ("discord.exe", "Discord", "edit", "Rechercher", "search", "text"),
        ("thunderbird.exe", "Écrire : Réunion", "edit", "Objet", "other", None),
        ("winword.exe", "lettre.docx - Word", "document", "Corps du document", "other", None),
        ("olk.exe", "Nouveau message", "edit", "À", "email", "email"),
        ("olk.exe", "Nouveau message", "edit", "Cc", "email", "email"),
        ("steam.exe", "Amis", "edit", "Rechercher des amis", "search", "username"),
    ]:
        for k in range(4):
            t = title if k == 0 else f"{title} ({k})"
            add(field(proc, t, ctype, name), kind, want, "fr", ["adversarial", "desktop", "seen_vocab"])
    for i, r in enumerate(rows):
        r["id"] = f"t{i:04d}"
    return rows


def leaks(rows: list[dict], vocab: set[str]) -> list[tuple[str, str]]:
    bad = []
    for r in rows:
        if "seen_vocab" in r["tags"]:
            continue  # applis connues utilisees a contre-emploi (voir README) : vocabulaire vu, volontairement
        f = r["field"]
        for k in ("name", "label", "help_text", "automation_id"):
            v = norm(f.get(k, ""))
            if v and v in vocab and v not in GENERIC_OK:
                bad.append((r["id"], f"{k}={f[k]!r}"))
        for part in str(f.get("window_title", "")).replace(" | ", " - ").replace(" – ", " - ").split(" - "):
            v = norm(part)
            if v and v in vocab and v not in GENERIC_OK:
                bad.append((r["id"], f"title part {part!r}"))
        for c in r["candidates"]:
            if norm(c) in vocab:
                bad.append((r["id"], f"candidate {c!r}"))
    return bad


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    rng = random.Random(SEED)
    rows = build(rng)
    vocab = train_vocab()
    bad = leaks(rows, vocab)
    if bad:
        c = Counter(b[1] for b in bad)
        print(f"{len(bad)} fuites de vocabulaire d'entrainement :")
        for k, n in c.most_common(40):
            print(f"  {n:4d}  {k}")
        if not a.check:
            raise SystemExit("corriger le vocabulaire eval avant d'ecrire le jeu")
    if a.check:
        return
    OUT.mkdir(exist_ok=True)
    with open(OUT / "text.jsonl", "w", encoding="utf-8", newline="\n") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    kinds = Counter(r["kind"] for r in rows)
    tags = Counter(t for r in rows for t in r["tags"])
    langs = Counter(r["lang"] for r in rows)
    print(f"{len(rows)} cas -> {OUT / 'text.jsonl'}")
    print("sortes :", dict(sorted(kinds.items())))
    print("tags   :", dict(sorted(tags.items())))
    print("langues:", dict(sorted(langs.items())))
    print("sans texte a proposer (best=-1) :", sum(r["best"] < 0 for r in rows))


if __name__ == "__main__":
    main()
