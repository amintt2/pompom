# Tes données et Pompom

Pompom apprend de ses erreurs. Quand il croit que tu regardes une vidéo alors que tu écoutes de la musique,
ou qu'il ne fête pas le but que tu viens de marquer, tu peux le corriger. Cette page explique **ce qui est
gardé sur ton PC**, **ce qui part (seulement si tu l'acceptes)** et **comment tout effacer**.

En bref :

- **Par défaut, rien ne quitte ton PC.** Les corrections sont enregistrées sur ton PC uniquement.
- Le partage anonyme est **désactivé par défaut**. Si tu l'actives, seuls des **nombres** partent : jamais
  d'image, jamais de titre de fenêtre, jamais de texte tapé, jamais d'identifiant.
- Un bouton **« Effacer mes données d'entraînement »** supprime tout, à tout moment.

---

## 1. Corriger le compagnon

- **Clic droit sur lui → « Il s'est trompé… »**, ou
- **clic gauche** pendant qu'il fait quelque chose tout seul (il imite ce que tu fais, mange du pop-corn
  devant une vidéo…) ou juste après un moment de jeu : une petite pastille **« Il s'est trompé ? »**
  apparaît à côté de lui pendant 4 secondes.

La carte te demande **ce que tu faisais vraiment** (Vidéo, Musique, Jeu, Code, Claude / IA, Mails,
Documents, Tableur, Discussion, Réseaux, Lecture, Design, Web, Visio, Autre…) et, en jeu, **le moment qu'il
a raté** (« J'ai marqué », « Je suis mort », « Mon équipe a perdu »…). Après une suggestion de collage, elle
te demande aussi ce qu'était vraiment le champ (e-mail, téléphone…).

## 2. Ce qui est gardé sur ton PC

Dossier : `%APPDATA%\Pompom\dataset\` (rien d'autre n'est écrit ailleurs).

| Quoi | Où | Contenu |
|---|---|---|
| Tes corrections | `feedback.jsonl` | ce que tu as choisi, l'appli au premier plan, ce que le compagnon avait décidé, le titre de la fenêtre, ta note « Autre… », et l'**empreinte numérique** de l'écran (voir plus bas) |
| État d'envoi | `sent.jsonl` | quelles corrections ont déjà été partagées |
| Petites captures | `shots\` | **seulement en mode développeur** : une capture réduite jointe à la correction |
| Captures du mode développeur | `screens\` | **seulement si tu actives le mode développeur** (voir § 5) |

- Taille limitée : environ 12 Mo de corrections au plus (les plus anciennes sont supprimées), 300 petites
  captures au plus, 2 Go pour le mode développeur.
- **Jamais** de capture ni d'empreinte quand une fenêtre privée est au premier plan : gestionnaire de mots
  de passe, page de connexion, code de vérification (2FA), banque, navigation privée, sécurité Windows… ni
  pendant une visio, un enregistrement ou un stream.

### L'« empreinte numérique » de l'écran (embedding)

Quand l'assistant local est installé et lancé, il regarde l'écran **une fois**, au moment où tu ouvres la
carte, et le résume en **768 nombres** (un « embedding », calculé par le même modèle de vision que
d'habitude). L'image elle-même n'est **jamais écrite ni envoyée** : elle reste en mémoire le temps du calcul.
Ces nombres servent à ré-entraîner les petites « têtes » de décision de Pompom sur de vraies situations.

Pour un champ de saisie, l'empreinte est calculée à partir de sa **description** (type de contrôle, nom,
étiquette), **sans le titre de la fenêtre** et **jamais à partir de ce que tu as tapé** ; jamais pour un champ
mot de passe.

## 3. Ce qui part si tu l'acceptes (partage anonyme)

Réglage : **Réglages → Assistant → « Aider à améliorer Pompom (anonyme) »** (désactivé par défaut). Ensuite,
pour chaque correction, la case **« Partager anonymement »** te laisse encore choisir, et **« Voir ce qui
part »** affiche le JSON exact qui sera envoyé.

Voici **tout** ce qui part, pour une correction :

```json
{
  "schema": 1,
  "client": "0.6.0-beta",
  "items": [
    {
      "task": "activity",
      "label": "music",
      "app": "spotify",
      "model_id": "siglip-b16-224.fp16",
      "model_version": "e79563a4df40",
      "dim": 768,
      "dtype": "float16",
      "emb": "…768 nombres encodés en base64…",
      "pet": {"situation": "video_watch", "vision": "video", "mode": "video", "event": ""}
    }
  ]
}
```

- `task` / `label` : ce que tu as corrigé, choisi dans une liste fixe.
- `app` : le **nom du programme** au premier plan (ex. `spotify`, `chrome`), sans chemin.
- `model_id` / `model_version` / `dim` / `dtype` / `emb` : l'empreinte numérique de l'écran (ou du champ).
- `pet` : ce que le compagnon avait décidé (valeurs d'une liste fixe).
- `client` : la version de Pompom.

**Ne part jamais** : images, captures, titres de fenêtres, texte tapé ou copié, ta note « Autre… », noms de
fichiers, l'heure exacte, un identifiant de joueur ou d'appareil. Le serveur ne garde **ni ton adresse IP,
ni de cookie, ni de journal des requêtes** ; seule la **date de réception** (le jour) est conservée.

Limites honnêtes :

- Une empreinte n'est pas une image, mais elle **résume** l'écran : en théorie, quelqu'un qui aurait le même
  modèle pourrait deviner grossièrement le *genre* d'écran (un tableur, un jeu de foot…), pas son texte.
  C'est pour cela que rien n'est calculé sur les fenêtres privées, et que le partage est désactivé par défaut.
- Le nom d'un programme très rare (un logiciel interne d'entreprise) peut en dire un peu sur toi. Si cela te
  gêne, ne partage pas ces corrections-là (décoche la case).

Le serveur qui reçoit ces données est auto-hébergé par le développeur de Pompom (code : `server/feedback/`).
Les contributions sont gardées **2 ans au plus** puis supprimées automatiquement ; elles servent uniquement à
entraîner les petits modèles de Pompom.

## 4. Tout effacer

**Réglages → Assistant → « Effacer mes données d'entraînement »** supprime le dossier
`%APPDATA%\Pompom\dataset\` en entier (corrections, petites captures, captures du mode développeur).

Les contributions déjà partagées sont anonymes : elles ne sont reliées à rien qui permette de les retrouver,
donc on ne peut pas les supprimer une par une. Tu peux arrêter le partage à tout moment (le réglage coupe
tout envoi immédiatement).

## 5. Mode développeur : collecter mes écrans

Réglage : **« Mode développeur : collecter mes écrans »** (désactivé par défaut). Pensé pour le développeur
de Pompom, sur **son propre PC**.

- Une capture de l'écran principal **toutes les 3 minutes**, au format WebP, à la résolution native (réduite
  seulement au-delà de 2560 px de large), environ **250 Ko** par capture en 2560 × 1440, avec un petit fichier
  `.json` (programme, titre, catégorie, ce que faisait le compagnon).
- Stockage **local uniquement**, plafonné à **2 Go** (les plus anciennes sont supprimées) : environ 8 000
  captures. Le jeu **n'envoie jamais** ces captures.
- Mêmes exclusions que plus haut (mots de passe, connexion, banque, navigation privée, visio, stream).
- Ces captures peuvent ensuite être étiquetées à la main ou par un grand modèle de vision (outil
  `assistant/tools/label_screens.py`, lancé volontairement par le développeur avec sa propre clé) : les
  images partent alors chez le fournisseur choisi. Ne l'utilise que sur tes propres captures.

## 6. Contact

Une question, une demande ? Ouvre un ticket sur
[github.com/amintt2/pompom/issues](https://github.com/amintt2/pompom/issues).
