# Journal des versions

Toutes les versions de Pompom. Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/)
et les numéros suivent [SemVer](https://semver.org/lang/fr/).

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
