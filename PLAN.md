# olalatab — plan

⌥ Option + Tab affiche les fenêtres de l'app au premier plan (Bureau courant, non réduites) et permet d'en choisir une. Exigence n°1 : la performance, mesurée.

## 0. Ce que le spike a déjà vérifié (macOS 26.6, M5 Max)

| Point | Résultat |
|---|---|
| `RegisterEventHotKey(kVK_Tab, optionKey)` | accepté (status 0) et déclenché par un ⌥⇥ synthétique. La restriction « ⌥ seul » de Sequoia ne bloque pas ici. À reconfirmer avec un vrai clavier. |
| Symboles privés | `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`, `SLSMainConnectionID`, `_AXUIElementGetWindow` présents. |
| `CGWindowListCopyWindowInfo(onScreenOnly)` | 41 fenêtres système : p50 0,44 ms, p99 4,3 ms. Le p99 est le premier risque à mesurer. |

## 1. Architecture

```
⌥⇥ ─Carbon hotkey─▶ Switcher ─▶ WindowSource ─▶ Ordering ─▶ Panel (NSPanel + NSTableView)
                       │                                         │
                  EventTap (actif seulement panneau ouvert)      ▼
                  Tab / ⇧Tab / Échap / ⌥ relâché ──────▶ Focuser (SkyLight, repli AX)
```

Paquet SwiftPM, même découpe que swipekey :

- `Sources/OlalaCore/` (testable sans clavier ni écran)
  - `WindowInfo` : `id: CGWindowID`, `pid`, `title`, `frame`, `zIndex`.
  - `Ordering` : `creation | recent | title | position` (tri pur, stable ; `title` insensible à la casse et aux accents, égalité départagée par `id`).
  - `Selection` : état du cycle (index, `next()`, `previous()`, bouclage), sélection initiale.
  - `WindowFilter` : filtre pur sur les dictionnaires CG (pid, layer 0, alpha > 0, taille > 1×1, pas de fenêtre fantôme sans titre ni taille).
  - `Config` : `~/.config/olalatab/config.json` (`order`, plus tard thème/taille). Fichier absent = défauts.
  - `Stats` : percentiles p50/p99 (pour le banc).
- `Sources/CSkyLight/` : en-tête C qui déclare les symboles privés, chargés par `dlsym` (pas de lien direct au framework privé : si Apple retire un symbole, l'app passe au repli au lieu de ne pas démarrer).
- `Sources/olalatab/` : AppKit — `HotKey`, `EventTap`, `Panel`, `Focuser`, `AXPrefetcher`, `Bench`, `main.swift`.
- `Tests/OlalaCoreTests/`.

### Déclenchement

- `RegisterEventHotKey` pour ⌥⇥ : aucun tap clavier au repos, donc 0 réveil et 0 latence ajoutée aux frappes normales.
- À l'ouverture : `CGEvent.tapCreate` (session, tête, `keyDown|keyUp|flagsChanged`) activé ; à la fermeture : `CGEvent.tapEnable(false)` (créé une fois, réutilisé). Callback O(1) : il lit le keycode et les flags, écrit dans une petite enum, renvoie `nil` pour avaler Tab/⇧Tab/Échap, et poste le traitement sur le fil principal. Aucun appel système bloquant dedans. Réactivation automatique si macOS coupe le tap (`tapDisabledByTimeout`).
- Course « ⌥ relâché avant que le tap soit actif » : à l'ouverture on lit `CGEventSource.flagsState(.combinedSessionState)` ; si ⌥ est déjà relâché, on bascule directement (⌥⇥ rapide = aller à la fenêtre suivante sans voir le panneau, comme ⌘⇥).

### Liste des fenêtres

- Un seul appel `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`, filtré sur le PID de `NSWorkspace.frontmostApplication` (lu en cache via la notification `didActivateApplication`, pas d'IPC au moment de l'appui). Titres via `kCGWindowName` (permission Enregistrement de l'écran).
- Deux variantes, mesurées par le banc, on garde la meilleure :
  - **(a) à la demande** : l'appel ci-dessus à chaque appui.
  - **(b) cache** : liste maintenue par `NSWorkspace` + `AXObserver` (création / destruction / titre / déplacement) sur l'app active, réconciliée par un appel CG en arrière-plan à l'ouverture. Plus complexe, et l'IPC AX tourne en continu : je ne la garde que si (a) rate l'objectif. Mon pronostic : (a) suffit, et c'est la plus fiable ; le banc tranchera.
- Si le p99 de CG s'avère trop haut : essayer `SLSCopyWindowsWithOptionsAndTags` filtré côté serveur sur la connexion de l'app, ou ne demander que les ID puis `CGWindowListCreateDescriptionFromArray` sur les seuls ID du PID.

### Affichage

- AppKit seul, pas de SwiftUI. Un `NSPanel` `.nonactivatingPanel`, niveau `.popUpMenu`, `NSVisualEffectView`, créé au lancement puis caché (`orderOut`). À l'appui : mise à jour du modèle, `reloadData`, `setFrame`, `orderFrontRegardless`. L'app active ne perd pas le focus pendant le choix.
- `NSTableView` en mode vue, cellules réutilisées : seules les lignes visibles existent, quelle que soit la taille de la liste. Hauteur plafonnée (≈ 12 lignes visibles, défilement au-delà, ligne sélectionnée gardée visible).
- Chaque ligne : icône de l'app (une seule image en cache par PID), titre (ou « Sans titre — n° »). Pas de vignette de fenêtre : une capture par fenêtre coûterait des ms et la permission ne sert ici qu'aux titres.
- 0 ou 1 fenêtre : rien n'est affiché (avec 1, ⌥⇥ ne fait rien ; à valider ci-dessous).
- Panneau sur l'écran qui contient la souris ou la fenêtre active (à valider).

### Bascule

1. `_SLPSSetFrontProcessWithOptions(&psn, wid, kCPSUserGenerated)` : app au premier plan avec cette fenêtre.
2. `SLPSPostEventRecordTo` ×2 (événements synthétiques 0x01/0x02 comme yabai) : la fenêtre devient clé.
3. `AXUIElementPerformAction(kAXRaiseAction)` sur l'élément AX de la fenêtre, pour la placer au-dessus des autres fenêtres de l'app.
4. Repli si un symbole manque : `AXRaise` + `NSRunningApplication.activate()`.

L'élément AX (étape 3) vient d'un `AXPrefetcher` sur une file en arrière-plan : à l'ouverture du panneau il lit `kAXWindowsAttribute` de l'app (délai `AXUIElementSetMessagingTimeout` 50 ms) et relie chaque élément à son `CGWindowID` avec `_AXUIElementGetWindow`. L'utilisateur met plus de 50 ms à choisir, donc c'est prêt à la bascule ; si l'app est figée, on fait 1 et 2 sans 3 au lieu d'attendre. Rien d'AX sur le fil principal.

### Symboles privés (documentés dans le README et l'en-tête)

| Symbole | Rôle | Si absent |
|---|---|---|
| `_SLPSSetFrontProcessWithOptions` (SkyLight) | activer l'app sur une fenêtre précise | `NSRunningApplication.activate` |
| `SLPSPostEventRecordTo` (SkyLight) | rendre la fenêtre clé | `AXRaise` seul |
| `_AXUIElementGetWindow` (HIServices) | élément AX → `CGWindowID` | appariement par titre + position |
| `GetProcessForPID` (Carbon, déprécié public) | PID → PSN pour les appels ci-dessus | — |

### Packaging (calqué sur swipekey)

`Olalatab.app` dans `~/Applications`, `LSUIElement` (pas d'icône de Dock), identifiant `io.github.olalatab`, LaunchAgent `RunAtLoad` + `KeepAlive`. Cibles `make install | restart | logs | test | uninstall | permissions | bench`. Signature avec le certificat « Apple Development » trouvé dans le trousseau (sinon ad hoc), reconstruction seulement si le binaire change, pour garder les autorisations. `make permissions` ouvre Accessibilité puis Enregistrement de l'écran et révèle l'app dans le Finder.

## 2. Protocole de mesure

### Instrumentation dans l'app

- `os_signpost` (sous-système `io.github.olalatab`, catégorie `PointsOfInterest`, visible dans Instruments) :
  - `open` : de l'appui (horodatage de l'événement clavier, `GetEventTime` de l'événement Carbon, pas l'heure d'entrée dans le callback) jusqu'au bloc de fin de la transaction Core Animation qui dessine le panneau (l'image est remise au WindowServer). Sous-intervalles : `list`, `layout`.
  - `switch` : du relâchement d'⌥ (horodatage de l'événement `flagsChanged`) jusqu'à ce que `CGWindowListCopyWindowInfo` montre la fenêtre cible en tête de pile (sondage court sur une file en arrière-plan, uniquement en mode banc).
- Les mêmes durées sont gardées en mémoire (tampon circulaire, 0 allocation) pour le banc.

Limite honnête : « première image » = transaction validée côté app. Le WindowServer compose ensuite à la prochaine trame (≤ 8,3 ms à 120 Hz). Je le documente sans l'ajouter aux chiffres, et je recoupe une fois avec Instruments (piste Display) pour estimer cet écart.

### Banc (`make bench`)

1. `bench/open-windows.sh N app` ouvre N fenêtres (TextEdit : AppleScript `make new document` ; Chrome : profil jetable `--user-data-dir` dans `$TMPDIR`, `make new window`), N ∈ {10, 100, 300}, puis met l'app au premier plan.
2. `olalatab --bench` est lancé hors LaunchAgent (même binaire signé, donc mêmes autorisations) : il poste lui-même de vrais événements ⌥⇥ via `CGEventPost` (chemin complet : hotkey Carbon → liste → panneau → tap → relâchement → bascule), 200 itérations avec 2 premières jetées, et écrit p50/p99/max de `open`, `list` et `switch` en JSON + tableau.
3. Un script agrège en tableau Markdown pour le README, puis ferme les fenêtres et le profil Chrome.
4. Variante (a) contre (b) : même banc, sélection par option `--source ondemand|cached`.

### Objectifs et autres mesures

| Mesure | Objectif | Comment |
|---|---|---|
| Panneau visible, 100 fenêtres | p50 < 8 ms, p99 < 16 ms | banc |
| Même chose à 10 et 300 | rapporté (300 : même objectif visé) | banc |
| CPU au repos | 0 % | `top -l 30 -pid` sur 30 s, et 0 réveil (`powermetrics` ou `ps -o` sur le temps CPU cumulé avant/après 60 s) |
| Mémoire | ≈ 15 Mo | `footprint` (phys_footprint) au repos et après 300 fenêtres |
| App figée | le sélecteur ne bloque jamais | processus de test (petite app AppKit à 3 fenêtres fournie dans `bench/`) mis en `SIGSTOP` : ⌥⇥ ouvert sur elle et sur une autre app, latence `open` inchangée, bascule ≤ 60 ms (délai AX) |

### Tests unitaires (`make test`, sans clavier)

Tri pour les 4 ordres (stabilité, égalités, accents), cycle Tab/⇧Tab (bouclage, liste de 2, sélection initiale), filtrage (autre PID, layer ≠ 0, alpha 0, taille nulle, fenêtres sans titre), décodage de la config (absente, valeur inconnue → erreur claire), percentiles.

## 3. Ordre de travail

1. Squelette SwiftPM + `OlalaCore` + tests (tri, cycle, filtre, config).
2. Hotkey + panneau + liste (a) + signposts ; première mesure manuelle.
3. Tap clavier + bascule SkyLight + prefetch AX.
4. Packaging (`make install` etc.).
5. Banc + app de test figée ; mesures 10/100/300, TextEdit et Chrome.
6. Variante (b) seulement si (a) rate l'objectif ; optimisations guidées par les mesures (C seulement si un chemin chaud le justifie).
7. README avec résultats, écarts expliqués.

Rien n'est commité ni poussé sans ton accord explicite ; pas de dépôt GitHub.

## 4. Points à valider

1. **⌥⇥ rapide** (appui-relâche) : bascule directement vers la fenêtre *suivante* dans l'ordre choisi, sans panneau. En ordre `creation`, « suivante » = celle créée après la fenêtre active (bouclage) ; en `recent`, c'est la précédente utilisée, comme ⌘⇥.
2. **Sélection initiale** quand le panneau s'ouvre : la fenêtre suivante (même règle).
3. **Une seule fenêtre** : rien ne se passe (pas de panneau, pas de bascule).
4. **Écran** : panneau centré sur l'écran de la fenêtre active.
5. **Clic souris** sur une ligne : bascule aussi (coût nul). Pas de recherche par frappe dans cette version.
