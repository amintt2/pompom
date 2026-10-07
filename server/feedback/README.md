# Serveur de contributions anonymes de Pompom

Petit serveur (FastAPI + SQLite en mode WAL) qui reçoit les corrections **anonymes** des joueurs qui ont
activé « Aider à améliorer Pompom (anonyme) ». Il ne reçoit que des **embeddings** (128 à 1024 nombres
calculés sur le PC du joueur) + l'étiquette corrigée + la tâche + le nom du programme + l'identifiant du
modèle. Jamais d'image, de titre de fenêtre, de texte, d'identifiant. Détails côté joueur : [docs/donnees.md](../../docs/donnees.md).

Vie privée côté serveur :

- **aucun journal des requêtes** (`uvicorn --no-access-log`, rien n'est journalisé par l'application) ;
- l'IP ne sert qu'à limiter le débit, **en mémoire**, **hachée** (HMAC) avec un sel aléatoire renouvelé
  toutes les 24 h, jamais écrite ; aucun cookie ; seule la **date** (jour UTC) de réception est gardée ;
- schéma **strict** : un champ inconnu (ex. `title`, `image`) fait rejeter toute la requête ;
- conservation : `RETENTION_DAYS` (730 jours par défaut), purge automatique.

## API

| Route | Accès | Rôle |
|---|---|---|
| `POST /v1/contrib` | public (limité en débit) | `{"schema": 1, "client": "0.6.0-beta", "items": [...]}` → `{"accepted", "duplicates"}` |
| `GET /v1/health` | public | `{"ok": true}` (healthcheck) |
| `GET /v1/export?since=ID\|AAAA-MM-JJ&limit=N` | `Authorization: Bearer ADMIN_TOKEN` | JSON Lines (`application/x-ndjson`) ; en-tête `x-next-since` = dernier id |
| `GET /v1/stats` | `Authorization: Bearer ADMIN_TOKEN` | comptes par tâche, étiquette, modèle, jour, appli |

Un exemple (`items[]`), tous les champs obligatoires sauf `app` et `pet`, aucun autre accepté :

```json
{"task": "activity", "label": "music", "app": "spotify",
 "model_id": "siglip-b16-224.fp16", "model_version": "e79563a4df40",
 "dim": 768, "dtype": "float16", "emb": "<base64 de 768 float16 petit-boutistes, norme L2 = 1>",
 "pet": {"situation": "video_watch", "vision": "video", "mode": "video", "event": ""}}
```

- `task` ∈ `activity`, `game_event`, `field_kind` ; `label` dans le vocabulaire de la tâche (voir `TASKS` dans `app.py`).
- `dim` 128..1024 ; `dtype` `float16` ou `float32` ; vecteur fini, de norme 1 (± 0,1).
- `app` : `^[a-z0-9][a-z0-9._+ -]{0,39}$` (nom de processus nettoyé, sans `.exe`).
- 32 exemples max par requête (`MAX_ITEMS`), 256 Ko max (`MAX_BODY`). Doublons ignorés (même tâche, étiquette, modèle, vecteur).
- Réponses d'erreur : `400` (schéma ; seul le chemin du champ fautif est renvoyé, jamais la valeur), `413`, `415`, `429` (+ `retry-after`).

## Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `ADMIN_TOKEN` | *(vide = routes admin désactivées)* | jeton des routes `/v1/export` et `/v1/stats` (32+ caractères aléatoires) |
| `MAX_BODY` | `262144` | taille max d'une requête (octets) |
| `MAX_ITEMS` | `32` | exemples max par requête |
| `RATE_LIMIT` | `120/3600` | requêtes max par IP et par fenêtre (`N/secondes`) |
| `TRUSTED_PROXY_HOPS` | `1` | proxys de confiance devant le serveur (Traefik de Coolify = 1 ; accès direct = 0) |
| `RETENTION_DAYS` | `730` | durée de conservation |
| `DB_PATH` | `/data/feedback.db` | base SQLite (dans le volume) |

## Déployer sur Coolify

Le dépôt contient tout : `Dockerfile` (utilisateur non root, healthcheck) et `docker-compose.yml` (un seul
service, volume `feedback-data` monté sur `/data`).

1. **Projects** → ton projet → environnement (ex. `production`) → **+ New** (*New Resource*).
2. **Public Repository** (ou **Private Repository (with GitHub App)** si le dépôt est privé) → colle l'URL
   du dépôt Pompom, branche `main`.
3. **Build Pack : Docker Compose**.
   - **Base Directory** : `/server/feedback`
   - **Docker Compose Location** : `/docker-compose.yml`
   - **Continue**.
4. Dans la ressource, onglet **General** → section du service `feedback` → **Domains** :
   `https://feedback.ton-domaine.fr:8000` (le `:8000` indique à Coolify le port **du conteneur** ; le public
   passe par 443 en HTTPS, certificat Let's Encrypt automatique). Le DNS `feedback.ton-domaine.fr` doit
   pointer (A/AAAA) vers ton serveur Coolify.
5. Onglet **Environment Variables** :
   - `ADMIN_TOKEN` = une longue valeur aléatoire (ex. `openssl rand -hex 32`), cochée **secret** / non
     visible dans les journaux de build ;
   - les autres sont facultatives (valeurs par défaut ci-dessus). Garde `TRUSTED_PROXY_HOPS=1` derrière Traefik.
6. Onglet **Persistent Storage** : le volume nommé `feedback-data` → `/data` apparaît tout seul (créé
   depuis le compose). Rien à faire ; c'est lui qui garde la base entre deux déploiements.
7. **Deploy**. Le statut passe à *Running (healthy)* grâce au healthcheck `GET /v1/health`.
8. Vérifie : `curl https://feedback.ton-domaine.fr/v1/health` → `{"ok":true}`.

Variante sans compose : **Build Pack : Dockerfile**, *Base Directory* `/server/feedback`, *Ports Exposes*
`8000`, puis ajoute à la main un *Persistent Storage* (volume) monté sur `/data`, et les mêmes variables.

Sauvegarde : la base est un seul fichier SQLite dans le volume (`/data/feedback.db`, + `-wal`/`-shm`).
Coolify peut sauvegarder le volume, ou utilise `GET /v1/export` régulièrement.

## Brancher Pompom sur le serveur

Le jeu n'envoie rien tant que l'adresse est la valeur factice `https://pompom-feedback.example`. Au choix :

- pour une version publiée : réglage de projet `pompom/feedback/endpoint="https://feedback.ton-domaine.fr"`
  dans `godot/project.godot` (section `[pompom]`) ;
- pour tester sur un PC : écrire l'adresse dans `%APPDATA%\Pompom\feedback_endpoint.txt` (1re ligne).

HTTPS obligatoire (sauf `http://127.0.0.1` / `http://localhost` pour les tests).

## Récupérer les données pour l'entraînement

```powershell
$h = @{ Authorization = "Bearer $env:POMPOM_FEEDBACK_ADMIN" }
Invoke-WebRequest "https://feedback.ton-domaine.fr/v1/export?since=0" -Headers $h -OutFile assistant\data\real\export.jsonl
cd assistant
.venv\Scripts\python.exe tools\build_real_dataset.py --export data\real\export.jsonl
dev\.venv\Scripts\python.exe tools\train_real_heads.py
```

Pour un export incrémental, repars de la valeur de l'en-tête `x-next-since` de l'export précédent.

## Développement

```powershell
cd server\feedback
python -m venv .venv; .venv\Scripts\pip install -r requirements-dev.txt
.venv\Scripts\python -m pytest -q          # 29 tests (schéma, limites, débit, admin, vie privée)
$env:DB_PATH="feedback.db"; $env:ADMIN_TOKEN="dev"; .venv\Scripts\uvicorn app:app --port 8000 --no-access-log
```

Le test `test_godot_payload_is_accepted` vérifie qu'un lot réellement produit par le jeu
(`godot/tests/feedback_test.tscn`, qui écrit `%APPDATA%\Pompom\feedback_payload_sample.json`) est accepté.
