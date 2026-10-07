# Journal des versions

Toutes les versions de Pompom. Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/)
et les numéros suivent [SemVer](https://semver.org/lang/fr/).

## [0.6.2-beta] - 2026-10-07

### Ce qu'il tient, en main de cartes
- Survole sa tête : tout ce qu'il porte (captures, textes copiés, fichiers, et la **lettre** avec ses messages) s'étale au-dessus de lui **comme une main de cartes**. La carte survolée se soulève.
- **Clique une carte** pour la récupérer (copier l'image ou le texte, lire la lettre). Glisse-la dehors pour la déposer, clic droit pour la retirer.
- Survole une **image** : un grand aperçu net s'affiche au-dessus (ou sur le côté près du haut de l'écran), avec sa taille et son âge.

## [0.6.1-beta] - 2026-10-07

### Il apprend de ses erreurs
- **« Il s'est trompé… »** (clic droit), ou une pastille **« Il s'est trompé ? »** quand tu le cliques pendant qu'il fait quelque chose tout seul ou juste après un moment de jeu.
- Une carte te demande ce que tu faisais vraiment (Vidéo, Musique, Jeu, Code, Claude / IA, Mails, Documents, Tableur, Discussion, Réseaux, Lecture, Design, Web, Visio, Autre…) et le moment de jeu qu'il a raté (« J'ai marqué », « Je suis mort »…).
- Les corrections sont gardées **sur ton PC** (`%APPDATA%\Pompom\dataset`), avec l'« empreinte » numérique de l'écran calculée par l'assistant local (l'image n'est jamais écrite).
- **Partage anonyme** (bientôt : le réglage apparaîtra quand le serveur sera en ligne ; réglage « Aider à améliorer Pompom (anonyme) », désactivé par défaut) : uniquement des nombres + la correction, jamais d'image, de titre ni de texte ; « Voir ce qui part » montre le JSON exact.
- **Mode développeur** : captures locales toutes les 3 min (WebP, plafond 2 Go), jamais sur les fenêtres privées, en visio ou en stream.
- Nouveau réglage « Effacer mes données d'entraînement ». Tout est expliqué dans [docs/donnees.md](docs/donnees.md).

### Pour les développeurs
- Service local : `POST /embed` (embedding normalisé de l'écran ou d'un champ, avec l'identifiant du modèle).
- `assistant/tools/` : étiquetage des captures par un grand modèle de vision (`label_screens.py`, sortie JSON stricte, reprise, estimation du coût, `--dry-run`), jeu de données réel découpé par jour (`build_real_dataset.py`), ré-entraînement et comparaison aux têtes actuelles (`train_real_heads.py`).
- `server/feedback/` : serveur FastAPI + SQLite pour Coolify (schéma strict, aucune IP ni journal).

## [0.6.0-beta] - 2026-10-07

### Un seul compagnon dans la boutique
- Quand tu ouvres la boutique, **il saute dedans** et s'assoit dans la carte d'aperçu (fini le double). C'est lui qu'on habille : les essayages, les couleurs, les réactions, tout se passe sur le vrai compagnon.
- Glisse sur lui pour le faire tourner sur lui-même. À la fermeture, il redescend avec sa vraie tenue (les essayages non achetés sont retirés).

## [0.5.4-beta] - 2026-10-06

### Corrigé
- **Accessoires portés en noir dans la boutique** : les miniatures préparées pendant que la boutique était cachée (préchargement au démarrage) sortaient noires. Elles sont maintenant dessinées à l'ouverture, et une miniature ratée est refaite.

## [0.5.3-beta] - 2026-10-06

### Il suit la vidéo
- Nouveau **détecteur de vidéo intégré** (sans IA, rien à installer) : l'écran est découpé en une grille de cases ; les zones qui bougent sans arrêt sont la vidéo. Il se tourne vers elle, et va s'asseoir dessous si elle est loin.
- Léger : une analyse par seconde de la seule fenêtre au premier plan (~20 ms sur un fil séparé), uniquement quand il regarde une vidéo.
- Il ne s'endort plus devant une vidéo (on ne touche ni souris ni clavier, ce n'est pas une absence).

### En jeu
- En plein écran, il s'accroche au **bord droit de l'écran**, aux deux tiers de la hauteur, à moitié caché, et regarde ta partie. Il glisse derrière le bord quand ta souris approche.

### Corrigé
- Le menu (clic droit) se ferme dès que tu cliques ailleurs, même avec le clic droit ou dans une autre appli.
- Mises à jour : si GitHub ne répond pas un instant, il réessaie, puis affiche un message clair (au lieu de « empreinte de sécurité introuvable »).

## [0.5.2-beta] - 2026-10-06

### Plus juste
- **Barre des tâches masquée automatiquement** : il s'assoit tout en bas de l'écran, puis remonte avec la barre quand elle apparaît (et redescend quand elle se cache).
- **Jeux en plein écran** : au lieu du périscope, il s'installe **sur le côté**, en petit, tourné vers ta partie avec son pop-corn. Il plonge si ta souris approche, et tu peux le poser ailleurs : il retient la place pour ce jeu.
- **Vidéos** : il se tourne **du côté de la vidéo** (avant, toujours vers la droite).
- **Besoins** : les jauges n'apparaissent plus au survol que si l'un de ses besoins est bas (elles cachaient ce qu'il tient sur la tête).

## [0.5.1-beta] - 2026-10-06

### Corrigé
- **Il restait invisible dans Rocket League** : le jeu était classé « compétitif », donc il se cachait complètement. Il reste maintenant visible (en périscope au bord de l'écran, ou à la place où tu le poses) pour fêter tes buts.

## [0.5.0-beta] - 2026-10-06

### Il regarde ton écran (option, bêta)
- Nouvelle option « Il regarde ton écran » : une IA de vision **locale** (SigLIP, Apache-2.0) devine si tu joues, regardes une vidéo, codes, écris ou discutes, et **repère où est la vidéo**.
  - Une vidéo à l'écran : il marche jusque **sous la vidéo** et la regarde avec toi (pop-corn).
  - Un jeu inconnu du catalogue : il sort sa manette si tu en as une.
- Très léger : une analyse toutes les 3 s (≈ 43 ms sur la carte graphique, 0,4 % de processeur). Pause complète pendant les jeux en plein écran et les jeux compétitifs.
- Les images restent en mémoire sur ton PC : jamais enregistrées, jamais envoyées.

### Assistant plus léger, sans PyTorch
- Les suggestions utilisent maintenant **stuntd + Laya** (modèle de décision, pas de génération de texte) au lieu de llama.cpp.
- Modèles convertis en ONNX : l'installation de l'assistant passe d'environ 4 Go à environ 860 Mo, et la mémoire du modèle de texte se libère après 5 minutes sans servir.
- L'assistant reste optionnel et séparé du jeu (Pompom.exe ne grossit pas).

## [0.4.1-beta] - 2026-10-06

### Mini-jeux : le vrai compagnon dans la partie
- Quand tu ouvres « Jouer avec moi », il **saute dans la fenêtre du jeu** et s'assoit dans sa carte (le vrai compagnon 3D, à la place du dessin). Il suit la fenêtre si tu la déplaces.
- Si tu passes à une autre fenêtre, il redescend sur la barre des tâches, puis revient dès que tu retournes au jeu.

### Corrigé
- Un léger rectangle gris pouvait apparaître sous lui sur les fonds clairs (ombre de contact mal estompée sur les bords).

## [0.4.0-beta] - 2026-10-06

### Il fait comme toi (48 situations)
- Il imite ce que tu fais, selon l'appli ou le site au premier plan :
  - **mails** : il lit une lettre en suivant ton curseur ;
  - **code** : ordinateur et lunettes ; **Claude Code** : ordinateur, café et bulle de réflexion ;
  - **Excel** : calculatrice ; **design** : béret et palette ; **3D** : petit cube ;
  - **musique** : casque et il bouge en rythme ; **Discord** : il tape sur son téléphone ;
  - **lecture** : livre ; **shopping**, **météo**, **échecs**, **films** (pop-corn)…
- 34 nouveaux objets modélisés (lettre, livre, clavier, calculatrice, palette, cube 3D, sablier, échiquier…).
- Discret sur les pages privées (gestionnaires de mots de passe, connexion) : il détourne le regard.

### Joue avec moi !
- Nouveau menu **« Jouer avec moi »** (clic droit) : **Puissance 4**, **Snake duel** et **Morpion** contre lui, en 3 niveaux.
- Il réfléchit, te taquine et réagit aussi sur le bureau. Des pièces et de l'XP à gagner, et une nouvelle quête.

## [0.3.0-beta] - 2026-10-06

### Il vit tes parties avec toi
- **Il fête tes buts et tes éliminations** (multi-kill, ace, victoire) et boude un peu quand tu meurs ou que l'adversaire marque. Récap de session avec tes buts et éliminations.
- **Rocket League** : Stats API officielle (activation proposée avec ton accord, une fois sorti du jeu) ; ne fête que les buts de ton équipe. Option : lecture du tableau des scores.
- **CS2 et Dota 2** : Game State Integration officielle de Valve. **LoL / TFT** : API locale officielle de Riot.
- **Valorant, Fortnite** (option) : lecture des éliminations et des morts à l'écran, sans jamais toucher au jeu.
- **Jeux de stratégie** : il met ses lunettes et réfléchit avec toi. Catalogue de 250 jeux par genre.
- Nouvelle section « Jeux » dans les réglages.

## [0.2.3-beta] - 2026-10-06

### Mises à jour plus rapides
- Il vérifie **toutes les 10 minutes** si la version suivante est déjà téléchargeable (lien direct), au lieu d'attendre la liste de GitHub toutes les 6 h : une nouvelle version est proposée quelques minutes après sa sortie.
- Nouveau : **« Chercher une mise à jour »** dans le menu (clic droit) et un bouton « Vérifier » dans Réglages → Système. Il te répond tout de suite.
- Toujours rien d'installé sans ton accord, et chaque fichier est vérifié (empreinte SHA-256).

## [0.2.2-beta] - 2026-10-06

### Corrigé
- **Grand rectangle noir autour de lui** (v0.2.1) : l'anticrénelage 2D appliqué à la fenêtre principale cassait sa transparence. Il est retiré de cette fenêtre (la boutique et le menu le gardent).

### Fluide à 120 images/s
- Il tourne désormais à **120 images/s** (avant : 30). Nouveau réglage « Images par seconde » : 60, 120, 144 ou Max.
- La capture de l'écran pour les reflets se fait sur un fil d'exécution séparé, sans relecture de la carte graphique : plus de saccades (pire image : 40 ms → 9 ms, temps moyen 3,3 → 2,2 ms).
- Il s'adapte tout seul : plein régime quand tu le regardes ou le touches, 60 images/s quand personne ne bouge, 30 quand il dort.
- **Économie en jeu** (activé par défaut) : pendant tes parties, 30 images/s, pas de suréchantillonnage et reflets rafraîchis une fois par seconde, pour ne pas te coûter de FPS. Caché dans un jeu compétitif, il ne consomme presque plus rien.

### Plus réactif
- La boutique est préparée en coulisse au démarrage : elle s'ouvre en moins de 0,1 s (avant : jusqu'à 1,4 s).
- Animations du menu et de la boutique plus vives.
- Il s'enfonce sous ton doigt dès que tu appuies (retour immédiat au clic).

### Plus doux
- Fourrure environ 30 % plus longue et plus duveteuse.

## [0.2.1-beta] - 2026-10-06

### Interface plus nette
- Boutique, menu et bulles nets sur les écrans en haute résolution (1440p, 4K, mise à l'échelle 125 à 150 %) :
  - icônes et formes lissées (anticrénelage) ;
  - miniatures 3D rendues en double résolution ;
  - aperçu 3D suréchantillonné.
- Nouveau réglage « Mises à jour automatiques ».

## [0.2.0-beta] - 2026-10-06

### Il ne gêne plus jamais (en jeu, en visio)
- **Boîte aux lettres** : en jeu, en visio ou quand OBS tourne, il ne parle plus. Ses messages s'accumulent dans une enveloppe sur sa tête, livrée quand tu reviens. Clique-le pour la lire.
- **Récap de partie** : après plus de 20 min de jeu, il t'attend avec un petit ticket (« Session de Hades : 1 h 12 · +80 pièces. GG ! »).
- **Placement en jeu plein écran** :
  1. Sur ton deuxième écran s'il y en a un.
  2. Sinon, à la place où tu l'as posé une fois pour ce jeu : il la retient.
  3. Sinon, en **périscope** : tout petit en bas de l'écran, seuls ses oreilles et ses yeux dépassent.
  - Il plonge hors de vue dès que ta souris approche.
- **Jeux compétitifs** (Valorant, CS2, LoL, Overwatch…) : il se cache complètement, puis revient avec un « GG ? ».
- **Visio** (Teams, Zoom, Meet, appel Discord) : il se fait tout petit dans le coin, sans bulle ni animation.

### Il joue avec toi
- **Manette miroir** : si une manette est branchée, sa petite manette imite la tienne. Il se penche avec ton stick, sursaute à chaque bouton et transpire si tu enchaînes.
- **Pop-corn** : devant une vidéo (YouTube, Netflix, Twitch…), il se tourne vers l'écran, dos à toi, et grignote.

### Physique des fenêtres
- **Fenêtre fermée** : il reste suspendu en l'air une demi-seconde, comme dans un dessin animé, puis tombe.
- **Fenêtre secouée** : il a le vertige puis est éjecté. La slime, elle, reste collée.
- **Fenêtre maximisée** : « Ascenseur ! ». Il est propulsé vers le haut, se cogne au plafond et retombe.
- **Fenêtre rétrécie sous lui** : le bord le pousse.

## [0.1.1-beta] - 2026-10-06

### Nouveau
- **Visible en partage d'écran** : il apparaît maintenant dans tes partages d'écran (Discord, Teams, OBS…) et tes captures, tout en gardant ses reflets.
  - Pour ne pas se refléter lui-même, il s'efface de sa propre capture et reconstruit le fond derrière lui (inpainting).
  - Réglage « Visible en partage d'écran » : désactive-le pour des reflets parfaitement exacts, mais il sera alors invisible en partage.
- **Il tient tes captures d'écran** : quand tu fais une capture (Outil Capture d'écran, Win+Maj+S), il la garde sur sa tête. Clique-le pour la recopier, glisse-la dehors pour la déposer.
  - Activé par défaut, réglage « Tenir mes captures d'écran ». Seules les images de l'Outil Capture d'écran sont prises.

## [0.1.0-beta] - 2026-10-06

Première bêta publique.

### Le compagnon
- 5 compagnons en 3D : Mochi, Pico, Kiwi, Coco et Nuage, chacun avec ses goûts.
- Fourrure à brins géométriques éclairée par des matcaps rendus dans Cycles.
- 10 matières, chacune avec sa propre physique de rebond :
  - Peluche, Velours, Gelée, Slime, Pâte à pain, Plastique, Bois, Chrome, Verre, Néon.
  - Gelée, slime et verre utilisent l'environment matting tiré de Cycles.
- Reflets et réfractions de ton vrai écran, en temps réel.
- 55 accessoires détaillés, 13 styles d'yeux et 12 bouches.

### Sur le bureau
- Il s'assoit sur la barre des tâches et sur le haut des fenêtres, suit les fenêtres qu'on déplace et saute sur celles qui s'ouvrent.
- On peut le prendre et le lancer, le caresser en frottant la souris dessus.
- Il tape sur un mini-ordi quand tu travailles, joue à la manette quand tu joues, sort son téléphone et dort quand tu t'absentes.
- En plein écran, il te regarde discrètement depuis le bord.

### Jeu
- Besoins : faim, amusement, énergie et bonheur.
- Niveaux, XP et compagnons débloqués par niveau.
- 3 quêtes du jour.
- Nourris-le en déposant des fichiers sur lui : ils partent dans la Corbeille, toujours restaurables.
- Pièces gagnées quand tu travailles ou que tu joues, et boutique d'accessoires.

### Assistant
- Gardien du presse-papiers (optionnel) : ce que tu copies apparaît sur sa tête.
- Suggestions intelligentes (bêta, optionnelles) : modèle de décision local stuntd + Laya, rien ne quitte ton PC.

### Technique
- Boutique et menus entièrement redessinés, testés automatiquement.
- Mise à jour automatique depuis les Releases GitHub, avec vérification SHA-256.
