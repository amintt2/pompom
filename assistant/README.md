# Assistant local de Pompom (suggestions de collage)

Quand tu cliques dans un champ de saisie n'importe où dans Windows (email, adresse, recherche, message,
éditeur de code…), Pompom regarde **la description** du champ et te propose le texte copié qui va bien :
bulle « Coller ton email ? ». Tout tourne sur ton PC : aucune connexion Internet après l'installation,
aucun service en ligne, aucune télémétrie.

```
 Godot (SuggestClient)                       assistant/service.py  (127.0.0.1, jeton secret)
 ─────────────────────                       ──────────────────────────────────────────────
  textes copiés (ClipboardKeeper) ─┐          FocusWatcher : UI Automation, 4 lectures/s, ~3 ms
  GET /focus (attente longue) ◄────┼───────── description du champ focus (jamais son contenu)
  POST /suggest {candidats} ───────┘──────► Decider
                                               1. règles/regex (< 1 ms) : 77 % des cas
                                               2. sinon llama-server (Vulkan ou CPU), réponse
                                                  contrainte par grammaire, 1 seul token décodé
  signal suggestion(text_fr, index, kind) ◄─── {kind, index, confidence, label_fr}
  emotes.say("Coller ton email ?")
```

## Installation

```powershell
powershell -ExecutionPolicy Bypass -File assistant\setup.ps1        # ~1,1 Go (Llama-3.2-1B)
powershell -ExecutionPolicy Bypass -File assistant\setup.ps1 -Light # ~0,6 Go (Qwen2.5-0.5B)
```

Le script crée `assistant/.venv` (Python 3.11, une seule dépendance : `comtypes`), télécharge
llama.cpp officiel (build `b11443`, versions **Vulkan** et **CPU**) dans `assistant/llama/` et le modèle
dans `assistant/models/` (ignorés par git). Sur cette machine tout est déjà installé.

Dans le jeu : réglage `suggestions` (désactivé par défaut, opt-in) et `ai_gpu` (vrai par défaut ; faux =
le modèle tourne sur le processeur). Réglage optionnel `ai_model` = nom du fichier `.gguf` à utiliser.

## Vie privée

- Le service n'écoute que sur `127.0.0.1`, exige un jeton aléatoire (en-tête `X-Pompom-Token`), refuse
  toute requête avec un en-tête `Origin` (pages web) ou un `Host` inattendu (attaque « DNS rebinding »).
- `llama-server` écoute aussi sur `127.0.0.1` seulement, avec sa propre clé aléatoire (passée par variable
  d'environnement) ; sans elle n'importe quelle page web aurait pu l'interroger (il autorise CORS `*`).
- On ne lit **jamais** la valeur d'un champ, seulement : type de contrôle, nom/libellé, id d'automatisation,
  texte d'aide, classe, rôle ARIA, nom du processus, titre de la fenêtre.
- Champs **mot de passe** : ignorés entièrement (`{"skip":"password"}`, sans aucun autre détail).
- Les fenêtres du jeu lui-même sont ignorées. Rien n'est écrit sur le disque (pas de journal, pas de cache
  de prompts : `-cram 0`) ; `--log` (débogage) n'écrit jamais de texte copié.
- Si le jeu est tué brutalement, le service s'arrête (il surveille le PID du jeu) et Windows tue
  `llama-server` (Job Object « kill on close »).

## API du service

| requête | réponse |
| --- | --- |
| `GET /health` (sans jeton) | `{ok, llm: loading/ready/off/error, backend: vulkan/cpu, model}` |
| `GET /focus?after=SEQ&wait=10` | champ focus ; attend jusqu'à 10 s qu'il change |
| `POST /suggest {candidates:[...], field?}` | `{kind, index, confidence, label_fr, kind_source, pick_source, ms, llm_ms}` |
| `POST /decide {question, options:[...], context?}` | `{answer, confidence, probs, ms}` (décision typée générique) |
| `POST /shutdown` | arrête le service et llama-server |

`kind` ∈ email, phone, address, url, search, name, code, chat_message, username, number, date, other.
`index` = position du texte à proposer dans `candidates` (du plus récent au plus ancien), ou -1.

## Comment ça décide

1. **Règles** (`pompom_assist/rules.py`) : type de chaque texte copié par regex (email, url, téléphone,
   adresse, date, nombre, code, nom, identifiant, texte) ; sorte du champ par mots-clés FR/EN
   (« Adresse e-mail », `txtEmailAddress`, « À » d'un client mail, fichier `.py` dans le titre, appli de chat…).
   Un seul mot-clé = sûr (0,9). Plusieurs mots-clés (« Rechercher une adresse ») ou aucun = ambigu.
2. **Modèle local** seulement si c'est ambigu :
   - `field_kind` : choix parmi les 12 sortes, à partir de la description du champ ;
   - `best_candidate` : quand plusieurs **types** de textes conviennent autant (ex. une recherche :
     une phrase ou une adresse ?), le modèle choisit le **type** voulu selon l'appli/la fenêtre (« Google
     Maps » → adresse, « YouTube » → phrase), puis on prend le texte le plus récent de ce type.
     Demander un type plutôt qu'un numéro évite le biais de position des petits modèles.
3. La sortie est contrainte par une **grammaire GBNF** (seules les étiquettes permises sont possibles), on
   décode **un seul token** et on lit les probabilités *après grammaire* (`post_sampling_probs`) : réponse =
   option la plus probable, `confidence` = sa probabilité. Toujours parseable, jamais de texte libre.
4. Trois petits « slots » llama-server (un par type de question) gardent chacun leur long préfixe
   (consignes + exemples) en cache : seule la description du champ (~40 tokens) est calculée à chaque fois.
   Les requêtes sont sérialisées (jamais de décodage parallèle).
5. Le libellé français (« Coller ton email ? », « Chercher « … » ? ») vient de modèles de phrases : instantané
   et toujours correct, plutôt que généré par un modèle de 1 milliard de paramètres.

Sans modèle (démarrage, fichiers absents, erreur), les règles seules répondent : même interface.

## Mesures (Windows 11, i5-10400F, RX 6650 XT, pilote AMD Vulkan)

Jeu synthétique `data/` : 600 cas (champ + 1 à 4 textes copiés → bonne sorte + bon texte ou « rien »),
deux vocabulaires **disjoints** : `dev` (240, a servi à régler règles et exemples) et `test` (360, sites,
applis, libellés et textes jamais vus pendant le réglage). Chiffres sur `test`, « exact » = sorte ET texte
justes. Commande : `python bench.py --split test --llm --gpu` (résultats : `data/bench_results.jsonl`).

| décideur | exact | latence /suggest p50 / p95 | appel modèle p50 / p95 | appels modèle |
| --- | --- | --- | --- | --- |
| règles seules | 0,892 | 0,24 / 0,32 ms | – | 0 % |
| **règles + Llama-3.2-1B, Vulkan** (défaut) | **0,978** | 0,26 / 66 ms | **54 / 71 ms** | 23 % |
| règles + Llama-3.2-1B, CPU (4 threads) | 0,956 | 0,28 / 355 ms | 312 / 424 ms | 23 % |
| règles + Qwen2.5-0.5B, Vulkan | 0,914 | 0,28 / 58 ms | 48 / 65 ms | 23 % |
| règles + Qwen2.5-0.5B, CPU | 0,914 | 0,29 / 282 ms | 234 / 304 ms | 23 % |
| Llama-3.2-1B seul pour la sorte du champ | 0,792 | 55 / 70 ms | | 100 % |

Comparaison initiale (même jeu, PC chargé à 100 % par un rendu Blender, Vulkan) : Qwen3-0.6B 0,856,
Qwen2.5-1.5B 0,950 (appel ~120 ms, 986 Mo), Qwen2.5-0.5B 0,914, Llama-3.2-1B 0,978. Qwen3 et
Qwen2.5-1.5B ont été supprimés du disque. Gemma 3 1B non retenu (licence « Gemma Terms of Use »
plus restrictive).

À savoir, honnêtement :
- Le modèle **seul** est nettement moins bon que les règles (0,79) : il sert à trancher les cas ambigus,
  pas à tout faire. Les erreurs restantes : « Pour » (destinataire Thunderbird) pris pour un message.
- Le jeu test est petit (12 sortes × 2-4 modèles de champ) : une variante de prompt plus courte a perdu
  3 points (0,947) ; nous avons gardé la plus verbeuse. Ce choix a regardé le jeu test une fois : la
  vraie précision sur des champs réels est probablement un peu plus basse et ces données sont
  synthétiques (le vrai web a des champs sans nom, des `aria-label` absents, etc.).
- Sur ce GPU AMD, le pré-remplissage Vulkan de petits lots est limité par le pilote (~720 tokens/s à 32
  tokens) : un appel coûte ~1 ms par token nouveau + ~5 ms. Sur CPU c'est ~5 ms/token : ~300 ms.
- Lecture du champ focus : ~2,5-3 ms par lecture UI Automation (une requête groupée).

Mémoire / disque / démarrage :

| | Vulkan | CPU |
| --- | --- | --- |
| VRAM (Llama-3.2-1B, 3 slots × 1024 tokens) | 779 Mo | 0 |
| RAM llama-server (working set) | ~470 Mo | ~950 Mo |
| RAM service Python | ~44 Mo | ~44 Mo |
| service HTTP prêt | ~0,7 s (règles disponibles) | idem |
| modèle prêt (fichier en cache disque) | ~1,1-1,9 s | ~1,2 s |
| CPU au repos | ~0 (`--poll 0`, attente longue HTTP) | idem |

Disque : llama.cpp Vulkan+CPU 138 Mo, venv 14 Mo, Llama-3.2-1B 808 Mo, Qwen2.5-0.5B 491 Mo (optionnel).

Stabilité GPU : petit modèle entièrement en VRAM (`-ngl 99`, < 0,8 Go sur 8 Go), un lot de 64 tokens,
un décodage à la fois, rien quand personne ne clique. Si Vulkan échoue, le service bascule tout seul sur
la version CPU. Le réglage `ai_gpu = false` force le CPU.

## Tests

```powershell
cd assistant
.venv\Scripts\python.exe -m unittest discover -s tests -v          # règles, sans modèle
$env:POMPOM_TEST_LLM="gpu"; .venv\Scripts\python.exe -m unittest discover -s tests -v   # + modèle
.venv\Scripts\python.exe tests\smoke_service.py [--cpu]            # service HTTP de bout en bout
.venv\Scripts\python.exe bench.py --split test --llm --gpu          # précision + latence
# Godot (lance le service, faux champ + candidats, décision générique, arrêt) :
..\tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path ..\godot res://tests/suggest_test.tscn [-- --cpu]
```

Diagnostic du champ focus en direct : `.venv\Scripts\python.exe -m pompom_assist.focus_probe`.

## Pourquoi pas stuntd

La première piste était stuntd (proxy qui distille des décisions typées dans de petites têtes sur un
encodeur Laya figé). Abandonnée à la demande de l'utilisateur au profit de llama.cpp. Notes de
l'évaluation partielle : une tête stuntd a un **jeu d'étiquettes fixe** (les « options dynamiques »
sont dans sa feuille de route), donc « quel texte copié coller » n'y rentre pas tel quel ; il faut
PyTorch (~1 Go installé, CPU seulement ici : pas de CUDA sur une carte AMD) ; ses têtes s'entraînent sur
≥ 300-3000 exemples étiquetés. llama.cpp + Vulkan utilise la carte AMD et accepte des options variables.

## Plus tard : décisions en jeu (< 60-100 ms)

Le même `llama-server` sait déjà répondre à n'importe quelle question fermée : `POST /decide` (ou
`SuggestClient.decide(question, options, contexte)` → signal `decided(id, réponse, confiance)`).
Mesuré : ~55 ms par décision sur GPU quand le préfixe est en cache (≤ ~40 tokens nouveaux), ~300 ms sur CPU.

Pour que ce soit utile et rapide :
- Garder une **consigne fixe + des exemples** (préfixe mis en cache dans un slot dédié) et ne mettre à la
  fin que l'état qui change, en quelques mots (« faim: haute, énergie: basse, heure: 13h, jouet: balle »).
- Des **options courtes et distinctes dès le premier token** (un seul token décodé suffit).
- Utiliser `confidence` : sous un seuil, garder la règle par défaut du jeu.
- Pour les réflexes image par image (marcher, sauter, éviter une fenêtre), garder du code/IA utilitaire :
  60 ms par décision ne tient pas à 30 images/s, et un modèle de 1 Md de paramètres raisonne mal sur des
  nombres. Le modèle convient aux choix « d'humeur » occasionnels (quelle réaction, quel jouet, quoi dire).
- Le texte seul ne suffit pas pour « voir » le bureau ou le jeu : il faut lui donner l'**état du jeu sérialisé**
  (variables), ou un modèle de **vision** (plus gros, plus lent : hors de ce budget de 60 ms).
- Pour descendre sous ~20 ms : journaliser les décisions du modèle puis entraîner un petit classifieur
  (distillation, l'idée de stuntd) ou une table de règles à partir de ces journaux.

## Fichiers

| fichier | rôle |
| --- | --- |
| `service.py` | service HTTP local (focus, suggest, decide), gère llama-server |
| `pompom_assist/focus_probe.py` | lecture du champ focus (UI Automation via comtypes) |
| `pompom_assist/rules.py` | regex des textes copiés, mots-clés des champs, libellés FR |
| `pompom_assist/decider.py` | décision hybride règles + modèle, interface `Decider` |
| `pompom_assist/llm.py` | lancement de llama-server (Job Object, clé, slots), questions à choix contraintes |
| `bench.py`, `data/` | jeu synthétique (`gen_synthetic.py`), mesures, résultats |
| `tests/` | tests unitaires, test de bout en bout du service |
| `setup.ps1` | installation (venv, llama.cpp, modèles) |
| `../godot/scripts/assistant/suggest_client.gd` | client Godot (`SuggestClient`) + instructions de câblage |
| `../godot/tests/suggest_test.tscn` | test de bout en bout côté Godot |

## Licences

llama.cpp : MIT. Qwen2.5-0.5B-Instruct : Apache-2.0. Llama-3.2-1B-Instruct : *Llama 3.2 Community
License* — usage commercial et redistribution permis, à condition de joindre la licence, d'afficher
« Built with Llama », de respecter la politique d'usage acceptable de Meta (et < 700 M utilisateurs
mensuels). Pour une distribution sans ces obligations : `setup.ps1 -Light` (Qwen2.5-0.5B, un peu moins
précis : 0,914). comtypes : MIT.
