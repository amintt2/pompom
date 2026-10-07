# EmbeddingGemma 2 contre la pile actuelle (Laya + stuntd, SigLIP)

*Mesuré le 7 octobre 2026 sur le PC de jeu (i5-10400F 6 cœurs / 12 fils, 32 Go, RX 6650 XT, Windows 11).
Calculs lourds sur le CPU en priorité basse, 4 fils, un seul gros processus à la fois. DirectML seulement pour
de courtes mesures de latence. Tout est reproductible avec `.venv\Scripts\python.exe tests\eval_v2.py`
(voir « Fichiers »). Les tableaux viennent de `data/eval_v2/results/*.json` (`tests/eval_v2_report.py`).*

## En bref : recommandation

**Adopter un mode hybride : EmbeddingGemma 2 pour le texte, SigLIP (avec une tête entraînée) pour la vision.**
Ce mode est prêt derrière `ASSIST_BACKEND=gemma2-text`. Le défaut ne change pas.

| | pile actuelle | **hybride recommandé** (`gemma2-text`) | tout Gemma 2 (`gemma2`) |
| --- | --- | --- | --- |
| suggestions : bonne suggestion / bout en bout (1 850 champs inédits) | 0,786 / 0,687 | **0,829 / 0,753** | 0,829 / 0,753 |
| sorte de champ juste | 0,779 | **0,863** | 0,863 |
| secrets jamais proposés (160 champs) | 0,988 (2 fuites) | **1,000 (0 fuite)** | 1,000 |
| appel au modèle de texte (CPU, p50) | 108 ms | 136 ms | 136 ms |
| RAM du modèle de texte chargé | 810 Mo | **347 Mo** | 347 Mo (partagé avec la vision) |
| activité à l'écran, chaîne du service (360 écrans) | 0,536 (zéro-shot) | **0,897** (tête + fenêtre au premier plan) | 0,892 |
| … sur des mises en page jamais vues | 0,48 | 0,66 | **0,77** |
| vision : une passe sur DirectML / CPU | 54 / 206 ms | 54 / 206 ms | 192 / 1 040 ms |
| disque des modèles livrés | 694 Mo | **~495 Mo** | ~955 Mo |

Pourquoi ce choix :

- **Texte : EmbeddingGemma 2 gagne nettement.** Sur 1 850 champs jamais vus, le bout en bout passe de 0,687 à
  0,753 (+6,6 points, bien au-delà de l'incertitude de ±2,2 points). La sorte de champ passe de 0,779 à 0,863.
  La tête seule passe de 0,634 à 0,773. Le modèle chargé prend **2,3 fois moins de RAM**, et c'était le point
  faible du README (objectif < 400 Mo). Il sait aussi reconnaître un champ secret par le sens (« Passwort »,
  « Senha », « Code de déverrouillage ») : 0 fuite. Le prix : +28 ms par appel au modèle (136 contre 108 ms),
  et seulement dans 35 % des cas.
- **Vision : le gros gain vient de la tête entraînée, pas de l'encodeur.** Une petite tête apprise sur des
  écrans fait passer SigLIP de 0,54 à 0,90 dans la chaîne du service. Gemma 2 fait jeu égal dans la chaîne
  (0,892) et un peu mieux sur l'image seule (0,947 contre 0,922). Il généralise mieux aux mises en page inédites
  (0,77 contre 0,66). Mais il est **3,6 fois plus lent sur DirectML** (192 contre 54 ms) et 5 fois sur CPU
  (1,04 s contre 0,21 s). Il pèse aussi +640 Mo sur le disque et ~1 Go de RAM sur CPU. Pour le moment, ce n'est
  pas rentable. Il faudra revoir la question avec de vraies captures (`--real-vision`).
- **Bloquant levé en route :** la pile actuelle **proposait un texte dans 19 champs secrets sur 160** (codes SMS,
  CVC, « 6-digit code »…). Une garde par mots-clés (`rules.is_secret_field`, écrite avant l'eval) le corrige pour
  les deux piles. Elle est active par défaut et ne change rien à l'ancien jeu test (0,939 / 0,892 / 0,761).

## 1. D'abord : des tests plus gros et plus réalistes (`data/eval_v2/`)

L'ancien jeu test (360 cas) ne contenait que **36 champs différents**. La pile actuelle y faisait 0,939, ce qui
ne disait presque rien de son comportement sur des champs jamais vus. `data/eval_v2/README.md` détaille la
construction des jeux. En résumé :

| jeu | taille | contenu |
| --- | --- | --- |
| **texte** `text.jsonl` | **1 850 cas = 1 850 champs différents** | FR 1 124 / EN 619 / mélangé 85 / autres langues 22. Descriptions comme les renvoie UI Automation : label, placeholder, id HTML parfois sans aucun sens (`:r4:`), rôle ARIA, `required=true`… Plus de 30 applis de bureau et plus de 100 sites jamais vus. 205 libellés bruités (fautes, MAJUSCULES, emoji). 185 cas adverses : « Code promo », « Nom de la rue », « Ville de naissance », « Email ou numéro de mobile », recherche de personnes, `.py` ouvert dans le Bloc-notes… **160 champs secrets** où la seule bonne réponse est « rien » : mot de passe non marqué, code SMS, PIN, CVC, clé d'API, phrase de récupération, Passwort, Contraseña, Senha… Le script **vérifie** que le vocabulaire est disjoint de l'entraînement : il refuse d'écrire le jeu en cas de fuite. |
| **vision** `vision/` | **360 écrans 2560×1440**, 5 captures à 1 s chacun | Navigateur avec page vidéo (normale, mode cinéma, plein écran, image dans l'image), éditeur de code clair ou sombre, terminal, traitement de texte, tableur, diapos, PDF, Discord / Slack / WhatsApp, boîte mail, explorateur, réglages, bureau. Jeux procéduraux : FPS, TPS, plateforme, stratégie, course. Plusieurs fenêtres, écran partagé, thèmes, mise à l'échelle de 100 à 150 %. 93 vidéos : 62 qui bougent, 18 immobiles (diapos, pause), 13 « personne qui parle ». Distracteurs : défilement, publicité animée, jeux fenêtrés, curseur. **65 écrans dans des mises en page jamais vues** à l'entraînement. 61 Mo en JPEG, régénérables à l'identique. Tout est dessiné par `data/gen_screens.py` : aucune capture n'est copiée. |

Les têtes ne voient **jamais** ces jeux. Elles sont choisies sur l'ancien `data/test.jsonl` et calibrées sur
20 % mis de côté de leur entraînement, comme stuntd. Les têtes de vision s'entraînent sur 360 autres écrans
(`--split train`, autres graines).

## 2. EmbeddingGemma 2 : téléchargement, adaptation, export

- **Modèle** : `google/embeddinggemma-2`, révision `914f7f89142e33e77833254d9c9b90c3cef7303b`,
  `model.safetensors` 1 488 915 288 octets, sha256 `197a3296…5553d79` (vérifié contre le X-Linked-ETag de Hugging
  Face). **Non restreint** (`gated: false`) : aucune licence à accepter, aucune connexion. Licence **Apache-2.0**,
  indiquée dans l'en-tête du README (pas de fichier LICENSE dans le dépôt). Le README renvoie aussi à la
  politique d'usage interdit de Gemma. Tout est recopié dans `models/gemma2/LICENSE-NOTICE.txt`. Source et
  hash : `dev/embeddinggemma2/SOURCE.json`.
- **Variante texte + image (440 M)** : chargée avec `audio_config = None`. Architecture vérifiée : backbone de
  24 couches **bidirectionnelles** de largeur 512, embeddings par couche « PLE », projection vers 768, moyenne.
  La tour de vision Gemma 4 (16 couches, carrés de 16 px regroupés par 3×3) produit des « jetons doux ». Ces
  jetons repassent par le backbone de texte, encadrés par `[BOS, <|image>, …, <image|>, EOS]`. L'audio n'a pas
  été testé : il ne sert à rien ici.
- **stuntd ne peut pas utiliser cet encodeur.** Son entraîneur (`stuntd/train/trainer.py`) instancie
  `laya.Agent(base_model)`. Il lui faut donc un checkpoint Laya complet : encodeur + tête de décision Laya
  pré-entraînée, marqueurs `[MASK]`, mise en page propre à ModernBERT. Il faudrait aussi transformers 5 / torch 2.14
  dans l'environnement où tournent laya et stuntd. J'ai donc écrit de **petites têtes moi-même** (PyTorch côté
  dev, exportées en numpy) sur l'encodeur **figé**, avec **la même calibration que stuntd** : température
  ajustée, puis seuil de certitude (1 − entropie normalisée) au point de **99 % d'accord** sur 20 % mis de côté.
  Le mode hybride est inchangé : les règles répondent quand la tête n'est pas sûre.
- **Têtes texte** (mêmes données que les têtes stuntd : `data/train_field_kind.jsonl` et
  `data/train_text_kind.jsonl`). J'ai comparé trois variantes : MLP sur le vecteur 768, MLP sur Matryoshka 256
  et attention apprise sur les jetons. Le choix s'est fait sur l'ancien jeu test, en simulant le mode hybride.
  Retenues : `field_kind` = MLP-256 (validation hybride 0,978), `text_kind` = MLP-768. L'attention sur les
  jetons sur-apprend le vocabulaire d'entraînement (0,83 en validation).
- **Garde « secret » sémantique** (option, Gemma seulement) : une tête binaire entraînée sur 65 libellés secrets
  écrits à part, FR/EN seulement, **aucun identique à l'eval** (vérifié). Les négatifs sont les champs
  d'entraînement. Elle ne sert que si le modèle a déjà lu le champ (vecteur en cache, ~0 ms de plus). Résultat :
  0 faux positif sur l'ancien test, 0 sur les 1 690 champs non secrets de l'eval, et elle rattrape « Passwort »,
  « Senha », « Code de déverrouillage », « Clé de sécurité réseau ».
- **Têtes vision** : une tête d'activité par stratégie (moyenne des vecteurs des recadrages), plus une tête
  « vidéo dans la case » pour la grille 3×3. Les mêmes têtes ont été entraînées **aussi sur SigLIP**, par
  loyauté.
- **Ajustement des dernières couches : non fait.** Le gain venait déjà des têtes, et le CPU était le goulot
  (l'encodage seul des écrans d'entraînement a pris 1 h 50).
- **Export sans PyTorch** (`export_gemma_onnx.py`) :
  - texte : table d'embeddings en int8 par ligne (numpy, mémoire projetée, 128 Mo) + backbone ONNX ;
  - image : tour de vision ONNX (P carrés variables, vérifié sur plusieurs formats d'image).
  - **Quantification mesurée** (cosinus avec PyTorch fp32) :

    | format du backbone | disque | cosinus texte | cosinus image | texte CPU |
    | --- | --- | --- | --- | --- |
    | fp32 | 523 Mo | 0,99996 | 1,0000 | 84 ms |
    | int8 dynamique (comme Laya) | 134 Mo | **0,71** (cassé) | 0,85 | 77 ms |
    | 4 bits par blocs | 83 Mo | 0,976 | 0,987 | 110–122 ms |
    | **8 bits par blocs (MatMulNBits, livré)** | **148 Mo** | **0,9991** | **0,9998** | 135 ms |
    | fp16 | — | interdit par Google (dépassement → NaN) | | |

    Les valeurs aberrantes des activations (comme mmBERT) cassent l'int8 dynamique. Le 8 bits par blocs les
    garde locales. La tour de vision reste en fp32 (641 Mo) : le 8 bits y est plus lent sur CPU, et DirectML ne
    l'accélère pas.
  - **Parité vérifiée** (`models/gemma2/parity.json`) : tokenisation identique à transformers (40/40). Cosinus
    entre la chaîne livrée (ONNX + numpy) et le modèle PyTorch fp32 : ≥ 0,9991 pour le texte, ≥ 0,9998 pour les
    images (vraies captures eval + recadrages de formats variés). Les têtes tournent en numpy, avec le même code
    pour l'entraînement, l'éval et le service.

## 3. Résultats texte (1 850 champs, `tests/eval_v2.py --text`)

| configuration | sorte juste | **bonne suggestion** | bout en bout | secrets jamais proposés | p50 | p95 | appels au modèle |
| --- | --- | --- | --- | --- | --- | --- | --- |
| règles seules | 0,755 | 0,765 | 0,673 | 1,000 | 0,3 ms | 0,5 ms | 0 % |
| Laya hybride, **tel que livré** | 0,779 | 0,777 | 0,687 | **0,881 (19 fuites)** | 0,6 ms | 126 ms | 41 % |
| Laya hybride + garde mots-clés | 0,779 | 0,786 | 0,687 | 0,988 (2 fuites) | 0,7 ms | 120 ms | 35 % |
| Laya têtes seules + garde | 0,634 | 0,723 | 0,542 | 0,969 | 239 ms | 294 ms | 92 % |
| Gemma 2 hybride + garde mots-clés | 0,863 | 0,826 | 0,753 | 0,975 (4 fuites) | 0,6 ms | 133 ms | 35 % |
| **Gemma 2 hybride + garde mots-clés + garde sémantique** | **0,863** | **0,829** | **0,753** | **1,000 (0 fuite)** | 0,6 ms | 132 ms | 35 % |
| Gemma 2 têtes seules + gardes | 0,772 | 0,774 | 0,654 | 1,000 | 251 ms | 346 ms | 92 % |

*Bonne suggestion* : le texte proposé, ou « rien », est le bon, sur tout le jeu. *Bout en bout* : la sorte et le
texte sont justes, sur les 1 690 champs non secrets. Latences : le décideur complet en process ; la part utile est
« appels au modèle ».

**Têtes seules** (sans règles) :

| tête | précision | couverture au seuil (99 % sur l'entraînement) | précision quand sûre | ECE |
| --- | --- | --- | --- | --- |
| Laya `field_kind` | 0,634 | 0,567 | 0,808 | 0,155 |
| **Gemma 2 `field_kind`** | **0,773** | 0,951 | 0,801 | **0,102** |
| Laya `text_kind` | 0,837 | 0,932 | 0,861 | 0,115 |
| Gemma 2 `text_kind` | 0,839 | 0,215 | **0,955** | **0,038** |

Calibration : les deux seuils, fixés à 99 % d'accord sur des lignes d'entraînement, sont trop optimistes sur du
vocabulaire inédit (environ 80 % juste quand « sûr » pour `field_kind`). Le défaut est le même pour stuntd et
pour mes têtes. Gemma 2 est mieux calibré (ECE plus bas).

**Détail du bout en bout (hybride + garde)** : Gemma 2 fait mieux sur adresse (0,66 → 0,77), code
(0,28 → 0,49), nombre (0,69 → 0,77), téléphone (0,86 → 0,95), identifiant (0,74 → 0,90), recherche (0,64 → 0,72),
carte (0,30 → 0,43), applis de bureau (0,57 → 0,72), libellés bruités (0,70 → 0,80), anglais (0,69 → 0,77) et
français (0,68 → 0,74). Égalité sur date (0,72). **Gemma 2 fait moins bien** sur `other` (0,70 → 0,61) et sur les
**cas adverses** (0,74 → 0,63). Il « comprend » trop vite « Code promo » comme un champ d'adresse ou de nombre, et
« Instructions pour le livreur » comme une adresse. Une tête qui a appris les mots est plus prudente ; une tête qui
a appris le sens se laisse piéger par les sens voisins. Ces cas sont rares en vrai, mais ils sont visibles.

Plafond commun : le typage des textes copiés par regex (`rules.content_type`) est partagé. `git commit -m …`,
`docker run …` ou « 1600 Amphitheatre Parkway » ne sont pas reconnus comme code ou adresse. C'est la principale
cause d'erreur restante pour la sorte `code`, avec les deux piles.

**Latence** (`--latency`, 200 descriptions, chaque pile seule, même moment) :

| appel de tête | CPU p50 / p95 | DirectML p50 / p95 |
| --- | --- | --- |
| Laya (mixed int8/fp16) | 108 / 122 ms | 149 / 325 ms |
| Gemma 2 (backbone 8 bits) | 136 / 166 ms | 405 / 439 ms |
| Gemma 2 (backbone fp32, non livré : +375 Mo) | ~84 ms (mesure isolée) | — |

Le texte reste sur CPU (DirectML recompile à chaque longueur, et ne gère pas MatMulNBits).

## 4. Résultats vision (360 écrans, `tests/eval_v2.py --vision`)

### Activité, image seule : quelle partie de l'écran analyser ?

Précision sur les 7 classes. Le temps couvre l'encodage de tous les recadrages d'une stratégie (p50 sur
10 écrans).

| stratégie | SigLIP zéro-shot | **SigLIP + tête** | Gemma 2 zéro-shot | **Gemma 2 + tête** | SigLIP CPU / DirectML | Gemma 2 CPU / DirectML |
| --- | --- | --- | --- | --- | --- | --- |
| plein écran (actuel) | 0,500 | 0,875 | 0,597 | 0,897 | 206 / 54 ms | 1 040 / 192 ms |
| **plein écran + fenêtre au premier plan** | 0,533 | **0,922** | 0,625 | **0,947** | 204 / 53 ms* | 1 065 / 193 ms* |
| grille 2×2 + plein écran | 0,525 | 0,922 | 0,625 | 0,883 | 851 / 169 ms | 5 137 / 1 210 ms |
| grille 3×3 + plein écran | 0,508 | 0,894 | 0,614 | 0,903 | 1 712 / 226 ms | 10 579 / 2 384 ms |
| grille 3×3 + plein écran + fenêtre | 0,514 | 0,908 | 0,619 | 0,911 | 1 706 / 226 ms | 10 819 / 2 381 ms |
| *mises en page jamais vues (tête, plein écran + fenêtre)* | | 0,677 | | **0,892** | | |
| *vidéo immobile (tête, plein écran + fenêtre)* | | 0,933 | | 0,800 | | |

\* La fenêtre n'est recadrée que si elle ne couvre pas déjà l'écran : souvent, une seule passe suffit.

**La meilleure précision par ms est « plein écran + fenêtre au premier plan » avec une tête entraînée**, pour les
deux encodeurs. Les grilles coûtent 4 à 10 fois plus pour un gain nul ou négatif : elles diluent le contexte. Le
zéro-shot sur des phrases plafonne à 0,50–0,63, car il confond page web, discussion et documents.

### Activité, chaîne complète du service

La chaîne complète ajoute l'a priori du processus au premier plan, la pause sur les jeux en plein écran, la
pénalité « jeu » hors plein écran et la confirmation par la zone de mouvement.

| | SigLIP | Gemma 2 |
| --- | --- | --- |
| plein écran, zéro-shot (**actuel**) | **0,536** | 0,628 |
| plein écran + tête | 0,844 | 0,856 |
| **plein écran + fenêtre + tête** (prêt dans `vision.py`, activé par le flag) | **0,897** | 0,892 |
| … dont mises en page jamais vues | 0,662 | 0,769 |

Dans le service, le nom du processus apporte déjà beaucoup. Les deux encodeurs font donc jeu égal, et l'écart
d'encodeur ne se voit plus que sur les mises en page inédites.

### Où est la vidéo ?

Rectangle juste si l'IoU ≥ 0,5. Il y a 93 écrans avec vidéo et 267 sans.

| méthode | SigLIP rappel / précision / F1 | Gemma 2 rappel / précision / F1 | fausses alertes sans vidéo (S / G) | coût en plus du plein écran |
| --- | --- | --- | --- | --- |
| mouvement seul | 0,15 / 0,15 / 0,15 | identique | 14 % | 0 |
| mouvement + confirmation zéro-shot (**actuel**) | 0,15 / 0,24 / 0,19 | 0,12 / 0,38 / 0,18 | 6,4 % / 0,4 % | 1 recadrage |
| cases 3×3, tête | 0,48 / 0,47 / 0,48 | 0,46 / 0,47 / 0,47 | 4,9 % / 2,6 % | 9 recadrages |
| mouvement + cases (tête) | 0,20 / 0,25 / 0,23 | 0,25 / 0,31 / 0,27 | 2,2 % / 1,9 % | 9 recadrages |
| **mouvement élargi + cases (tête)** (`vision_strategies.motion_region_any`) | **0,52 / 0,73 / 0,60** | 0,46 / 0,74 / 0,57 | **1,5 %** / 1,1 % | 9 recadrages |

Ce qu'on apprend :

1. La carte de mouvement actuelle (une case doit changer dans 3 paires sur 4) ne trouve souvent qu'**une partie**
   de la vidéo : les zones unies (ciel, fond) ne changent pas assez en 1 s. Les rectangles sont trop petits
   (IoU < 0,5). Avec « une case qui change au moins une fois, dilatée d'une case », 87 % des vidéos qui bougent
   sont trouvées. Mais les défilements et les jeux fenêtrés font alors 55 % de fausses alertes.
2. La **confirmation par les cases 3×3 avec une tête entraînée** élimine ces fausses alertes (1,5 %) et trouve
   aussi des vidéos immobiles ou « qui parlent ». C'est le meilleur compromis. Coût : 9 recadrages, soit
   ~190 ms sur DirectML avec SigLIP (acceptable toutes les 3 s) mais 1,8 s avec Gemma 2.
3. L'encodeur ne fait pas la différence ici : SigLIP est même un peu meilleur.

Ce n'est **pas** encore branché dans `vision.py`. C'est la prochaine étape logique pour la vision, quel que soit
l'encodeur (voir § 7).

## 5. Coûts : RAM, disque, temps

RAM (working set, chaque composant chargé seul dans un processus neuf, `--ram`) :

| | Laya / SigLIP (actuel) | EmbeddingGemma 2 |
| --- | --- | --- |
| Python + onnxruntime à vide | 20 Mo | 20 Mo |
| **texte chargé** | **810 Mo** | **347 Mo** |
| vision sur CPU | 261 Mo | 1 016 Mo (backbone partagé avec le texte) |
| vision sur DirectML | 173 Mo (privé 426) | 400 Mo (privé 1 365) |
| texte + vision (CPU) | ~1 050 Mo | ~1 020 Mo (un seul backbone) |
| **hybride recommandé** : texte Gemma + vision SigLIP DirectML | | **~500 Mo** |

Disque d'une installation joueur (`models/`, en plus de `.venv` 181 Mo, identique pour toutes les options) :

| | actuel | hybride `gemma2-text` | tout `gemma2` |
| --- | --- | --- | --- |
| texte | Laya 399 + 3 têtes 85 + tokenizer 33 = 517 Mo | backbone 148 + embeddings 129 + tokenizer 31 + têtes 1 = **309 Mo** | 309 Mo |
| vision | SigLIP 178 Mo | SigLIP 178 + tête 4 = **182 Mo** | tour Gemma 641 + têtes 4 = 645 Mo |
| **total `models/`** | **~694 Mo** | **~491 Mo** | **~954 Mo** |

Le paquet ONNX de Gemma 2 ne contient **aucune dépendance nouvelle** : onnxruntime, numpy, tokenizers et pillow
sont déjà dans `.venv`. Il n'y a pas de PyTorch.

Temps de chargement du texte : 4,9 s (Laya) contre 8,8 s (Gemma 2 dans le service). Les règles répondent
pendant ce temps.

## 6. Comment basculer

1. Produire les modèles (développeur, une fois ; les fichiers vont dans `models/`) :
   ```powershell
   cd assistant
   dev\gemma_venv\Scripts\python.exe export_gemma_onnx.py                 # models\gemma2\ (backbone 8 bits, vision fp32, parité)
   dev\gemma_venv\Scripts\python.exe train_gemma_heads.py --text --secret # models\gemma2\text_heads.npz
   dev\gemma_venv\Scripts\python.exe train_gemma_heads.py --vision --encoder siglip --limit 360
   copy dev\heads_vision\siglip_vision_heads.npz models\                  # tête d'activité SigLIP (mode hybride)
   ```
   (`dev\gemma_venv` : Python 3.11, torch 2.14 CPU, torchvision, transformers 5.19, sentence-transformers 6.1,
   onnx, onnxscript, onnxruntime-directml 1.24.4. Modèle source dans `dev\embeddinggemma2\`. Tous ces fichiers
   sont **déjà produits** sur ce PC.)
2. Activer le mode hybride : variable d'environnement **`ASSIST_BACKEND=gemma2-text`** pour le processus du
   service. Ou bien `service.py --backend gemma2 --vision-backend siglip --vision-head`.
   - `ASSIST_BACKEND=gemma2` : Gemma 2 pour tout. `laya`, ou rien : comportement actuel, inchangé.
   - Le Godot (`SuggestClient` / `VisionClient`) **ne change pas**. Les routes HTTP et leurs réponses sont
     identiques (`/health` indique en plus `vision_model`). Pour lancer le service avec la variable,
     `suggest_client.gd` peut ajouter `ASSIST_BACKEND` à l'environnement du processus qu'il démarre. **Je n'ai
     pas touché `godot/`.** Sinon, il suffit de définir la variable pour la session Windows.
3. Vérifier :
   ```powershell
   $env:ASSIST_BACKEND="gemma2-text"; .venv\Scripts\python.exe tests\smoke_service.py --cpu   # SMOKE OK
   .venv\Scripts\python.exe -m unittest discover -s tests                                     # 43 tests OK
   ```
4. Livrer : ajouter `models\gemma2\` (sans `vision.fp32.onnx` en mode hybride) et
   `models\siglip_vision_heads.npz` au paquet. Garder les fichiers Laya tant que le mode `laya` reste le défaut.
   Ensuite, Laya peut partir (−517 Mo). **Attention :** `/decide` (choix zéro-shot du jeu) passe alors par la
   similarité Gemma au lieu de la tête d'origine de Laya. La réponse a le même format, mais la qualité n'a pas été
   mesurée faute de jeu de décisions de jeu. `/embed` (boucle de retour de l'autre agent) utilise toujours
   SigLIP / Laya.

## 7. Ce qui reste / ce que je n'ai pas pu vérifier

- **Données réelles** : tout est synthétique. Les écrans sont dessinés, les vidéos sont procédurales, et les
  descriptions de champs sont réalistes mais générées. Le harnais accepte déjà les jeux réels :
  `tests/eval_v2.py --text --real fichier.jsonl` et `--vision --real-vision dossier`. Il faut relancer la
  comparaison quand `tools/build_real_dataset.py` aura produit son split d'éval. C'est surtout là que
  l'avantage de Gemma 2 sur les mises en page inédites pourrait compter.
- **Vision** : la stratégie « mouvement élargi + cases 3×3 + tête » n'est pas branchée dans le service. Mesurée
  seulement : F1 0,60 contre 0,19 aujourd'hui. Pour SigLIP sur DirectML, elle coûterait ~190 ms toutes les 3 s.
- **`/decide`** avec Gemma 2 : vérifié fonctionnel (« manger », 0,79), qualité non mesurée.
- **Faiblesse de Gemma 2** sur les champs adverses et `other` (−10 points). Ajouter quelques exemples négatifs
  (« Code promo », « Instructions… ») dans `data/gen_train.py` serait la correction naturelle. Il faudrait alors
  réentraîner aussi les têtes stuntd, pour rester loyal.
- **DirectML pour Gemma 2** : seule la tour de vision en profite. Le backbone 8 bits retombe sur le CPU. Un backbone
  fp32 dédié au GPU irait plus vite, mais coûterait +523 Mo de disque. Non fait.
- **Échelle zéro-shot de Gemma 2** : l'ajustement a buté sur sa borne (×20). Ça ne change pas le choix de la
  classe, mais les probabilités zéro-shot de Gemma 2 sont trop plates. Avec la tête, ça ne compte plus.
- Le jeu test Godot (`godot/tests/*`) n'a pas été relancé : aucune modification de `godot/`.

## 8. Temps passé

À peu près 7 h 30 de bout en bout. Le gros du temps machine :

| étape | durée |
| --- | --- |
| encodage Gemma 2 des 360 écrans d'entraînement | 1 h 50 |
| encodage Gemma 2 des 360 écrans d'éval | 1 h 50 |
| têtes texte | 38 min, dont 32 d'encodage |
| éval texte | 2 × 25 min |
| SigLIP | 40 min |

Tout a tourné sur 4 fils, sur le CPU. **Erratum** : jusqu'à 14 h, mes scripts demandaient la priorité basse
via `SetPriorityClass`, mais l'appel échouait sans erreur. Sans `restype`, ctypes tronque la pseudo-poignée
`GetCurrentProcess()`. Les premiers calculs (baseline texte, têtes texte, génération d'écrans, étape SigLIP de la
vision) ont donc tourné en priorité **normale** (4 fils seulement). J'ai remis l'encodage Gemma en cours en
priorité « inactive » à 13 h 59. Corrigé dans `pompom_assist/lowprio.py`, avec vérification. Le même
défaut existe dans `tools/real_common.py` (code de l'autre agent, non modifié).

## Fichiers

| fichier | rôle |
| --- | --- |
| `data/gen_eval_v2.py` → `data/eval_v2/text.jsonl` | jeu texte figé (1 850 cas) + contrôle de disjonction |
| `data/gen_screens.py` → `data/eval_v2/vision/` | écrans synthétiques (éval figée, 61 Mo, ignorée par git ; `--split train` → `dev/vision_train`) |
| `data/eval_v2/README.md` | construction des jeux |
| `tests/eval_v2.py` (+ `eval_v2_vision.py`, `eval_v2_report.py`) | banc complet en une commande : texte, vision, latence, RAM, `--real` |
| `tests/test_gemma.py` | tests du backend Gemma 2 (prétraitement, grille, interface du décideur) |
| `export_gemma_onnx.py` | export ONNX + quantification + parité (dev) |
| `train_gemma_heads.py` | têtes texte / secret / vision (dev, CPU, priorité basse) |
| `pompom_assist/gemma_onnx.py` | `GemmaEncoder`, `GemmaHeads` (= `OnnxHeads`), `GemmaEyes` (= `SiglipEyes`), sans PyTorch |
| `pompom_assist/np_heads.py` | têtes en numpy (format `.npz`) |
| `pompom_assist/vision_strategies.py` | recadrages, cases → rectangle, IoU, mouvement élargi |
| `pompom_assist/lowprio.py` | priorité basse **qui marche** |
| `pompom_assist/rules.py` (`is_secret_field`), `decider.py` (garde secrets) | garde des champs secrets (défaut) |
| `pompom_assist/vision.py` | tête d'activité optionnelle + recadrage de la fenêtre au premier plan (seulement si une tête est chargée) |
| `service.py` | `ASSIST_BACKEND` / `--backend` / `--vision-backend` / `--vision-head` (défaut inchangé) |
| `models/gemma2/` (ignoré par git) | backbone 8 bits, embeddings int8, tour de vision fp32, tokenizer, têtes, `gemma2.json`, `parity.json`, licence |
| `models/siglip_vision_heads.npz` (ignoré par git) | têtes d'activité SigLIP (mode hybride) |
| `dev/embeddinggemma2/`, `dev/gemma_venv/`, `dev/gemma2_fp32/`, `dev/cache/`, `dev/vision_train/` | source, environnement de dev, backbone fp32, vecteurs en cache (réévaluer sans réencoder), écrans d'entraînement |
