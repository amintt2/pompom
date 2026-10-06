# Événements de jeu : Pompom réagit à tes buts, éliminations et morts

Tout passe par le hub `godot/scripts/games/game_events.gd` (`GameEvents`). Rocket League est détaillé dans
[rocket_league.md](rocket_league.md). Tests : `godot/tests/game_events_test.tscn` et `godot/tests/rocket_league_test.tscn`.

Règle d'or : **uniquement des API officielles, locales et sans risque anti-triche**, ou de la **capture d'écran**
(comme OBS / Discord / Medal.tv). Jamais de lecture mémoire, d'injection, d'entrée simulée. Tout fichier de
configuration d'un jeu n'est écrit **qu'après l'accord de l'utilisateur**.

## 1. Signaux du hub

```gdscript
signal event(kind: String, mine: bool, data: Dictionary)
signal game_changed(proc: String, genre: String)
signal setup_suggested(game: String, message: String)   # proposer une intégration officielle (texte en français)
signal status_changed(source: String, status: String)   # "rocket_league"/"cs2_dota"/"lol" : connected|disconnected ; "hud" : ok|black|frozen|idle
func apply_setup(game: String) -> String                # APRÈS accord ; "" = OK, sinon message d'erreur
func hud_hint() -> String                               # « mets le jeu en plein écran fenêtré » si la capture est noire/figée
```

| `kind` | `mine` | Sources |
|---|---|---|
| `goal` | true = mon équipe a marqué, false = l'adversaire | Rocket League (API, écran) |
| `goal_any` | false | but dont on ne sait pas qui l'a marqué (équipe inconnue) |
| `kill` | true (toujours l'utilisateur lui-même) | CS2, Dota 2, LoL (API) ; Valorant, Fortnite (écran) |
| `death` | true (c'est l'utilisateur qui est mort) | CS2, Dota 2, LoL (API) ; Valorant, Fortnite (écran) |
| `assist` | true | CS2, Dota 2, LoL |
| `multikill` | true, `data.n` = nombre | CS2 (≥ 3 dans la manche), Dota 2 (≥ 2 en 18 s), LoL (`Multikill`) |
| `first_blood` | true | LoL |
| `ace` | équipe qui fait l'ace = la mienne ? | LoL |
| `objective` | dragon/baron/héraut/tour/inhibiteur pris par mon équipe ? | LoL |
| `round_won` / `round_lost` | true / false | CS2 |
| `match_won` / `match_lost` | true / false | Rocket League, CS2, Dota 2, LoL |
| `match_started` | true | Rocket League, CS2, Dota 2, LoL |

`data` contient toujours `game` (`rocket_league`, `cs2`, `dota2`, `lol`, `valorant`, `fortnite`) et `source`
(`api` ou `screen`), plus des détails (`scorer`, `score_mine`, `score_theirs`, `victim`, `n`, `via`…). Le hub
supprime un même événement vu deux fois en moins d'une seconde (ex. but vu par l'API et par l'écran) ; la limitation
de fréquence des réactions reste à faire côté animation.

`game_changed(proc, genre)` : jeu au premier plan, stable 1,5 s ; `("", "")` quand on quitte les jeux ; genre
`"unknown"` si Activity dit « jeu » mais qu'il n'est pas au catalogue ; Teamfight Tactics (même processus que LoL)
passe en `"strategy"` dès que l'API LoL donne `gameMode = "TFT"`. `GameCatalog.is_thinking_genre(genre)` vrai pour
`strategy`, `card`, `puzzle` (lunettes + pose pensive).

## 2. Réglages attendus (`GameState.settings`, valeurs par défaut si absents)

| Clé | Défaut | Rôle |
|---|---|---|
| `game_events` | `true` | interrupteur général |
| `rl_stats_api` | `true` | se connecter à la Stats API de Rocket League quand le jeu tourne |
| `rl_screen_watch` | `false` | repli écran Rocket League (opt-in : capture d'écran) |
| `rl_my_color` | `"auto"` | `"auto"`, `"blue"`, `"orange"` |
| `rl_player_name` | `""` | pseudo Rocket League (optionnel) |
| `valve_gsi` | `true` | écouter CS2 / Dota 2 (port local 47326) quand un de ces jeux tourne |
| `lol_live` | `true` | interroger l'API locale de LoL pendant une partie |
| `hud_watch` | `false` | Valorant / Fortnite par l'écran (opt-in : capture d'écran) |
| `hud_regions` | `{}` | recalibrage : `{"fortnite": {"elims": [x, y, l, h]}}` (voir §6) |

## 3. Intégrations officielles vérifiées

### Counter-Strike 2 — Game State Integration (Valve)

- Mécanisme officiel de Valve : le jeu **envoie lui-même** des requêtes HTTP POST (JSON) à l'adresse déclarée dans
  `<CS2>\game\csgo\cfg\gamestate_integration_<nom>.cfg`. Aucune lecture mémoire ; utilisé par les HUD de tournoi.
- Sources : page Valve <https://developer.valvesoftware.com/wiki/Counter-Strike:_Global_Offensive_Game_State_Integration>
  (protégée par une vérification anti-robot lors de la recherche, contenu confirmé via les bibliothèques suivantes) ;
  <https://github.com/antonpup/CounterStrike2GSI> (README : chemin `game/csgo/cfg/gamestate_integration_<NOM>.cfg`,
  format du cfg, « will only expose local player's information when playing ») et ses nœuds `Provider.cs`
  (`steamid`, `appid`), `Player.cs` (`steamid`, `team`, `state`, `match_stats`), `Round.cs` (`phase`, `win_team`),
  `Map.cs` (`phase`, `team_ct`/`team_t`).
- Pompom : fichier `gamestate_integration_pompom.cfg` (uri `http://127.0.0.1:47326/`, `throttle 0.5`,
  `heartbeat 10`, jeton `auth.token` aléatoire, données `provider, map, round, player_id, player_state,
  player_match_stats`). **Le jeu doit être relancé.**
- Joueur local : quand on est mort, le bloc `player` décrit le joueur observé → on ne compte que si
  `player.steamid == provider.steamid`.
- Mort : `player.state.health` du joueur local qui passe à 0 (immédiat), avec le compteur `match_stats.deaths` en
  secours ; une seule `death` par mort (le compteur qui monte plus tard est reconnu comme déjà signalé).

### Dota 2 — Game State Integration (Valve)

- Fichier `<Dota 2>\game\dota\cfg\gamestate_integration\gamestate_integration_pompom.cfg` (dossier créé si besoin) ;
  données `provider, map, player, hero`.
- **En plus**, Dota 2 exige l'option de lancement Steam **`-gamestateintegration`** (Steam > Dota 2 > Propriétés >
  Options de lancement). Pompom **ne la modifie pas** (ce serait toucher à la configuration de Steam) : le message de
  `setup_suggested` le demande à l'utilisateur.
- Sources : <https://github.com/antonpup/Dota2GSI> (chemin du cfg ; `Map.cs` : `matchid`, `game_state`,
  `win_team`, `radiant_score`… ; `PlayerDetails.cs` : `kills`, `deaths`, `assists`, `kill_streak`, `team_name`) ;
  option de lancement : <https://support.overwolf.com/en/support/solutions/articles/9000212745-how-to-enable-game-state-integration-for-dota-2>.
- Mort : `hero.alive` qui passe à `false` (avec `player.deaths` en secours). En spectateur, `player` contient
  `team2`/`team3` → ignoré. Victoire : `map.game_state = DOTA_GAMERULES_STATE_POST_GAME` et `win_team == team_name`.

### League of Legends — Live Client Data API (Riot)

- Source : <https://developer.riotgames.com/docs/lol> (section « Game Client API ») et la liste d'événements
  <https://static.developer.riotgames.com/docs/lol/liveclientdata_events.json>.
- Servie par le **client de jeu** sur `https://127.0.0.1:2999` pendant une partie, certificat auto-signé Riot (la doc
  dit qu'on peut ignorer l'erreur ou utiliser `riotgames.pem`) : Pompom accepte le certificat **seulement pour
  127.0.0.1**. Rien à installer ni à configurer.
- Points d'accès utilisés : `/liveclientdata/activeplayername` (« Pseudo#TAG »), `/playerlist` (équipe `ORDER`/
  `CHAOS`, `riotId`, `riotIdGameName`, `summonerName`), `/gamestats` (`gameMode`), `/eventdata` (`Events[]` avec
  `EventID`, `EventName`, `KillerName`, `VictimName`, `Assisters`, `KillStreak`, `AcingTeam`, `Result`…).
- 1 requête/s seulement pendant que LoL tourne (1 toutes les 5 s tant que le client ne répond pas). Au premier
  contact, l'historique n'est pas rejoué.
- Mort : `ChampionKill` dont `VictimName` est l'utilisateur (comparé à « Pseudo#TAG », « Pseudo » et aux noms de
  `playerlist`).

### Non retenus

- **Valorant, Fortnite, Apex Legends, Overwatch 2** : aucune API locale officielle de ce type → seulement l'écran
  (Valorant et Fortnite, §5). Apex / Overwatch non faits : pas de compteur simple et stable à surveiller ; ajoutables
  plus tard en données dans `HudWatcher.PROFILES`.
- **Rocket League** : pas d'événement « mort » ; « but contre » joue ce rôle (`goal` avec `mine = false`).

## 4. Catalogue de genres (`game_catalog.gd`)

`GameCatalog.lookup(proc, title) -> {id, name, genre}` : **251 noms de processus** (Windows, minuscules, sans
`.exe`, comme `Activity.proc_name`) + jeux de navigateur reconnus au titre (Chess.com, Lichess, Wordle, Sudoku,
GeoGuessr, Solitaire…) et Minecraft Java (`javaw` + titre). Genres : strategy, card, puzzle, moba, fps, racing,
sports, fighting, platformer, rpg, action, sandbox, survival, sim, horror, party, rhythm. Les noms d'exécutables
viennent de la connaissance des jeux, pas d'une vérification un par un : quelques-uns (sorties récentes comme
Anno 117, EU5, Battlefield 6, Borderlands 4) peuvent différer ; une entrée fausse ne coûte rien (pas de réaction).

## 5. Valorant et Fortnite par l'écran (`hud_watcher.gd`, opt-in)

Le principe de Medal.tv / Insights, en beaucoup plus léger : **pas de modèle de vision en continu**, seulement 3 à
4 toutes petites captures 3 fois par seconde, analysées dans `WorkerThreadPool`, et **seulement quand le jeu est au
premier plan** et que `hud_watch` est actif.

| Jeu | Zone | Type | Détecte |
|---|---|---|---|
| Valorant | bandeau d'élimination, bas-centre (x 45,5–54,5 %, y 70–80 %) | flash blanc | `kill` ; si l'empreinte change pendant qu'il est affiché : kill suivant enchaîné |
| Valorant | « tué par », bas-centre (x 38–62 %, y 79–86 %) | flash rouge | `death` |
| Valorant | image désaturée en observation (centre) | gris | `death` — **expérimental, coupé par défaut** (`hud.enabled_extra["grey_view"] = true`) |
| Fortnite | compteur d'éliminations sous la mini-carte (ancré à droite) | chiffres | `kill` à chaque changement |
| Fortnite | « ÉLIMINÉ : pseudo » sous le réticule | flash blanc | `kill` (dédoublonné avec le compteur) |
| Fortnite | « éliminé par » / interface d'observation, haut-centre | flash blanc | `death` |

- Écrans : x est exprimé dans une boîte 16:9 de la hauteur de l'écran, centrée ou collée au bord droit/gauche
  (ultra-larges : le HUD central reste centré, le compteur Fortnite suit le coin) ; en 16:10 la boîte prend la largeur.
- Anti-rebond : un bandeau doit disparaître (sous `off_frac`) avant de pouvoir compter à nouveau ; un compteur doit
  être stable sur 2 captures ; une mort n'est comptée qu'une fois par 6 s ; deux zones qui voient la même
  élimination → un seul `kill` (1,5 s).
- Sonde de capture (petit carré au centre) : `capture_status = "black"` (6 captures noires) ou `"frozen"` (image
  identique 20 s) → `status_changed("hud", ...)` et `hud_hint()` : « Je ne vois pas l'image du jeu : mets-le en
  « plein écran fenêtré » … ».

### Précision : ce qu'il faut savoir honnêtement

- Les zones et couleurs par défaut sont des **estimations** de la position des éléments du HUD **par défaut** ;
  elles **n'ont pas pu être vérifiées sur de vraies images** (ni Valorant ni Fortnite sur ce PC). Elles sont dans
  `HudWatcher.PROFILES` et se recalibrent sans code : réglage `hud_regions` ou `hud.set_region(jeu, zone, [x, y, l, h])`.
  `hud.dump_regions()` enregistre les zones capturées en PNG (`user://hud_dump/`) pour vérifier/ajuster.
- Faux positifs possibles : décor très clair dans la zone du bandeau (Valorant), texte blanc d'un autre message au
  même endroit (Fortnite), rouge vif dans la zone « tué par ». Faux négatifs : HUD redimensionné, bannière
  d'élimination personnalisée, daltonisme, captures noires. Seuils volontairement prudents : mieux vaut rater une
  réaction que se tromper (surtout pour la tristesse).
- Confirmation possible par le modèle de vision (service local `GET /vision` d'un autre module) : **pas branchée** ;
  si elle l'est un jour, ce doit être une seule requête par détection, jamais en continu.

### Plein écran exclusif

`DisplayServer.screen_get_image_rect` copie l'écran par GDI (`BitBlt`). Pour un jeu en **plein écran exclusif**, le
contenu peut ne pas passer par la composition du bureau : la capture renvoie alors du **noir ou une image figée**.
En **plein écran fenêtré / fenêtre sans bordure**, l'image est composée par Windows et la capture fonctionne (même
principe que la « capture d'écran » d'OBS, par opposition à sa « capture de jeu »). Les deux jeux proposent ce mode
(Valorant : « Plein écran fenêtré » ; Fortnite : « Plein écran fenêtré »). Pas pu être vérifié en vrai sur ce PC
(jeux absents) : c'est pourquoi la sonde `capture_status` existe.

### Coûts mesurés (ce PC, écran 2560×1440)

| Mesure | Résultat |
|---|---|
| Petite capture GDI (60×40) | **~0,35 ms de CPU** (mesuré sur 500 captures), mais ~6 ms d'attente de la composition de Windows |
| Capture 600×130 | ~0,9 ms de CPU |
| Analyse Fortnite (2 zones, image 4K) | ~0,95 ms |
| Échantillon complet sur le thread de travail (temps écoulé, attentes GDI incluses) | Valorant 3 captures ~20 ms, Fortnite 4 captures ~31 ms |
| CPU réel par échantillon | ≈ 1,3 ms (captures) + ~1 ms (analyse) ≈ **2–2,5 ms**, 3 fois/s ≈ 0,7 % d'un cœur |
| Thread principal | jamais bloqué (pire image 8,5 ms = rythme normal) |

L'objectif « < 2 ms de CPU par échantillon » est atteint pour l'analyse, et à peine dépassé avec les captures ;
l'attente GDI (~6–10 ms par appel) se passe sur un thread de fond et ne consomme pas de CPU. À 3 Hz, la copie
demandée à Windows ne devrait pas se voir dans le jeu, mais cela n'a pas pu être mesuré dans les jeux eux-mêmes.

## 6. Mise en place côté utilisateur

| Jeu | À faire |
|---|---|
| Rocket League | accepter la proposition (Pompom passe `PacketSendRate` à 5 dans les ini, avec sauvegarde) puis **relancer le jeu** ; ou activer le repli écran (`rl_screen_watch`) et choisir sa couleur si besoin |
| Counter-Strike 2 | accepter la proposition (fichier `gamestate_integration_pompom.cfg`) puis **relancer CS2** |
| Dota 2 | accepter la proposition **et** ajouter `-gamestateintegration` aux options de lancement Steam, puis relancer |
| League of Legends / TFT | rien |
| Valorant, Fortnite | activer « il regarde le HUD » (`hud_watch`) et jouer en **plein écran fenêtré** |

Désinstallation : `RocketLeagueLink.disable_stats_api()`, `ValveGsiLink.uninstall_config("cs2" | "dota2")`.
