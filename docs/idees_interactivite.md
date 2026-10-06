# Pompom : idées pour qu'il ait l'air vivant (sans être pénible)

> Doc de design, octobre 2026. Efforts : **S** ≈ 1 à 2 jours, **M** ≈ 1 semaine, **L** = plusieurs semaines ou nouvelle techno.
> 🆕 = demande une capacité technique qui n'existe pas encore (détail en annexe).

---

## 1. Principes

1. **Le jeu (ou le travail) passe d'abord.** Pompom ne se met jamais sur une zone utile (HUD, minimap, sous-titres, zone du curseur) et ne vole **jamais** le focus. La fenêtre doit être `WS_EX_NOACTIVATE` : cliquer sur lui ne doit jamais sortir le joueur de son jeu. 🆕 à vérifier
2. **Réagir plutôt qu'improviser.** L'impression de vie vient du « il m'a vu ». Tout comportement notable s'appuie sur un vrai signal (ce que tu fais, l'heure, le son). L'idle aléatoire sert seulement à faire la transition entre deux réactions.
3. **Budget d'attention chiffré.**
   - En jeu actif : **0 bulle**. Seulement des emotes muettes de 1,5 s maximum, pas plus grandes que lui.
   - Pendant une pause détectée en jeu : 1 bulle au maximum.
   - Sur le bureau : 1 bulle spontanée au maximum toutes les 15 min.
   - Si 3 bulles d'affilée sont ignorées, la fréquence est divisée par 2 (adaptatif).
4. **Les messages sont différés, pas supprimés.** Ce qu'il a « envie de dire » pendant une partie part dans une **boîte aux lettres**, livrée au alt-tab ou à la fin de la session.
5. **Un faux positif coûte plus cher qu'un raté.** Sous un seuil de confiance (≈ 0,7), il ne fait rien. Il vaut mieux rater une victoire que fêter une défaite.
6. **Une même situation, cinq personnalités.** Chaque déclencheur a une variante par espèce (voir le tableau au §2.4). C'est ce qui donne envie de les collectionner.
7. **Il apprend des gestes de refus.** S'il est déplacé hors d'un endroit, il évite cet endroit. S'il est lancé deux fois de suite, il boude puis se fait discret 30 min. S'il est déposé quelque part en jeu, il retient cette place pour ce jeu.
8. **Pas de culpabilisation façon Tamagotchi.** Il ne meurt jamais, il ne réclame jamais. Au pire il est « grognon ». Les séries (streaks) peuvent être gelées. Pas de récompense pour jouer *plus* : plutôt des bonus pour les pauses.
9. **Coût quasi nul.** En jeu : moins de 1 % de CPU, capture d'écran en 64×36 une fois par seconde au maximum, aucune capture pour les jeux de la liste « compétitif ».

---

## 2. En jeu (priorité)

### 2.1 Où se mettre : le placement

| # | Idée | Déclencheur / détection | Comportement | Anti-agacement | Effort |
|---|---|---|---|---|---|
| P1 | **Deuxième écran d'abord** | `EnumDisplayMonitors` 🆕 (trivial) : jeu en plein écran sur l'écran A et un écran B existe | Il prend son skate pour rejoindre B et y joue « en parallèle » avec sa manette, en taille normale | C'est la solution idéale : il reste visible sans gêner. Retour quand le jeu se ferme | **S** |
| P2 | **Sa place par jeu** | L'utilisateur le dépose une fois pendant une partie. On enregistre `exe → (écran, coin, offset, échelle)` | Au lancement suivant de ce jeu, il y va directement (petit « c'est ma place ! » muet) | Zéro réglage. On lui apprend une seule fois, il ne l'oublie plus | **S** |
| P3 | **Mode périscope** | Plein écran sans 2e écran et sans place mémorisée | Échelle ×0,5. Il est collé au bord bas de l'écran, à moitié hors champ : on ne voit que les oreilles et les yeux. Il remonte un peu pendant les pauses | Sa silhouette tient en moins de 60 px. Ses mouvements restent lents (pas de saut, pas de spin) | **S** (le peek existe déjà) |
| P4 | **Carte de calme** (coin sans HUD automatique) | Capture basse résolution de l'écran entier (64×36, niveaux de gris, 1/s). Par cellule, sur 60 s, on accumule la **variance temporelle** (le monde 3D bouge) et la **densité de bords** (un HUD est statique et contrasté). Un « calme » a une variance basse et peu de bords : ciel, bandes noires, bords sombres. On y ajoute une **heatmap de la souris** (les clics de MOBA/RTS couvrent la minimap) | Après 1 min de jeu, il glisse vers la cellule calme la plus proche d'un coin. Le résultat est mémorisé par jeu (comme pour P2) | Il ne se déplace jamais plus d'une fois toutes les 5 min. Si la zone devient agitée, il se « tasse » (échelle ×0,7) au lieu de bouger | **M** |
| P5 | **Esquive rapide** | La souris approche à moins de 120 px pendant un jeu (le discreet mode existe déjà, mais il faut des seuils plus agressifs en jeu) | Il plonge sous le bord de l'écran en 150 ms et remonte 3 s plus tard | Indispensable en MOBA et en RTS | **S** |
| P6 | **Liste compétitif** | Les exe de Valorant, CS2, LoL, Overwatch, etc. (et un bouton « Pas pendant ce jeu ») | Il se cache totalement. Il réapparaît après la partie avec un panneau « GG ? » | Respecte les joueurs tryhard. Plus de capture d'écran | **S** |

> Note technique : en **plein écran exclusif**, une fenêtre always-on-top n'est pas affichée. `SHQueryUserNotificationState` renvoie `QUNS_RUNNING_D3D_FULL_SCREEN` 🆕 : dans ce cas on bascule directement sur P1 (2e écran) ou sur la boîte aux lettres. La plupart des jeux récents sont en fenêtré sans bordure, donc ça fonctionne.

### 2.2 Être *avec* le joueur

| # | Idée | Déclencheur / détection | Comportement | Anti-agacement | Effort |
|---|---|---|---|---|---|
| J1 | **Manette miroir (façon Bongo Cat)** | État de la manette via l'API joypad de Godot ou `XInputGetState` dans le helper si Godot ignore la manette quand la fenêtre n'a pas le focus 🆕 à vérifier. Pour le clavier et la souris : **nombre** de touches par seconde (Raw Input `RIDEV_INPUTSINK`, aucun contenu enregistré) 🆕 et vitesse de la souris | Sa petite manette s'allume sur la touche A, il se penche avec le stick. Il tapote plus vite quand tu spammes. Les jours de grosse intensité, il transpire | Mouvements sur place uniquement, rien ne bouge en dehors de son corps. C'est le « il joue avec moi » le plus lisible qui soit | **S** (manette) / **M** (clavier) |
| J2 | **Pauses détectées** (chargement, cinématique, menu) | Aucune entrée depuis 8 s **et** soit une image quasi noire ou statique (faible variance), soit le son du jeu continue sans entrée (cinématique) | Chargement : il s'étire, boit sa tasse. Cinématique : il se tourne vers l'écran, **dos à toi**, avec du pop-corn. Menu ou pause : c'est le **seul** moment où une bulle est permise | Dès qu'une touche est pressée, il revient en mode jeu immédiatement | **M** |
| J3 | **Jauge d'intensité** | Pic sonore **de la session audio du jeu** (`IAudioMeterInformation` par processus 🆕, sans enregistrement, juste un niveau) + nombre de touches + vitesse de la souris | Haute : il serre sa manette, sourcils froncés, emote de sueur. Retombée brutale juste après un pic : petit « ! » puis soupir de soulagement | Emotes uniquement. Il ne cherche pas à interpréter (pas de « tu es mort ! ») | **M** |
| J4 | **Accessoires selon le genre** | Table `exe / appid Steam → genre` livrée avec le jeu (les ~300 jeux les plus joués) + lecture de `steamapps/appmanifest_*.acf` (nom du jeu) + mots-clés du titre de fenêtre. Genre inconnu : manette | Souls/RPG : épée en bois et bouclier-couvercle. Course : volant. FPS : pistolet à eau. Stratégie : carte et longue-vue. Bac à sable : pioche. Rythme : mini-guitare. Cartes (Balatro, Hearthstone) : éventail de cartes. Foot : écharpe et ballon. Cozy (Stardew) : canne à pêche | Choisi au lancement du jeu, il ne change plus ensuite. L'accessoire est un **objet de collection** : on le débloque la première fois qu'on joue au genre | **M** (le gros du travail, ce sont les assets) |
| J5 | **Casque quand on est en vocal** | Le processus Discord a une session audio active avec du son (des gens parlent) | Il met un mini-casque et hoche la tête quand ça parle | Zéro bulle tant qu'on est en vocal | **S** |
| J6 | **Vraies réactions mort / kill / victoire** (intégrations officielles) | **LoL Live Client Data API** (`localhost:2999`, officielle : kills, morts, fin de partie), **CS2 / Dota 2 Game State Integration** (fichier cfg officiel qui envoie du JSON en HTTP au helper), API Stats de Rocket League. Pas d'injection, rien qui touche à l'anti-cheat | Kill : petit poing levé. Mort : il se cache les yeux. Pentakill / ace : confettis (1,5 s). Victoire : panneau « GG » en fin de partie. Défaite : il te tend sa tasse | Les emotes sont limitées à 1 toutes les 20 s. Les grosses célébrations n'ont lieu **qu'en fin de manche ou de partie** | **M** par jeu |
| J7 | **Succès Steam et captures** | Un nouveau fichier dans le dossier screenshots de Steam (surveillance de fichiers). Succès : modification de `appcache/stats/UserGameStats_*.bin` 🆕 à vérifier | Capture : il prend la pose avec un « cheese ! » (et une photo de lui seul va dans son carnet). Succès : un petit trophée apparaît dans ses mains | Rare par nature, donc jamais agaçant | **S** / **M** |
| J8 | **Récap de session** | Le jeu se ferme après plus de 20 min | Il arrive avec un ticket : « 2 h 14 sur Hades · +402 🪙 · 3 moments intenses · record de la semaine ». Avec les intégrations : K/D. Le ticket va dans le carnet | Une seule bulle qui se ferme toute seule et qu'on peut cliquer pour la garder | **S** |
| J9 | **Longues sessions, bien-être** (opt-in) | Plus de 90 min de jeu continu, livré **uniquement** pendant une pause détectée (J2) | Il s'étire en te regardant (sans texte). Si tu fais 5 min de pause : bonus « pause » de 15 🪙 | Jamais plus d'une fois par heure. Désactivable | **S** |
| J10 | **Fatigue tardive** | Jeu après 1 h du matin | Il porte un bonnet de nuit et bâille entre les manches. Il ne dit rien. Le message « au lit ? » attend dans la boîte aux lettres | Pas de morale pendant la partie | **S** |
| J11 | **Fan de ton jeu** | Temps cumulé par jeu supérieur à 10 h | Il obtient l'écharpe ou le badge du jeu (cosmétique générique aux couleurs dominantes captées à l'écran : palette moyenne des sessions) | Récompense de fidélité, sans interruption | **M** |

### 2.3 Boîte aux lettres

C'est le cœur du « jamais pénible ». Tout ce qui n'est pas une emote est mis en file. La file est livrée :

- au **alt-tab** vers le bureau,
- ou à la **fermeture du jeu**,
- ou pendant un **menu de pause** détecté.

Elle prend la forme d'une enveloppe sur sa tête. Un clic l'ouvre. Si on ne clique pas, elle disparaît au bout de 2 min et reste lisible dans le carnet. **Effort S.** C'est un quick win structurel : tous les autres comportements en dépendent.

### 2.4 Personnalité par espèce (exemples)

| Situation | Mochi (câlin) | Pico (distingué) | Coco (cool) | Nuage (rêveur, artiste) | Kiwi (gamer, énergique) |
|---|---|---|---|---|---|
| Victoire | Câlin-saut | Applaudit poliment avec un monocle | Lunettes de soleil, hoche la tête | Dessine un petit soleil | Danse de victoire, trash-talk (« ez ») |
| Mort ou défaite | Tapote ta barre des tâches | « Hm. Regrettable. » (différé) | Hausse les épaules | Pluie de pétales tristes | Tape du pied, puis « revanche ! » |
| Chargement | Grignote un mochi | Lit un journal | Regarde son téléphone | Croque le paysage à l'écran | Fait des pompes |
| Plus de 2 h de jeu | Apporte une couverture | Sort sa montre à gousset | « Pas mal. » | S'endort sur son carnet | Bandeau de sueur, encore plus hype |
| Traversée de l'écran | Rebondit | Monte à l'échelle | Grappin | Flotte | **Se balance avec sa langue** sur les bords de fenêtre |

---

## 3. Sur le bureau

### 3.1 Fenêtres comme terrain de jeu (en plus des plateformes en cours)

| Idée | Détection | Comportement | Effort |
|---|---|---|---|
| **Chute cartoon** | La fenêtre-plateforme disparaît (fermée ou minimisée) | Il reste suspendu en l'air 0,4 s, regarde la caméra, puis tombe. La réception dépend du matériau : la gelée fait splat, le chrome rebondit et sonne « tink », la pâte à pain s'aplatit. S'il possède le parapluie, il descend en planant (Mary Poppins) | **S** |
| **Vertige** | La fenêtre est secouée (aller-retour rapide, accélération > seuil) | Il s'accroche, ses yeux tournent en spirale, puis il est éjecté. La slime **colle** et ne tombe pas. Le chrome **glisse** | **S** |
| **Ascenseur** | La plateforme est maximisée et la barre de titre monte à y = 0 | Il est propulsé vers le haut, se cogne la tête au bord de l'écran (emote étoiles) et redescend en glissant le long du bord | **S** |
| **Redimensionnement** | La largeur de la fenêtre-plateforme diminue sous lui | Il est poussé, court en sens inverse comme sur un tapis roulant, puis tombe au bout | **S** |
| **Coucou derrière une fenêtre** (faux) | Rects + z-order connus. On clippe le rendu de Pompom au bord de la fenêtre voisine (plan de coupe dans le shader) | Il « sort de derrière » le bord d'une fenêtre, une moitié du corps seulement. C'est l'illusion de profondeur que la plupart des desktop pets n'ont pas | **M** |
| **Suspendu ou escalade** | Bords verticaux et bord bas des fenêtres | Il pend par les oreilles sous une fenêtre. La gelée et la slime grimpent les bords latéraux (ventouse) | **M** |
| **L'horloge** | Rect de la barre des tâches (`SHAppBarMessage`) + position de la zone de notification | Il s'assoit sur l'horloge. À l'heure pile, il sonne une mini-cloche (emote notes, sans son par défaut) | **S** |
| **Menu Démarrer / recherche** | Premier plan sur `StartMenuExperienceHost` ou `SearchHost` | Il lève la tête, curieux. « ? » | **S** |
| **Corbeille** | Explorateur dont le titre est « Corbeille » | Il se pince le nez, sort un balai | **S** |
| **Trop de fenêtres** | Plus de 15 fenêtres visibles | Il jongle avec de petits carrés, puis s'effondre en souriant. Au maximum une fois par jour | **S** |
| **Déposer un fichier sur lui** | Signal `files_dropped` de Godot 🆕 à vérifier avec le click-through (zone hit-test sur le pet) | Une image : il la tient comme un tableau et commente sa couleur dominante, puis elle va dans sa « galerie ». Il ne supprime ni ne modifie **jamais** le fichier | **M** |
| **Se cacher dans une icône du bureau** | Positions des icônes via `LVM_GETITEMPOSITION` sur la ListView de `Progman` 🆕 (inter-process, fragile) | Cache-cache dans les dossiers | **L**, plus tard |

> **Le curseur** : on ne **bouge jamais** la vraie souris (règle d'or). On joue *avec* elle.
> - **Bond de chat** : le curseur s'arrête à moins de 80 px pendant plus de 1,5 s et le bureau est au premier plan. Il prend la posture du chat, fesses qui gigotent, puis saute « dessus ». Au maximum 1 fois toutes les 10 min. **S**
> - **Pointeur laser** (objet de boutique) : quand il est équipé, les cercles de souris sur le bureau le font courir après le point. Désactivé automatiquement dès qu'une app de travail ou un jeu est au premier plan. **S**
> - **Flick rapide** : sa tête suit la trajectoire, il en a le tournis. **S**

### 3.2 Réactions aux applications

| App / contexte | Détection | Comportement | Effort |
|---|---|---|---|
| **Musique** | Pics de la session audio de Spotify ou de n'importe quel lecteur (`IAudioMeterInformation`) 🆕. Détection d'attaques simple pour trouver le **tempo** | Il danse **sur le temps** : bob, hochements, notes. Le titre Spotify (« Artiste – Titre ») permet : « 7e écoute aujourd'hui 👀 » (différé) et un « top 3 de la semaine » dans le carnet | **M** |
| **Vidéo** (YouTube, Netflix, Twitch, VLC) | Mots-clés du titre + session audio active | Il se tourne vers l'écran, **dos à toi**, avec du pop-corn. Quand le son s'arrête (pause), il se retourne avec un « ? ». En vidéo plein écran : mode périscope et zéro bulle | **S** |
| **Visio** (Teams, Zoom, Meet, Discord en appel) | Processus et titre (« Réunion », « Meet – ») | Il met un doigt sur la bouche puis se fait tout petit dans le coin. **Aucune bulle, aucune emote animée.** C'est critique : en partage d'écran, il ne doit pas surprendre | **S** |
| **OBS / enregistrement** | Processus OBS ou Game Bar actif | Mode « streamer » au choix : il se cache, ou il fait coucou à la caméra et devient sage. C'est une piste de croissance : Pompom vu en stream | **S** |
| **Compilation** | Terminal ou IDE au premier plan + CPU de l'arbre de processus élevé, ou titre du terminal contenant `build`, `cargo`, `npm run`… | Il s'évente, la sueur monte avec la durée. Quand le CPU retombe, il jette un œil à l'écran : « fini ? » | **M** |
| **Frappe intense** | Nombre de touches (même hook que J1) | Il tape en rythme sur son laptop (synchronisé avec toi). Au-delà de 5 000 touches sans pause : il masse ses petites mains (rappel muet) | **S** une fois J1 fait |
| **Batterie / réseau / USB** | `GetSystemPowerStatus`, changement de réseau, `WM_DEVICECHANGE` 🆕 | Batterie faible : il bâille et traîne une prise. Il dort mieux pendant la charge. Wi-Fi coupé : câble cassé dans les mains. Clé USB : il regarde sur le côté | **S** |
| **Son coupé / volume** | Mixer Windows | Muet : il se bouche les oreilles puis fait « ? ». Volume au maximum : ses oreilles s'envolent | **S** |
| **Capture d'écran** | Outil Capture d'écran au premier plan, ou image dans le presse-papiers (format seulement, jamais le contenu) | Il prend la pose | **S** |

### 3.3 Heure, saisons, météo

- **Rituel du matin** : première activité de la journée. Il s'étire, dit « bonjour » et donne la date, la série en cours et la météo. C'est la seule bulle garantie de la journée. **S**
- **Midi et demi** : il mange un sandwich. **16 h** : goûter. **Après 23 h** : pyjama. **Après 1 h** : « dodo ? », une seule fois. **S**
- **Fermeture de Windows** (`WM_QUERYENDSESSION`) : il fait un petit « bonne nuit » de la main. **S**
- **Fêtes françaises** :
  - Halloween : costume proposé à partir du 24 octobre (c'est dans 3 semaines, à faire en premier).
  - Noël.
  - Chandeleur : crêpe qu'il fait sauter, ratée selon le matériau.
  - Poisson d'avril : il colle un poisson en papier sur la barre de titre de ta fenêtre active.
  - Fête de la musique : danse toute la journée.
  - 14 juillet : feux d'artifice au-dessus de la barre des tâches.
  - Anniversaire de Pompom : date d'installation.

  **S** chacune (assets).
- **Météo** : Open-Meteo (gratuit, sans clé), avec la ville demandée une seule fois 🆕 réseau. Pluie : parapluie et gouttes sur la barre des tâches. Neige : écharpe et petit tas de neige qui s'accumule sur les barres de titre. Canicule : éventail et petite piscine gonflable. **M**
- **Thème Windows clair ou sombre** : il allume une lampe de chevet en sombre. **S**

---

## 4. Accessoires / objets interactifs à ajouter

| Objet | Quand | Pourquoi c'est bien | Effort |
|---|---|---|---|
| **Pop-corn** | Vidéo, cinématique | Signal clair de « regarder ensemble » | S |
| **Skateboard** | Déplacements de plus de 600 px, changement d'écran | Rend les longues traversées lisibles et drôles au lieu d'une téléportation | S |
| **Parapluie** | Pluie (météo), chute de fenêtre | Double usage météo et physique | S |
| **Échelle / grappin / langue** | Pour monter sur les barres de titre selon l'espèce | La traversée devient de la personnalité (voir §2.4) | M |
| **Canne à pêche** | Utilisateur présent mais inactif depuis 1 à 3 min (il lit, il réfléchit) | Il pêche au bord de la barre des tâches dans « l'eau » du bureau. Les prises (poissons, bottes, accessoires rares) vont dans une collection. **Récompense asynchrone** | M |
| **Petit lit** (boutique) | Sommeil après 3 min d'absence | Placé à un endroit choisi de la barre des tâches. Point d'ancrage de sa « maison » | S |
| **Carnet à croquis** (Nuage surtout) | Inactivité en journée | Il « peint ce que tu regardes » : un tableau abstrait généré depuis la **palette dominante** de l'écran (capture basse résolution, rien de lisible), ajouté à une galerie | M |
| **Livre** | Lecture de PDF ou d'article long (défilement seul, aucune touche) | Il lit à côté de toi | S |
| **Casque audio** | Vocal Discord | Voir J5 | S |
| **Éventail** | Compilation, CPU élevé, canicule | Lien visible avec l'état de la machine | S |
| **Appareil photo** | Capture d'écran | Remplit son carnet de polaroids | S |
| **Pot de fleur** | Série quotidienne | La plante grandit avec les jours de présence. Elle ne meurt pas, elle attend | S |
| **Mini-cloche** | Heure pile sur l'horloge | Repère temporel discret | S |
| **Accessoires de genre de jeu** | Voir J4 | Collection liée à ta ludothèque | M |

---

## 5. Mini-jeux et relation

### 5.1 Relation

- **Affinité, niveaux 0 à 10.** On en gagne en caressant, en nourrissant, en offrant ce qu'il aime, en passant du temps ensemble et en faisant des pauses. Chaque niveau **débloque des comportements**, pas seulement un chiffre :
  - niveau 2 : il t'attend en ouvrant les yeux quand tu reviens ;
  - niveau 4 : il apporte des cadeaux après tes longues sessions (accessoire ou pièces) ;
  - niveau 6 : il te donne un surnom ;
  - niveau 8 : il s'endort contre ta fenêtre active quand tu pars ;
  - niveau 10 : danse secrète.

  **M**
- **Nourrir.** On glisse un aliment de l'inventaire sur lui. Ses goûts suivent ceux des accessoires (j'aime / j'aime pas). Pas de faim punitive : quand il a faim, il est seulement un peu grognon, et ça passe. Ça crée un puits de pièces. **S**
- **Carnet de Pompom (souvenirs).** Journal écrit à la première personne, automatiquement :
  > « Mardi. On a joué 3 h à Hades, tu as eu un succès. J'ai pêché une botte. Tu as écouté *Daft Punk* 9 fois. »

  On y trouve les polaroids (de *lui*, jamais de ton écran), les tickets de session, les tableaux de Nuage et les prises de pêche. Il y a un récap hebdomadaire le lundi matin. C'est **le** liant émotionnel : la preuve qu'il se souvient. **M**
- **Séries (streaks).** Au moins une interaction par jour. La plante grandit. 2 jokers de gel par mois. Paliers à 7, 30 et 100 jours, avec un accessoire unique. **S**

### 5.2 Mini-jeux (opt-in, toujours sur le bureau, jamais en jeu)

- **Cache-cache au retour d'absence** : à ton retour après plus de 10 min, il se cache derrière une fenêtre (clip §3.1), sous la barre des tâches ou dans un coin, avec seulement les oreilles qui dépassent. Tu as 30 s pour cliquer sur lui : 10 🪙 et un rire. Au maximum 1 fois par retour, désactivable. **M**
- **Attrape-moi** : il file sur la barre des tâches en skate. Le clic doit tomber pile au bon moment. Le matériau change la difficulté (le chrome glisse vite). **S**
- **Pêche** (asynchrone, §4) avec un **aquarium de prises** à compléter. **M**
- **Lancer de précision** : le lancer existe déjà. On ajoute une cible (une tasse posée sur une barre de titre) : le faire atterrir dedans rapporte des pièces, et la physique dépend du matériau. **S**
- **Chambre sur la barre des tâches** (façon Animal Crossing) : on achète des meubles (lit, lampe, plante, tapis, poster de jeu) qu'on pose le long de la barre des tâches. Il les utilise vraiment : il dort dans le lit, arrose la plante. C'est le **gros puits de pièces** de long terme. **L**
- **Économie** : on garde 3 🪙/min. On ajoute un bonus de pause, des pièces pour les mini-jeux et un plafond quotidien de pièces « gagnées en jouant » (par exemple 4 h) pour ne pas encourager les sessions interminables.

---

## 6. Mobile (court)

- **Toucher** : caresse au doigt, pincement pour l'écraser (le matériau change la déformation), chatouilles sur le ventre.
- **Accéléromètre** : secouer lui donne le vertige. Incliner le fait rouler et glisser selon le matériau. Téléphone posé à l'envers : il dort.
- **Continuité avec le PC** : quand le PC s'éteint, il « part dans ton téléphone » (même pet, même carnet, synchro cloud 🆕). Au retour sur le PC, il raconte sa journée mobile.
- **Widget écran d'accueil / Live Activity** : il dort, mange, pêche. Une prise toutes les 2 h à récupérer.
- **Podomètre** : il marche avec toi et gagne des pièces en marchant (une économie saine).
- **Notifications** : on ne peut pas lire celles des autres apps (iOS). Seulement ses propres notifications, très rares : « j'ai pêché un truc ! »
- **Jeux sur mobile** : impossible sur iOS. Sur Android, `UsageStats` avec permission explicite. Plus tard.

---

## 7. Top 15 : feuille de route

Score = plaisir (1 à 5) × faisabilité (1 à 5). ⭐ = les 5 meilleurs quick wins.

| Rang | Idée | Plaisir | Faisab. | Score | Effort | Pourquoi maintenant |
|---|---|---|---|---|---|---|
| 1 ⭐ | **Boîte aux lettres + récap de session** (§2.3, J8) | 4 | 5 | 20 | S | C'est la fondation du « jamais pénible ». Tout le reste en dépend |
| 2 ⭐ | **Placement en jeu : 2e écran + place mémorisée par jeu + périscope + esquive** (P1, P2, P3, P5) | 4 | 5 | 20 | S | Règle 80 % du problème « il gêne en jeu » sans analyse d'image |
| 3 ⭐ | **Manette miroir** (J1, partie manette) | 5 | 4 | 20 | S | C'est l'effet Bongo Cat : « il joue avec moi ». Pur plaisir |
| 4 ⭐ | **Chutes, vertige et ascenseur des fenêtres** (§3.1) | 5 | 4 | 20 | S | S'appuie directement sur les plateformes en cours. La physique des matériaux brille enfin |
| 5 ⭐ | **Mode visio / OBS silencieux + vidéo avec pop-corn** | 3 | 5 | 15 | S | Évite le pire moment de gêne (en réunion) et donne une scène très mignonne |
| 6 | **Pic audio par processus** : danse sur le tempo, intensité de jeu, casque en vocal (J3, J5, musique) | 5 | 3 | 15 | M | Un seul ajout au helper, au moins 4 comportements en profitent |
| 7 | **Détection des pauses en jeu** (chargement, cinématique, menu) (J2) | 4 | 3 | 12 | M | Donne le seul bon moment pour parler et pour les rappels bien-être |
| 8 | **Rituels du jour, heures et fêtes** (Halloween en premier) | 3 | 4 | 12 | S/M | Il vit au rythme de ta journée. Halloween dans 3 semaines |
| 9 | **Carnet de souvenirs + affinité** | 4 | 3 | 12 | M | Crée l'attachement de long terme et le retour quotidien |
| 10 | **Coucou derrière une fenêtre + cache-cache au retour** | 4 | 3 | 12 | M | Illusion de profondeur rare chez les desktop pets, très partageable |
| 11 | **Accessoires selon le genre de jeu** (J4) | 4 | 3 | 12 | M | Collection liée à la ludothèque. Surtout du travail d'assets |
| 12 | **Traversées par espèce** (langue de Kiwi, échelle de Pico, grappin de Coco…) | 4 | 3 | 12 | M | Rend chaque espèce distincte en mouvement, pas seulement en apparence |
| 13 | **Pêche sur la barre des tâches + collection** | 4 | 3 | 12 | M | Boucle asynchrone de récompense, puits de pièces |
| 14 | **Intégrations officielles LoL / CS2 GSI** (J6) | 5 | 2 | 10 | M par jeu | Vraies réactions mort/victoire, mais limité à quelques jeux |
| 15 | **Carte de calme** (coin sans HUD automatique) (P4) | 3 | 2 | 6 | M/L | Utile seulement après les ratés de P1, P2 et P3. À faire plus tard |

**Ordre conseillé :** 1 → 2 → 4 → 3 → 5 (deux semaines de quick wins), puis 6 (le helper audio débloque plusieurs lignes), puis 8 (Halloween), puis 7, puis 9.

---

## Annexe : nouvelles capacités techniques (🆕)

| Capacité | API Windows | Risque / note |
|---|---|---|
| Fenêtre jamais activée | `WS_EX_NOACTIVATE` sur la fenêtre Godot (via le helper ou un GDExtension) | À vérifier : un clic sur le pet ne doit pas sortir du jeu |
| Écrans multiples | `EnumDisplayMonitors` / `DisplayServer.get_screen_count()` de Godot | Trivial |
| Plein écran exclusif | `SHQueryUserNotificationState` | Trivial. Renvoie aussi « présentation » ou « occupé » |
| Niveau audio par processus | `IAudioSessionManager2` → `IAudioMeterInformation::GetPeakValue` | Aucun enregistrement, seulement un niveau. Respecte la vie privée |
| Nombre de touches | Raw Input + `RIDEV_INPUTSINK` (préférable à un hook bas niveau) | Compteur seulement, jamais de contenu. Désactivé pour la liste compétitif par prudence anti-cheat |
| Manette hors focus | Joypad de Godot (à tester sans focus) ou sinon `XInputGetState` dans le helper | Lecture seule |
| Événements de jeu | LoL Live Client API (`:2999`), CS2/Dota GSI (POST HTTP local) | Officiel, aucun risque anti-cheat |
| Surveillance de fichiers | Dossiers screenshots et stats de Steam | Le format des stats est à vérifier |
| Fichiers déposés sur la fenêtre | `files_dropped` de Godot | Compatibilité avec le click-through à vérifier |
| Icônes du bureau | `LVM_GETITEMPOSITION` sur la ListView de Progman | Fragile. Plus tard |
| Météo | HTTP vers Open-Meteo | Demande la ville une seule fois. Rien d'autre ne sort |
