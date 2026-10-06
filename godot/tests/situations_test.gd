extends Node
## Test du classifieur de situations (headless) :
##   Godot --path godot --headless res://tests/situations_test.tscn
## Code de sortie 0 = tout passe.

const E := "\u200b"
# [processus, titre, categorie, extra, situation attendue]
var CASES := [
	["chrome", "Boîte de réception (3) - moi@gmail.com - Gmail - Google Chrome", "work", {}, "email_read"],
	["msedge", "Courrier - Amin - Outlook et 2 pages supplémentaires - Personnel - Microsoft" + E + " Edge", "work", {}, "email_read"],
	["outlook", "Boîte de réception - amin@exemple.fr - Outlook", "work", {}, "email_read"],
	["OUTLOOK.EXE", "Sans titre - Message (HTML)", "work", {}, "email_write"],
	["olk", "RE: Réunion de lundi", "work", {}, "email_write"],
	["thunderbird", "Rédiger : (pas de sujet) - Thunderbird", "other", {}, "email_write"],
	["chrome", "Nouveau message - Gmail - Google Chrome", "work", {}, "email_write"],
	["code", "main.gd - Pompom - Visual Studio Code", "work", {}, "coding"],
	["cursor", "app.tsx - web - Cursor", "work", {}, "coding"],
	["idea64", "Project – Main.java", "work", {}, "coding"],
	["windowsterminal", "\u2733 Claude Code", "work", {}, "ai_agent"],
	["windowsterminal", "claude", "work", {}, "ai_agent"],
	["claude", "Claude", "work", {}, "ai_agent"],
	["pwsh", "codex - ~/projet", "work", {}, "ai_agent"],
	["powershell", "Windows PowerShell", "work", {}, "terminal"],
	["windowsterminal", "nvim init.lua", "work", {}, "coding"],
	["chrome", "ChatGPT - Google Chrome", "work", {}, "ai_chat"],
	["firefox", "Planifier un voyage - Claude — Mozilla Firefox", "work", {}, "ai_chat"],
	["chrome", "Claude - Google Chrome", "work", {}, "ai_chat"],
	["winword", "Rapport.docx - Word", "work", {}, "writing_doc"],
	["chrome", "Mémoire - Google Docs - Google Chrome", "work", {}, "writing_doc"],
	["notion", "Notes de cours", "work", {}, "writing_doc"],
	["notepad", "notes.txt - Bloc-notes", "work", {}, "writing_doc"],
	["excel", "Ventes 2026.xlsx - Excel", "work", {}, "spreadsheet"],
	["excel", "Budget maison.xlsx - Excel", "work", {}, "finance"],
	["chrome", "Suivi - Google Sheets - Google Chrome", "work", {}, "spreadsheet"],
	["powerpnt", "Pitch.pptx - PowerPoint", "work", {}, "slides"],
	["chrome", "Deck - Google Slides - Google Chrome", "work", {}, "slides"],
	["figma", "Pompom UI – Figma", "work", {}, "design"],
	["photoshop", "dessin.psd @ 100%", "work", {}, "design"],
	["chrome", "Affiche - Canva - Google Chrome", "work", {}, "design"],
	["blender", "Blender [C:\\props.blend]", "work", {}, "modeling_3d"],
	["godot_v4.7.2-stable_win64", "Pompom - Godot Engine", "work", {}, "modeling_3d"],
	["unity", "MyGame - SampleScene - Windows - Unity 6", "work", {}, "modeling_3d"],
	["resolve", "DaVinci Resolve - Projet", "work", {}, "video_edit"],
	["capcut", "CapCut", "other", {}, "video_edit"],
	["spotify", "Daft Punk - One More Time", "media", {}, "music_listen"],
	["spotify", "Spotify Premium", "media", {}, "music_listen"],
	["chrome", "YouTube Music - Google Chrome", "media", {}, "music_listen"],
	["chrome", "Lofi Girl - lofi hip hop radio - YouTube - Google Chrome", "media", {}, "music_listen"],
	["fl64", "FL Studio 21", "work", {}, "music_make"],
	["ableton live 12 suite", "Untitled - Ableton Live 12 Suite", "work", {}, "music_make"],
	["audible", "Audible", "other", {}, "podcast"],
	["chrome", "Episode 12 - Le Podcast - Spotify - Google Chrome", "media", {}, "podcast"],
	["discord", "#général | Mon serveur - Discord", "other", {}, "chat"],
	["whatsapp.root", "WhatsApp", "other", {}, "chat"],
	["chrome", "(2) Messenger - Google Chrome", "browse", {}, "chat"],
	["ms-teams", "Conversation | Microsoft Teams", "work", {}, "chat"],
	["chrome", "(5) Accueil / X - Google Chrome", "browse", {}, "social_scroll"],
	["chrome", "r/godot - Reddit - Google Chrome", "browse", {}, "social_scroll"],
	["firefox", "Instagram — Mozilla Firefox", "browse", {}, "social_scroll"],
	["chrome", "TikTok - Make Your Day - Google Chrome", "browse", {}, "social_scroll"],
	["chrome", "Facebook - Google Chrome", "browse", {}, "social_scroll"],
	["chrome", "Amazon.fr : casque audio - Google Chrome", "browse", {}, "shopping"],
	["chrome", "Vinted - Google Chrome", "browse", {}, "shopping"],
	["chrome", "Panier - Amazon.fr - Google Chrome", "browse", {}, "shopping"],
	["acrord32", "contrat.pdf - Adobe Acrobat Reader", "work", {}, "reading"],
	["chrome", "Chat — Wikipédia - Google Chrome", "browse", {}, "reading"],
	["chrome", "Duolingo - Google Chrome", "browse", {}, "studying"],
	["anki", "Paquet: Japonais - Anki", "other", {}, "studying"],
	["chrome", "Google Maps - Google Chrome", "browse", {}, "maps"],
	["chrome", "Booking.com : hôtels à Lyon - Google Chrome", "browse", {}, "maps"],
	["chrome", "Mes comptes - Boursorama Banque - Google Chrome", "browse", {}, "finance"],
	["chrome", "Google Agenda - Semaine du 5 octobre - Google Chrome", "work", {}, "calendar"],
	["chrome", "Tableau Pompom | Trello - Google Chrome", "work", {}, "todo"],
	["chrome", "[PROJ-12] Bug - Jira - Google Chrome", "work", {}, "todo"],
	["explorer", "Téléchargements", "other", {}, "files"],
	["explorer", "", "other", {}, ""],
	["msiexec", "Installation de Python", "other", {}, "installing"],
	["python-3.13.0-amd64", "Python 3.13.0 (64-bit) Setup", "other", {}, "installing"],
	["steamwebhelper", "Steam", "other", {}, "game_launcher"],
	["chrome", "Steam Community :: Guide - Google Chrome", "browse", {}, "game_launcher"],
	["obs64", "OBS 31.0 - Profil: Stream", "work", {}, "streaming"],
	["vlc", "film.mkv - Lecteur multimédia VLC", "media", {}, "video_watch"],
	["chrome", "Chat qui danse - YouTube - Google Chrome", "media", {}, "video_watch"],
	["chrome", "Netflix - Google Chrome", "media", {}, "movie"],
	["chrome", "zerator - Twitch - Google Chrome", "media", {}, "stream_watch"],
	["taskmgr", "Gestionnaire des tâches", "other", {}, "settings"],
	["systemsettings", "Paramètres", "other", {}, "settings"],
	["msedge", "Paramètres - Personnel - Microsoft" + E + " Edge", "browse", {}, "settings"],
	["chrome", "Jouer aux échecs en ligne - Chess.com - Google Chrome", "browse", {}, "chess"],
	["chrome", "Wordle - The New York Times - Google Chrome", "browse", {}, "chess"],
	["photos", "Photos - IMG_0042.jpg", "other", {}, "photos"],
	["chrome", "Météo Paris - Météo-France - Google Chrome", "browse", {}, "weather"],
	["chrome", "Pâtes carbonara - Recette Marmiton - Google Chrome", "browse", {}, "food"],
	["chrome", "PSG - OM : score en direct - L'Équipe - Google Chrome", "browse", {}, "sports"],
	["chrome", "Offres d'emploi - Indeed - Google Chrome", "browse", {}, "job_hunt"],
	["chrome", "Déclarer mes revenus - impots.gouv.fr - Google Chrome", "browse", {}, "paperwork"],
	["chrome", "Tinder - Google Chrome", "browse", {}, "dating"],
	["chrome", "comment faire des crêpes - Recherche Google - Google Chrome", "browse", {}, "searching"],
	["chrome", "gmail login - Google Search - Google Chrome", "browse", {}, "searching"],
	["chrome", "Nouvel onglet - Google Chrome", "browse", {}, "searching"],
	["chrome", "Le Monde.fr - Actualités et Infos en France - Google Chrome", "browse", {}, "news"],
	["chrome", "Se connecter - Comptes Google - Google Chrome", "browse", {}, "private"],
	["keepassxc", "Passwords.kdbx - KeePassXC", "other", {}, "private"],
	["chrome", "Index of /files - Google Chrome", "browse", {}, "files"],
	["chrome", "Python Releases for Windows | Python.org - Google Chrome", "browse", {}, "installing"],
	["chrome", "godotengine/godot: Godot Engine - GitHub - Google Chrome", "work", {}, "coding"],
	["chrome", "localhost:5173 - Google Chrome", "work", {}, "coding"],
	["chrome", "Un site au hasard - Google Chrome", "browse", {}, "browsing"],
	["code", "a.gd - Visual Studio Code", "work", {"idle": 400.0}, "afk"],
	["ms-teams", "Réunion | Microsoft Teams", "work", {"meeting": true}, "meeting"],
	["eldenring", "ELDEN RING", "game", {}, "gaming"],
	["chrome", "Un site au hasard - Google Chrome", "browse", {"hour": 1}, "late_night"],
	["code", "a.gd - Visual Studio Code", "work", {"hour": 2}, "coding"],
	["chrome", "Un site au hasard - Google Chrome", "browse", {"hour": 15}, "browsing"],
]


func _ready() -> void:
	GameState.no_save = true
	var ok := 0
	var ko := 0
	for c in CASES:
		var got := Situations.detect(c[0], c[1], c[2], c[3])
		if got == c[4]:
			ok += 1
		else:
			ko += 1
			print("SITUATION FAIL  %s | %s  ->  %s (attendu %s)" % [c[0], c[1], got, c[4]])
	# toutes les situations detectables ont une fiche (label / lignes) et un comportement
	var ids := {}
	for r in Situations.data()["rules"]:
		ids[str(r["id"])] = true
	for extra_id in ["browsing", "afk", "late_night", "gaming", "meeting"]:
		ids[extra_id] = true
	var missing := 0
	for id in ids:
		if not Situations.all().has(id):
			missing += 1
			print("SITUATION FAIL fiche manquante : ", id)
		if not PetSituations.BEHAVIOURS.has(id):
			missing += 1
			print("SITUATION FAIL comportement manquant : ", id)
	print("SITUATIONS %d cas : %d ok, %d echecs ; %d situations, %d manques" % [CASES.size(), ok, ko,
		Situations.all().size(), missing])
	get_tree().quit(0 if ko + missing == 0 else 1)
