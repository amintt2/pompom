# Assistant local de Pompom (suggestions de collage + vision)

Deux fonctions, un seul service local (`service.py`, 127.0.0.1, jeton secret), toutes deux **dÃ©sactivÃ©es
par dÃ©faut** :

1. **Suggestions de collage** (`suggestions`) : quand tu cliques dans un champ de saisie n'importe oÃ¹ dans
   Windows (email, adresse, recherche, message, Ã©diteur de codeâ€¦), Pompom regarde **la description** du
   champ et te propose le texte copiÃ© qui va bien : bulle Â« Coller ton email ? Â».
2. **Vision** (`vision`) : il devine ce que tu fais (jeu, vidÃ©o, code, documents, web, discussion, autre),
   avec des probabilitÃ©s, et **oÃ¹** se trouve la vidÃ©o Ã  l'Ã©cran.

Tout tourne sur ton PC : aucune connexion Internet aprÃ¨s l'installation, aucun service en ligne, aucune
tÃ©lÃ©mÃ©trie, et **aucun modÃ¨le qui gÃ©nÃ¨re du texte** : uniquement des modÃ¨les qui **choisissent** parmi des
rÃ©ponses fixÃ©es Ã  l'avance.

```
 Godot                                   assistant/service.py  (127.0.0.1, jeton, 1 processus)
 â”€â”€â”€â”€â”€                                   â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
 SuggestClient â”€â”€ GET /focus â—„â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ FocusWatcher : UI Automation (description du champ, jamais son contenu)
               â”€â”€ POST /suggest â”€â”€â”€â”€â”€â”€â”€â–º Decider : 1. rÃ¨gles/regex (< 1 ms)
                                                   2. si ambigu : stuntd = encodeur Laya figÃ© + tÃªte entraÃ®nÃ©e
               â”€â”€ POST /decide â”€â”€â”€â”€â”€â”€â”€â”€â–º choix zÃ©ro-shot Laya (dÃ©cisions de jeu)
 VisionClient  â”€â”€ GET /vision â—„â”€â”€â”€â”€â”€â”€â”€â”€â”€ VisionWatcher : capture Ã©cran en mÃ©moire (mss)
                                           carte de mouvement 96Ã—54 + encodeur d'images SigLIP (ONNX)
```

## stuntd et Laya, en deux mots

- **Laya** (`convaiinnovations/laya`, Apache-2.0) est un modÃ¨le de *dÃ©cision* : un encodeur de texte
  (type BERT) suivi d'une petite tÃªte qui note des options. On lui donne un Ã©tat (texte) et une question
  typÃ©e (`choice` = une option parmi N, `noul` = oui/non, `score` = une note) ; il renvoie une
  probabilitÃ© par option en **une seule passe**, sans rien gÃ©nÃ©rer. Nous utilisons le checkpoint
  *multilingual* (mmBERT-base, 322 M paramÃ¨tres, 644 Mo, 100+ langues : nos champs sont en franÃ§ais et en
  anglais).
- **stuntd** (`bladedevoff/stuntd` 0.1.3, Apache-2.0) entraÃ®ne, pour chaque Â« site de dÃ©cision Â», une
  petite **tÃªte de classification** (2 couches + un scoreur, 30 Mo) sur l'encodeur Laya **figÃ©**, Ã  partir
  de lignes Ã©tiquetÃ©es, puis la sert. Normalement il apprend en observant un fournisseur (LLM/Jev) ; ici
  **il n'y a aucun professeur** : nos lignes sont Ã©tiquetÃ©es par un gÃ©nÃ©rateur synthÃ©tique
  (`data/gen_train.py`), importÃ©es avec `stuntd import`, et `stuntd train` ajuste les tÃªtes, hors ligne,
  sur le CPU (`train_heads.py`).
- stuntd fixe aussi, Ã  l'entraÃ®nement, un **seuil d'exploitation** par tÃªte (la certitude Ã  partir de
  laquelle la tÃªte est d'accord Ã  99 % avec ses Ã©tiquettes sur des lignes mises de cÃ´tÃ©). En mode hybride,
  une tÃªte sous son seuil laisse la main aux rÃ¨gles.
- Le service n'utilise ni le dÃ©mon `stuntd serve` ni PyTorch : aprÃ¨s l'entraÃ®nement, `export_onnx.py` exporte
  l'encodeur et chaque tÃªte en ONNX, et `laya_onnx.py` reconstruit exactement les mÃªmes sÃ©quences que
  laya/stuntd (vÃ©rifiÃ© : mÃªmes jetons, mÃªmes probabilitÃ©s Ã  0,0000 prÃ¨s en fp32).

Sites de dÃ©cision :

| site | entrÃ©e | sortie |
| --- | --- | --- |
| `field_kind` | description du champ (appli, titre de fenÃªtre, nom, id, aideâ€¦) | email, phone, address, url, search, name, code, chat_message, username, number, date, other |
| `text_kind` | sorte + description + types des textes copiÃ©s prÃ©sents | email, phone, url, address, number, date, code, name, username, text, none (types absents masquÃ©s) |
| `decide()` (jeu) | question + contexte | une des options donnÃ©es (zÃ©ro-shot, tÃªte d'origine de Laya, sans entraÃ®nement) |

Pas de site `noul` Â« faut-il suggÃ©rer ? Â» : `text_kind` sait dÃ©jÃ  rÃ©pondre `none`, et la probabilitÃ©
renvoyÃ©e sert de seuil cÃ´tÃ© Godot (`min_confidence`).

## Encodeur au choix : EmbeddingGemma 2 (évaluation du 7 octobre 2026)

`docs/eval_embeddinggemma2.md` compare la pile actuelle à EmbeddingGemma 2 sur de nouveaux jeux de test plus
réalistes (`data/eval_v2/`, `tests/eval_v2.py`). Recommandation : le mode hybride **`ASSIST_BACKEND=gemma2-text`**
(texte EmbeddingGemma 2, vision SigLIP avec tête entraînée). Le défaut (`laya`) ne change pas, et l'API HTTP
reste la même. Les champs secrets non marqués (codes SMS, PIN, carte, clés…) ne reçoivent plus jamais de
suggestion (`rules.is_secret_field`).

## Installation

```powershell
powershell -ExecutionPolicy Bypass -File assistant\setup.ps1        # joueurs : SANS PyTorch
powershell -ExecutionPolicy Bypass -File assistant\setup.ps1 -Dev   # dÃ©veloppeurs : fabrique models\
```

- **ExÃ©cution** (`.venv`, ~170 Mo) : Python 3.11 + `onnxruntime-directml`, `numpy`, `tokenizers`, `pillow`,
  `mss`, `comtypes`. **Pas de PyTorch, ni transformers, ni laya, ni stuntd** : le service lit des graphes
  ONNX dans `models\` (~690 Mo), livrÃ©s avec le jeu ou fabriquÃ©s par `-Dev`.
- **DÃ©veloppement** (`dev\`, ~2,3 Go, jamais livrÃ©) : PyTorch CPU + torch-directml, stuntd[train], laya,
  le checkpoint Laya multilingual, SigLIP ; `train_heads.py` entraÃ®ne les tÃªtes, `export_onnx.py` exporte.

RÃ©glages du jeu : `suggestions` et `vision` (tous deux **dÃ©sactivÃ©s par dÃ©faut**), `ai_gpu` (vrai par dÃ©faut :
la vision tourne sur la carte graphique via DirectML ; le texte tourne toujours sur le processeur, voir plus bas).

## Vie privÃ©e

- Service sur `127.0.0.1` uniquement, jeton alÃ©atoire obligatoire (`X-Pompom-Token`), refus de toute requÃªte
  avec en-tÃªte `Origin` (pages web) ou `Host` inattendu (DNS rebinding). Aucune connexion sortante
  (onnxruntime et tokenizers lisent des fichiers locaux ; aucune bibliothÃ¨que Hugging Face Ã  l'exÃ©cution).
- Suggestions : on ne lit **jamais** la valeur d'un champ, seulement sa description ; champs **mot de passe**
  ignorÃ©s entiÃ¨rement ; fenÃªtres du jeu ignorÃ©es.
- Vision : captures d'Ã©cran **en mÃ©moire uniquement**, jamais Ã©crites ni envoyÃ©es, et **seulement** quand le
  rÃ©glage `vision` est actif. On ne garde que 5 vignettes 96Ã—54 en niveaux de gris (carte de mouvement) et la
  derniÃ¨re capture le temps de l'analyse. Couper le rÃ©glage arrÃªte le fil de capture et libÃ¨re tout.
- **Pause totale** (ni capture ni calcul) quand un jeu compÃ©titif ou un jeu plein Ã©cran a le focus (le jeu le
  signale via `Activity`), et automatiquement pour toute appli plein Ã©cran qui n'est ni un navigateur ni un
  lecteur vidÃ©o. Une intÃ©gration de jeu peut demander une image ponctuelle (`VisionClient.request_frame()`).
- Si le jeu est tuÃ© brutalement, le service s'arrÃªte (il surveille le jeu ET son lanceur Python).

## API du service

| requÃªte | rÃ©ponse |
| --- | --- |
| `GET /health` (sans jeton) | `{ok, heads: loading/ready/unloaded/error, backend, model, mode}` |
| `GET /focus?after=SEQ&wait=10` | champ focus ; attend jusqu'Ã  10 s qu'il change |
| `POST /suggest {candidates:[...], field?}` | `{kind, index, confidence, label_fr, kind_source, pick_source, ms, model_ms}` |
| `POST /decide {question, options:[...], context?}` | `{answer, confidence, probs, ms}` (choix zÃ©ro-shot Laya) |
| `GET /vision` | `{enabled, ready, probs:{game, video, work_code, work_docs, browse, chat, other}, top, video_rect:[x,y,w,h] ou null, fullscreen, is_watching_video, is_fullscreen_game, paused, screen, ms, ts}` |
| `POST /vision/enable {on}`, `/vision/pause {paused}`, `/vision/frame` | activer / pause / une analyse immÃ©diate |
| `POST /shutdown` | arrÃªte le service |

## Comment Ã§a dÃ©cide (suggestions)

1. **RÃ¨gles** (`rules.py`, < 1 ms) : type de chaque texte copiÃ© par regex ; sorte du champ par mots-clÃ©s FR/EN.
   Un seul mot-clÃ© = sÃ»r. Plusieurs ou aucun = ambigu.
2. **TÃªtes stuntd** seulement si c'est ambigu (â‰ˆ 23 % des cas du jeu test) : `field_kind` sur la description
   du champ ; `text_kind` quand plusieurs **types** de textes copiÃ©s conviennent autant (une recherche : une
   phrase ou une adresse ?). La tÃªte ne rÃ©pond que si sa certitude dÃ©passe le seuil fixÃ© par stuntd Ã 
   l'entraÃ®nement ; sinon les rÃ¨gles gardent la main.
3. Le libellÃ© franÃ§ais vient de modÃ¨les de phrases (Â« Coller ton email ? Â»).

## Mesures (i5-10400F, 32 Go, RX 6650 XT, Windows 11)

### PrÃ©cision â€” jeu test synthÃ©tique (360 cas, vocabulaire disjoint de l'entraÃ®nement)

EntraÃ®nement : `data/gen_train.py` (6 000 scÃ©narios â†’ 3 524 lignes uniques `field_kind`, 5 825 `text_kind`),
`stuntd train` 24 Ã©poques sur CPU (~2 h 20 au total, machine partagÃ©e). Rapport stuntd sur ses lignes mises
de cÃ´tÃ© : `field_kind` accord 0,929, couverture 0,81 Ã  99,1 % d'accord (seuil 0,81) ; `text_kind` accord
0,981, couverture 0,97 Ã  99,0 % (seuil 0,76).

| dÃ©cideur | sorte + texte justes | latence d'une suggestion | appels au modÃ¨le |
| --- | --- | --- | --- |
| rÃ¨gles seules | 0,892 | 0,24 ms | 0 |
| **rÃ¨gles + tÃªtes stuntd (hybride), ONNX livrÃ©** | **0,939** | p50 0,35 ms, p95 107 ms | 23 % (â‰ˆ 100 ms chacun) |
| rÃ¨gles + tÃªtes stuntd (hybride), PyTorch (rÃ©fÃ©rence) | 0,939 | p50 0,38 ms, p95 111 ms | 23 % |
| tÃªtes stuntd pour tout, ONNX | 0,761 | p50 217 ms | 100 % |
| tÃªtes stuntd pour tout, PyTorch | 0,783 | p50 238 ms | 100 % |

Pour mÃ©moire, la version prÃ©cÃ©dente avec un LLM gÃ©nÃ©ratif (Llama-3.2-1B) atteignait 0,978 ; elle a Ã©tÃ©
abandonnÃ©e Ã  la demande de l'utilisateur. Les tÃªtes de choix, entraÃ®nÃ©es sur un vocabulaire disjoint du test,
gÃ©nÃ©ralisent moins bien aux libellÃ©s jamais vus : d'oÃ¹ le mode hybride, oÃ¹ elles ne parlent que quand elles
sont sÃ»res.

### AllÃ¨gement (export ONNX, sans PyTorch)

| format de l'encodeur Laya (322 M paramÃ¨tres dont 197 M d'embeddings) | taille | hybride | tÃªtes seules |
| --- | --- | --- | --- |
| fp32 | 1 171 Mo | 0,939 (identique Ã  PyTorch) | 0,783 |
| int8 dynamique, tout | 294 Mo | 0,861 | 0,111 |
| int8 par canal, poids seulement | 294 Mo | 0,892 (= rÃ¨gles : les tÃªtes ne sont plus sÃ»res) | â€” |
| int8 sur les embeddings seulement | 609 Mo | 0,939 | â€” |
| **Â« mixed Â» livrÃ© : embeddings int8 + reste fp16** | **399 Mo** | **0,939** | 0,761 |

mmBERT/ModernBERT ne supporte pas la quantification int8 de ses matrices (valeurs aberrantes dans les
activations) : seul l'embedding se quantifie sans perte. TÃªtes stuntd : fp16, 28 Mo chacune.
Vision SigLIP : l'int8 donne un cosinus de 0,90â€“0,97 avec le fp32 et plante sous DirectML ; on livre le fp16
(178 Mo), identique au fp32 sous DirectML.

### CoÃ»t Ã  l'exÃ©cution (service rÃ©el, `tests/bench_service.py`)

| | mesure |
| --- | --- |
| service HTTP prÃªt (rÃ¨gles disponibles) | 1,5 s |
| modÃ¨le de texte prÃªt (chargement en arriÃ¨re-plan) | 4,7â€“4,9 s |
| `/suggest` via HTTP, tout le jeu test | p50 1,9 ms, p95 104 ms |
| `/suggest` qui rÃ©veille une tÃªte (CPU) | p50 97 ms, p95 108â€“123 ms |
| `/decide` (zÃ©ro-shot, 3 options, CPU) | 70â€“250 ms (le 1er appel charge la tÃªte Â« base Â») |
| RAM : rÃ¨gles seules / aprÃ¨s dÃ©chargement du texte | ~100 Mo / 73â€“124 Mo |
| RAM : modÃ¨le de texte chargÃ© | **~850 Mo** (CPU) |
| vision DirectML, 1 passe / 3 s | 43 ms/passe, **0,4 % CPU** (tous cÅ“urs ; 4,8 % d'un cÅ“ur), VRAM 204 Mo, RAM ~190 Mo |
| vision CPU, 1 passe / 3 s | 290 ms/passe, **1,9 % CPU** (23 % d'un cÅ“ur), RAM ~190 Mo |
| texte sur DirectML (essayÃ©) | plus lent (220 ms, recompilation Ã  chaque longueur) et moins prÃ©cis (0,911) : non retenu |

Intervalle conseillÃ© pour la vision : **3 s** (1 capture/s pour la carte de mouvement, 1 passe d'encodeur
toutes les 3 s) ; 5 s sans carte graphique. Le modÃ¨le de texte se dÃ©charge aprÃ¨s 5 min sans champ ambigu
(`--idle-unload 300`) et se recharge Ã  la demande (~5 s ; les rÃ¨gles rÃ©pondent pendant ce temps).

### Empreinte, honnÃªtement

| | disque | RAM |
| --- | --- | --- |
| `.venv` (exÃ©cution) | 170 Mo | |
| `models\` : Laya Â« mixed Â» 399 + 3 tÃªtes 85 + tokenizer 33 + SigLIP fp16 178 | 694 Mo | |
| Python 3.11 (installÃ© Ã  part) | 148 Mo | |
| **total installation joueur** | **~860 Mo** (+148 Mo de Python) | 73â€“124 Mo au repos, ~300 Mo avec la vision, **~850 Mo** tant que le texte est chargÃ© |

L'objectif < 600 Mo disque / < 400 Mo RAM **n'est pas atteint pour le texte**, pour une raison mesurÃ©e :
l'encodeur Laya multilingual a 125 M de poids qui ne supportent pas l'int8 (voir tableau), donc au minimum
~250 Mo en fp16 sur disque et ~500 Mo en fp32 une fois chargÃ©s sur CPU, plus une table de 256 000 jetons.
Ce qui limite le coÃ»t : chargement Ã  la demande, dÃ©chargement aprÃ¨s 5 min, tÃªte Â« base Â» chargÃ©e seulement si
`decide()` est appelÃ©, vision et texte indÃ©pendants (chacun ne tourne que si son rÃ©glage est actif).
Pistes : publier `models\` en tÃ©lÃ©chargement sÃ©parÃ© (le jeu marche sans : rÃ¨gles seules, 0,892) ; Ã©laguer le
vocabulaire (il faut un corpus FR/EN reprÃ©sentatif) ; une tÃªte stuntd sur un encodeur plus petit.

## Vision : ce que c'est, ce que Ã§a vaut

- **ModÃ¨le** : SigLIP base patch16-224 (Google, **Apache-2.0**), tour de vision seule en ONNX fp16 (export
  Xenova). Les phrases de chaque classe (Â« a screenshot of a code editorâ€¦ Â») sont encodÃ©es une fois par
  `export_onnx.py` avec la tour de texte, qui n'est pas livrÃ©e.
- **ActivitÃ©** : choix zÃ©ro-shot entre 7 classes (moyenne des phrases de chaque classe, softmax, tempÃ©rature 2),
  combinÃ© Ã  un lÃ©ger a priori du processus au premier plan (code.exe â†’ code, discord â†’ discussionâ€¦) ; un Â« jeu Â»
  ni plein Ã©cran ni lancÃ© par un lanceur connu est pÃ©nalisÃ© ; puis lissage exponentiel (EMA 0,35).
  **Les probabilitÃ©s ne sont pas calibrÃ©es** sur de vraies captures (il faudrait des Ã©crans Ã©tiquetÃ©s : avec
  quelques centaines, une tÃªte stuntd-like sur les vecteurs SigLIP serait la suite logique).
  Sonde synthÃ©tique (`tests/vision_synth.py`, Ã©crans dessinÃ©s grossiÃ¨rement + photos) : 6/8.
- **OÃ¹ est la vidÃ©o** : 1 capture/s rÃ©duite Ã  96Ã—54 ; une zone qui change dans 3 des 4 derniÃ¨res paires
  d'images (trous bouchÃ©s, plus grande composante connexe, â‰¥ 1,2 % de l'Ã©cran) est recadrÃ©e en pleine
  rÃ©solution et confirmÃ©e par l'encodeur (Â« image filmÃ©e Â» contre Â« capture d'interface Â»). Test Godot :
  fenÃªtre animÃ©e 800Ã—450 retrouvÃ©e avec IoU 0,85, score Â« vidÃ©o Â» 0,97. Plein Ã©cran : rectangle = Ã©cran entier.
- **nnlgsakib/laya-vision** (Laya + SigLIP2, Apache-2.0) a Ã©tÃ© essayÃ© d'abord comme demandÃ© : pas de chargeur
  publiÃ©, j'en ai reconstruit un d'aprÃ¨s les poidsâ€¦ et **99,9 % des poids publiÃ©s sont NaN** (414 tenseurs sur
  419) : le checkpoint est inutilisable, toute rÃ©ponse vaut NaN. SupprimÃ©.

## Tests

```powershell
cd assistant
.venv\Scripts\python.exe -m unittest discover -s tests -v                 # rÃ¨gles, vision (20 tests)
$env:POMPOM_TEST_HEADS="1"; .venv\Scripts\python.exe -m unittest discover -s tests -v   # + tÃªtes ONNX
.venv\Scripts\python.exe tests\smoke_service.py [--cpu] [--no-vision]      # service HTTP de bout en bout
.venv\Scripts\python.exe bench.py --split test --heads --cpu              # prÃ©cision + latence
dev\.venv\Scripts\python.exe tests\parity_onnx.py                          # ONNX == PyTorch
dev\.venv\Scripts\python.exe tests\bench_service.py [--cpu]                # CPU / RAM / VRAM rÃ©els
..\tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path ..\godot res://tests/suggest_test.tscn
..\tools\godot\Godot_v4.7.2-stable_win64_console.exe --path ..\godot res://tests/vision_test.tscn   # vraie fenÃªtre
```

## Plus tard : dÃ©cisions en jeu (< 60â€“100 ms)

Le mÃªme mÃ©canisme sert aux choix du compagnon :
- **ZÃ©ro-shot tout de suite** : `SuggestClient.decide(question, options, contexte)` â†’ `decided(id, rÃ©ponse,
  confiance)`. ~70â€“100 ms sur CPU une fois chargÃ©, rien Ã  entraÃ®ner, mais Laya zÃ©ro-shot est approximatif.
- **Rapide et fiable** : comme ici, Ã©crire un gÃ©nÃ©rateur (ou journaliser les choix du jeu), `stuntd import`
  puis `stuntd train` une tÃªte par dÃ©cision (`pet_action`, `reaction`â€¦), et l'ajouter Ã  `export_onnx.py`.
  Une passe â‰ˆ 100 ms sur CPU avec ce Laya : pour descendre sous 60 ms, il faut des entrÃ©es courtes (l'Ã©tat du
  jeu rÃ©sumÃ© en quelques mots) ou un encodeur plus petit.
- Les tÃªtes lisent du **texte** : il faut leur donner l'Ã©tat du jeu sÃ©rialisÃ© (Â« faim : haute, Ã©nergie : basse,
  heure : 13 h Â»). Pour Â« voir Â» l'Ã©cran, c'est la vision ci-dessus (SigLIP) qui fournit `top`, `probs` et
  `video_rect`, qu'on peut Ã  leur tour mettre dans l'Ã©tat texte. Les rÃ©flexes image par image (marcher,
  sauter) restent du code classique.

## Fichiers

| fichier | rÃ´le |
| --- | --- |
| `service.py` | service HTTP local : focus, suggest, decide, vision |
| `pompom_assist/rules.py` | regex des textes copiÃ©s, mots-clÃ©s des champs, libellÃ©s FR |
| `pompom_assist/decider.py` | dÃ©cision hybride rÃ¨gles + tÃªtes (interface `Decider`) |
| `pompom_assist/laya_onnx.py` | Laya + tÃªtes stuntd en ONNX, sans PyTorch |
| `pompom_assist/heads.py` | description des champs ; `OnnxHeads` (exÃ©cution) ; `StuntdHeads` (dev, PyTorch) |
| `pompom_assist/vision.py` | capture, carte de mouvement, SigLIP, pause plein Ã©cran |
| `pompom_assist/focus_probe.py` | champ focus via UI Automation |
| `data/gen_synthetic.py`, `data/gen_train.py` | jeux dev/test et jeu d'entraÃ®nement des tÃªtes |
| `train_heads.py`, `export_onnx.py` | (dev) entraÃ®nement stuntd hors ligne, export ONNX |
| `bench.py`, `tests/` | mesures et tests |
| `../godot/scripts/assistant/suggest_client.gd` | `SuggestClient` : lance le service, suggestions, `decide()` |
| `../godot/scripts/assistant/vision_client.gd` | `VisionClient` : signal `vision_changed(top, probs, video_rect, fullscreen)` |

## Licences

stuntd 0.1.3 : Apache-2.0. Laya (`convaiinnovations/laya`, checkpoint multilingual) : Apache-2.0. SigLIP base
(`google/siglip-base-patch16-224`, export ONNX `Xenova/siglip-base-patch16-224`) : Apache-2.0. ONNX Runtime :
MIT. tokenizers : Apache-2.0. mss : MIT. Pillow : MIT-CMU. comtypes : MIT. Tout est compatible avec un projet
MIT (garder les mentions de licence Apache-2.0 des modÃ¨les dans la distribution). Non utilisÃ© :
`thaitea/laya-vision` (CC BY-NC-SA, non commercial).
