# Rocket League : Pompom fête tes buts

Code : `godot/scripts/games/rocket_league.gd` (`RocketLeagueLink`), `godot/scripts/games/scoreboard_watcher.gd`
(`ScoreboardWatcher`, repli par l'écran), branchés par le hub `godot/scripts/games/game_events.gd` (`GameEvents`).
Tests : `godot/tests/rocket_league_test.tscn`.

## 1. Ce qui a été vérifié (octobre 2026)

### La « Stats API » officielle de Psyonix

Source officielle : <https://www.rocketleague.com/developer/stats-api> (page lue en entier le 6 octobre 2026).

| Point | Fait vérifié |
|---|---|
| Activation | Fichier `<Install>\TAGame\Config\TAStatsAPI.ini` (ou `DefaultStatsAPI.ini` s'il n'existe pas), section `[TAGame.MatchStatsExporter_TA]`. |
| `PacketSendRate` | float, **0 par défaut = désactivé**, plafonné à 120 : nombre de paquets `UpdateState` par seconde. |
| `Port` | int, **49123** par défaut : socket **TCP** locale. 0 = désactivé. |
| `WebPort` | int, **49124** par défaut : **WebSocket** locale. 0 = désactivé. Doit différer de `Port`. |
| Redémarrage | « All configuration must be done before the client starts » : **il faut relancer Rocket League** après modification. |
| Messages | `{"Event": "...", "Data": {...}}`. Les événements (buts…) partent **au tick où ils arrivent**, quel que soit `PacketSendRate`. |
| Événements | `UpdateState`, `BallHit`, `BoostPickup`, `ClockUpdatedSeconds`, `CountdownBegin`, `CrossbarHit`, `GoalReplayStart/WillEnd/End`, `GoalScored`, `MatchCreated`, `MatchInitialized`, `MatchEnded`, `MatchDestroyed`, `MatchPaused/Unpaused`, `PlayerJoined/Left`, `PodiumStart`, `ReplayCreated`, `RoundStarted`, `StatfeedEvent`. |
| `UpdateState.Players[]` | `Name`, `PrimaryId` (`Plateforme|Uid|Splitscreen`), `Shortcut`, `TeamNum` (0 bleu, 1 orange), `Score`, `Goals`, `Shots`, `Assists`, `Saves`, `Touches`, `CarTouches`, `Demos`, `Loadout`… ; `Boost`, `Speed`, `bOnGround`… marqués **SPECTATOR** (envoyés seulement en spectateur). |
| `UpdateState.Game` | `Teams[]` (`Name`, `TeamNum`, `Score`, `ColorPrimary`, `ColorSecondary`), `TimeSeconds`, `bOvertime`, `Ball`, `bReplay`, `bHasWinner`, `Winner`, `Arena`, **`bHasTarget`** (« le client regarde un véhicule précis »), **`Target`** {`Name`, `Shortcut`, `TeamNum`} (joueur actuellement regardé). |
| `GoalScored` | `GoalSpeed`, `GoalTime`, `ImpactLocation`, **`Scorer` {`Name`, `Shortcut`, `TeamNum`}**, `Assister` (si passe décisive), `BallLastTouch`. |
| `MatchEnded` | **`WinnerTeamNum`**. |
| `MatchGuid` | présent seulement en ligne / LAN. |
| Commandes | la socket accepte aussi des commandes (`ChangePOV`, `SetHUDVisibility`, `SetMatchPaused`…). **Pompom n'en envoie aucune.** |

Pas de champ « joueur local » explicite : la doc ne donne que `Target` (le véhicule regardé). Quand on joue,
la caméra suit sa propre voiture, donc `Target` = soi (hors replays de but, où `bReplay` = true).

### Constaté sur ce PC (lecture seule, aucun fichier modifié)

- Rocket League installé via **Epic** : `C:\Program Files\Epic Games\rocketleague` (manifeste Epic `AppName = "Sugar"`,
  lanceur `Binaries/Win64/Launcher.exe`, présence de `RocketLeague_EAC.exe` = Easy Anti-Cheat).
- `DefaultStatsAPI.ini` dans l'installation : `Port=49123`, `WebPort=49124`, `PacketSendRate=0` (commentaires inclus).
- Le jeu a **généré** `Documents\My Games\Rocket League\TAGame\Config\TAStatsAPI.ini` (`PacketSendRate=0`) avec une
  section `[IniVersion] 0=<horodatage>` : mécanisme Unreal Engine 3, le fichier généré est reconstruit depuis le
  `Default…` si celui-ci change. → Pompom modifie **les deux** (voir §3).

### Format réel sur la socket TCP (implémentations tierces)

- <https://github.com/zomlit/rocket-league-stats-api> : la socket TCP envoie des objets JSON **concaténés sans
  séparateur**, et `Data` est une **chaîne JSON** (`"Data": "{\"MatchGuid\":...}"`), pas un objet.
- <https://github.com/DevJMD/rocket-league-stats-api> (`src/protocol/decode.ts`) : « `Data` arrives as a JSON encoded
  string on current builds, and as a nested object in the published envelope. Both are accepted. » ; fichiers
  `TAStatsAPI.ini` puis `DefaultStatsAPI.ini`, ports 49123/49124.
- <https://github.com/manucabral/rlstatsapi> : `Documents\My Games\Rocket League\TAGame\Config\TAStatsAPI.ini`.

→ Le décodeur de Pompom accepte les deux formes de `Data`, les messages collés, coupés n'importe où (y compris au
milieu d'un caractère UTF-8) et une éventuelle mise en forme avec espaces.

### Sans BakkesMod

Depuis l'arrivée d'Easy Anti-Cheat sur PC (28 avril 2026), BakkesMod ne fonctionne plus en ligne et le projet est
arrêté ; la Stats API officielle est justement la voie prévue par Psyonix pour ces usages (HUD de diffusion…).
Sources : <https://insider-gaming.com/rocket-league-anti-cheat/>,
<https://www.trophi.ai/post/rocket-league-updates-after-eac-bakkesmod-ballchasing-and-whats-actually-different-now>.
Le repli par l'écran (§4) n'a besoin d'aucun mod non plus.

## 2. RocketLeagueLink (API)

- Connexion **TCP** à `127.0.0.1:49123` (`StreamPeerTCP`, non bloquant). Tentatives toutes les 4 s **uniquement**
  pendant que Rocket League a été vu au premier plan dans les 10 dernières minutes (`GameEvents` pilote
  `game_present`). Une fois connecté, on reste connecté même si on change de fenêtre.
- Lecture de la socket 20 fois/s au plus ; les `UpdateState` sont filtrés **avant décodage** (au plus 2,5/s traités,
  `update_min_interval = 0.4`) : score et cible caméra n'ont pas besoin de plus. Les événements (`GoalScored`…)
  sont toujours traités immédiatement.
- **Mon équipe**, par priorité : `force_color` (« blue »/« orange ») → `player_name` (pseudo indiqué) présent dans
  `Players[]` → **nom le plus souvent en `Target` hors replay** pendant la session (vote) → indice faible : champ
  `Boost` visible pour une seule équipe (non documenté officiellement). Sinon équipe inconnue : `goal_unknown`.
- Buts : `GoalScored` → `goal(...)`. Filet de sécurité : si le score d'`UpdateState` monte sans `GoalScored` dans
  les 1,5 s, le but est déduit du score. Connexion en plein match : le score est repris sans « but fantôme ».
- Fin : `MatchEnded.WinnerTeamNum` (secours : `Game.bHasWinner` + `Winner`).

### API publique

```gdscript
signal goal(my_team: bool, scorer: String, score_mine: int, score_theirs: int)
signal goal_unknown(scorer: String, team_num: int)   # équipe de l'utilisateur inconnue
signal match_started()
signal match_ended(won: bool)                         # seulement si l'équipe est connue
signal score_changed(mine: int, theirs: int)
signal connected_changed(ok: bool)
signal team_known(team_num: int)                      # 0 bleu, 1 orange

var game_present: bool   # piloté par GameEvents
var force_color := "auto"  # "auto" | "blue" | "orange"
var player_name := ""
var my_team: int; var my_name: String; var scores: Array; var connected: bool

static func stats_api_status() -> Dictionary
    # {found, install_dir, files: [{path, exists, rate, port}], enabled, port}  — lecture seule
static func enable_stats_api(rate := 5) -> String      # "" = OK, sinon message d'erreur (français)
static func disable_stats_api() -> String
```

## 3. Activer la Stats API (avec l'accord de l'utilisateur)

`enable_stats_api()` ne doit être appelé **qu'après confirmation** (le hub émet `setup_suggested("rocket_league", msg)`
puis `apply_setup("rocket_league")`). Elle :

1. trouve l'installation : manifestes Epic `%ProgramData%\Epic\EpicGamesLauncher\Data\Manifests\*.item`
   (`AppName`/`DisplayName`/`InstallLocation` contenant « sugar » / « rocketleague »), sinon Steam
   (`libraryfolders.vdf` → `steamapps\common\rocketleague`) ;
2. pour chaque fichier existant parmi `Documents\My Games\Rocket League\TAGame\Config\TAStatsAPI.ini`,
   `<install>\TAGame\Config\TAStatsAPI.ini`, `<install>\TAGame\Config\DefaultStatsAPI.ini` :
   - ne fait **rien** si `PacketSendRate` est déjà > 0 (idempotent) ;
   - sinon crée **une seule fois** `<fichier>.pompom.bak` (copie d'origine, jamais écrasée), puis remplace la seule
     ligne `PacketSendRate=` dans la bonne section (ajoutée si absente), en gardant fins de ligne CRLF,
     commentaires, `Port`, `WebPort` et `[IniVersion]` ; relit le fichier pour vérifier.
3. Valeur par défaut **5** paquets/s (les buts arrivent de toute façon instantanément ; moins de paquets = moins de
   travail pour le jeu).

**Le jeu doit être relancé** pour que ce soit pris en compte (doc officielle). Conseillé : fermer Rocket League
avant. `disable_stats_api()` remet `PacketSendRate=0`. Le dossier Epic de ce PC est accessible en écriture pour
l'utilisateur ; ailleurs, si `Program Files` est protégé, l'écriture du `Default…` peut échouer : la modification
du `TAStatsAPI.ini` des Documents suffit tant que le jeu ne régénère pas ce fichier (mise à jour du jeu).

## 4. ScoreboardWatcher (repli par l'écran, opt-in)

Actif seulement si : Rocket League au premier plan **et** réglage `rl_screen_watch` **et** API non connectée.

- 2 captures/s de la zone `x 38–62 %, y 0–9 %` de l'écran du jeu (`DisplayServer.screen_get_image_rect`, GDI),
  **dans `WorkerThreadPool`** : le thread principal ne fait que lancer la tâche et lire le résultat.
- Réduction (moyenne 2×2 puis 180 px de large), classement des pixels bleu / orange / blanc, recherche par
  projections de la **boîte bleue à gauche** et de la **boîte orange à droite** (remplissage ≥ 70 %, forme plausible).
- Empreinte des chiffres : grille 8×7 posée sur le cadre des pixels blancs de la boîte + largeur des chiffres. Pas d'OCR.
- Anti faux positifs : une empreinte doit être identique sur **3 captures (1,5 s)** ; disparition courte (< 8 s,
  replay/transition) → comparaison à la réapparition ; longue → nouvelle référence sans but ; les **deux** boîtes qui
  changent ensemble (nouveau match) → aucun but ; 4 s minimum entre deux buts d'une même équipe.
- **Mon équipe** : le tableau de Rocket League met **toujours** le bleu à gauche et l'orange à droite, quelle que
  soit l'équipe du joueur ; rien de fiable à l'écran n'indique son camp. D'où `my_color` = `"blue"`, `"orange"` ou
  `"auto"` ; en `"auto"`, on réutilise l'équipe apprise par la Stats API (`known_team`) si elle a servi ; sinon
  `goal_unknown(couleur)` (le hub émet `goal_any`, réaction neutre). Les scores émis sont **relatifs** (buts vus
  depuis l'apparition du tableau).
- Limites : couleurs de club personnalisées, mode daltonien, HUD masqué ou réduit, plein écran exclusif (capture
  noire : `capture_ok = false`), autre mise en page du tableau (tournois, modes extra).

## 5. Coûts mesurés (ce PC, Godot 4.7.2, écran 2560×1440)

| Mesure | Résultat |
|---|---|
| Décodage d'un `UpdateState` réel (≈ 2 Ko, 6 joueurs) | ~260–310 µs si tout est décodé |
| Même flux avec le filtrage réel (≤ 2,5 `UpdateState`/s décodés) | **~21 µs par message reçu** |
| Analyse d'une capture du tableau (1080p ou 4K) | **~3,6–3,9 ms** sur le thread de travail, 2 fois/s |
| Capture GDI de la zone (614×129) | ~0,9 ms de **CPU** ; ~10 ms d'attente (synchronisation avec la composition de Windows, pas du calcul) |
| Même capture sur le thread principal | 9,4 ms (c'est pourquoi elle est faite dans `WorkerThreadPool`) |
| Pire image du thread principal pendant les captures | 8,5 ms (= le rythme normal de l'appli, aucun pic) |

En résumé : API ≈ 0,1 ms de CPU par seconde ; repli écran ≈ 9 ms de CPU par seconde sur un thread de fond
(< 1 % d'un cœur). Note honnête : la capture GDI de l'écran demande à Windows une copie de l'image composée ; à
2 Hz l'effet sur le jeu devrait être imperceptible, mais il n'a pas pu être mesuré dans Rocket League lui-même.

## 6. Tests

`tools\godot\Godot_v4.7.2-stable_win64_console.exe --path godot --headless res://tests/rocket_league_test.tscn`
(sans `--headless` : mesure en plus une vraie capture). Couvre : messages coupés au hasard (y compris dans un
caractère UTF-8), plusieurs messages par lecture, `Data` chaîne ou objet, JSON indenté, déchets puis
resynchronisation, but de mon équipe / adverse, absence de doublon `GoalScored` + `UpdateState`, but déduit du score,
connexion en plein match, fin de match, replay qui suit un autre joueur, équipe inconnue, couleur forcée, pseudo
imposé, indice `Boost`, modification d'ini sur **copies** (CRLF, `[IniVersion]`, sauvegarde unique, idempotence,
désactivation), tableau de synthèse en 720p/1440p/4K, chaque passage 0→12, horloge ignorée, transitions et replays.
