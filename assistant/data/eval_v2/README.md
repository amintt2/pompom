# eval_v2 — jeux de test figés (texte + vision)

Construits le 7 octobre 2026 pour comparer, **avec le même protocole**, la pile actuelle (règles + têtes
stuntd sur Laya, SigLIP) et EmbeddingGemma 2. Ces fichiers ne servent **jamais** à entraîner ni à régler quoi
que ce soit (les têtes sont choisies sur l'ancien `data/test.jsonl` et calibrées sur 20 % mis de côté de
l'entraînement, comme stuntd).

Lancer toute la mesure : `.venv\Scripts\python.exe tests\eval_v2.py` (voir l'en-tête du script pour les options :
`--text`, `--vision`, `--latency`, `--ram`, `--real fichier.jsonl`, `--real-vision dossier`).

## `text.jsonl` — 1 850 cas (un cas = un champ différent)

Généré par `python data/gen_eval_v2.py` (graine fixe `20261007`), puis figé.

| famille | cas | contenu |
| --- | --- | --- |
| formulaires web (11 sortes) | ~1 200 | email, téléphone, adresse, URL, nom, identifiant, nombre, date, recherche (sites) |
| recherche sur une carte | 60 | Moovit, Google Earth, Komoot… : le bon texte à coller est une **adresse** |
| code | 118 | éditeurs/terminaux jamais vus à l'entraînement (WebStorm, Zed, WezTerm, Colab, Replit…) |
| discussion | 140 | Element, Mattermost, Viber, Bluesky, Threads, Meet… |
| rien à proposer (`other`) | 120 | traitement de texte, tableur, objet de mail, titre de ticket, « Enregistrer sous »… |
| **secrets** | 160 | mots de passe non marqués (80 %) ou marqués (20 %), codes SMS/2FA, PIN, carte, CVC, clé d'API, jeton, phrase de récupération, autres langues (Passwort, Contraseña, Senha…) : **la seule bonne réponse est « rien »** |
| adverses / ambigus | 185 | « Code promo », « Nom de la rue », « Ville de naissance », « Numéro de SIRET », « Email ou numéro de mobile », recherche de personnes, `.py` ouvert dans le Bloc-notes, recherche dans VS Code/Discord… (dont 40 `seen_vocab` : applis connues utilisées à contre-emploi) |

Réalisme : descriptions comme les renvoie `focus_probe.py` (name, label `<label for>`, help_text = placeholder,
automation_id dont des id générés sans sens `:r4:` / `mat-input-3`, aria_role `searchbox`, aria_properties
`required=true;…`, localized_type FR, framework, class_name), titres de fenêtre avec suffixes réels de navigateur
(dont le `Microsoft​ Edge` avec espace insécable de largeur nulle), 18 % de libellés bruités (lettres inversées
ou oubliées, MAJUSCULES, emoji), FR 1 124 / EN 619 / mélangé 85 / autres langues 22.

**Vocabulaire disjoint de l'entraînement** : chaque libellé, id, aide, morceau de titre et texte copié est
comparé (minuscules, sans accents ni ponctuation finale) au vocabulaire de `data/gen_train.py` et au jeu « dev »
de `gen_synthetic.py` ; le script refuse d'écrire le jeu en cas de fuite. Seuls quelques mots génériques
inévitables sont tolérés (`email`, `message`, `date`, `nom`, `adresse`…, liste `GENERIC_OK`).

Étiquettes « or » fixées par l'intention du scénario (même oracle que `gen_synthetic.make`), jamais par les
règles. Champs : `field`, `kind` (sorte attendue ; `other` pour un secret), `candidates` (du plus récent au plus
ancien), `types` (type **voulu** de chaque texte — le décideur, lui, les retrouve par regex), `best` (index à
proposer ou -1), `secret`, `lang`, `tags`, `want`.

Métriques (`tests/eval_v2.py`) : sorte juste (champs non secrets), **bonne suggestion** (le texte proposé — ou
rien — est le bon, sur tout le jeu), bout en bout (sorte ET texte justes), **secrets jamais proposés**, latence,
part des appels au modèle, têtes seules (précision, couverture au seuil, précision quand sûre, ECE).

## `vision/` — 360 écrans 2560×1440 (+ cartes de mouvement)

Générés par `python data/gen_screens.py --split eval --n 360` (graines 9 000 000 + i), 61 Mo (JPEG q82) :
dossier ignoré par git, **régénérable à l'identique** avec le script (mêmes polices Windows, Pillow 12.3).
L'entraînement des têtes vision utilise `--split train` (graines 1 000 000 + i, `dev/vision_train`, jamais l'eval).

- 7 classes : vidéo 73, code 61, web 55, jeu 54, discussion 45, documents 41, autre 31 ; 93 écrans contiennent
  une vidéo (62 qui bouge, 18 immobile — diapos ou pause —, 13 « personne qui parle ») ; 88 plein écran,
  168 maximisés, 47 côte à côte, 57 fenêtres flottantes ; thèmes clair/sombre ; mise à l'échelle 100/125/150 % ;
  vidéo normale, mode cinéma, plein écran, image dans l'image ; vidéo dans la moitié d'un écran partagé.
- 65 écrans en **style tenu à l'écart** (`held_out_style`) : lecteur centré type Vimeo, JetBrains, lecteur PDF,
  WhatsApp, encyclopédie, Réglages, jeu de course… jamais vus par les têtes entraînées.
- Chaque écran = 5 captures à 1 s d'intervalle (comme `VisionWatcher`) : `<id>.jpg` = la dernière, et
  `motion.npz[id]` = les 5 vignettes 96×54 en niveaux de gris calculées **avant** compression, exactement
  comme `vision.py`. Distracteurs de mouvement : défilement de page (30 % des pages web), publicité animée,
  curseur qui clignote, message qui arrive, jeux fenêtrés.
- `labels.jsonl` : `cls`, `video_rect` [x, y, w, h] ou null, `video_motion` (moving / static / talking),
  `video_kind`, `fullscreen`, `layout`, `foreground` {process, rect, title}, `held_out_style`, `theme`, `scale`.

Limites (honnêtement) : images « naturelles » procédurales (paysages fBm, ville, fonds marins, personnage,
sport, dessin animé, diapos) et jeux procéduraux ; aucune vraie capture d'écran ni vidéo réelle. Les chiffres
mesurent surtout la **robustesse relative** des deux encodeurs ; à confirmer sur de vraies captures
(`--real-vision`, quand le jeu réel de l'outil de retour d'expérience existera).

## `results/`

Un JSON par mesure (`<date>_<partie>_<étiquette>.json`), écrit par `tests/eval_v2.py`.
