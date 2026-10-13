# Journal de développement

## 2026-10-13 — V1 (jalons M0 à M6, M7 partiel)

### Environnement

* Claude Code Cloud, conteneur Linux x86_64 sans Xcode. Toolchain Swift 6.1.3 obtenue via l’image Docker
  officielle `swift:6.1-noble` (`scripts/swift-linux.sh`) : compilation et tests des cibles multiplateformes.
* CI GitHub Actions : job Linux (logique) + job `macos-15` (compilation complète, tests, assemblage de
  `Espazio.app`). Les cibles AppKit/SwiftUI n’ont été compilées **que** par cette CI.
* **Aucun test manuel sur Mac** : l’interface n’a jamais été affichée. Statut : « non vérifié sur Mac ».

### Documentation revalidée au démarrage

* Hooks Claude Code (code.claude.com/docs/en/hooks) : format `PermissionRequest`
  (`hookSpecificOutput.decision.behavior`), délai par défaut 600 s des hooks `command`, liste des
  `notification_type`. Point non confirmé : comportement exact d’un `PermissionRequest` sans décision.
* Codex app-server : developers.openai.com inaccessible depuis le conteneur ; protocole relu dans le code
  source `openai/codex` (`app-server-protocol`, commit du 13/10/2026) : JSON par ligne sans `jsonrpc`,
  `initialize`/`initialized`, `thread/start`, `turn/start`, approbations `item/*/requestApproval` avec
  `decision` `accept|acceptForSession|decline|cancel`, `item/tool/requestUserInput` (expérimental).
  `thread/list` n’observe pas les sessions CLI vivantes d’un autre processus → `notify` pour les CLI.
* EventKit (`requestFullAccessToEvents/Reminders`, macOS 14), Gmail (`history`, `labels/INBOX`,
  `messages.modify`), Google Chat (`spaces`, `spaces.messages`), OAuth « native app » loopback + PKCE.

### Décisions

| Décision | Justification |
|---|---|
| Paquet SwiftPM unique, app assemblée par script | Compilable/testable en Linux pour la logique ; diff lisible ; Xcode ouvre le paquet. |
| macOS 14 minimum | `@Observable`, EventKit full access, `onKeyPress` ; couvre tous les Mac M2–M5. |
| Logique dans des cibles multiplateformes | 120+ tests exécutables hors Mac (sécurité des approbations, bridge, OAuth…). |
| Socket Unix plutôt que XPC | Le client est l’exécutable de hook lancé par Claude Code, pas un service launchd. |
| Assistant `espazio-hook` sans décision propre | Aucune approbation possible hors interface ; repli = comportement natif de Claude Code. |
| Fenêtre redimensionnée par état | Ne bloque jamais la barre des menus ; pas de grande fenêtre transparente permanente. |
| Notch toujours noire | Se fond dans la découpe physique ; réglages/palette suivent clair/sombre. |
| SHA-256 interne pour PKCE | CryptoKit indisponible sous Linux ; vérifié avec vecteurs NIST + RFC 7636 ; ne manipule aucun secret durable. |
| Spotify par notifications + AppleScript | API documentées, pas de polling, pas d’API privée MediaRemote. |
| Une PR unique, commits par jalon | Les jalons ont été produits dans la même session et dépendent les uns des autres ; des PR empilées n’auraient pas compilé isolément. |

### Défauts trouvés et corrigés pendant le développement

* Fuzzy-search trop permissive (« esp » correspondait à « Revue de sprint ») → sous-séquence ancrée sur un
  début de mot.
* Flux `codex app-server` tronqué : la fin du processus terminait le flux avant la dernière ligne ; puis
  blocage car le parent gardait l’extrémité d’écriture du pipe → fermeture des extrémités côté parent, fin
  de flux sur EOF.
* Session Codex pilotable rétrogradée en « lecture seule » par un événement `notify` → le niveau de contrôle
  n’est jamais rétrogradé.
* Fermeture du descripteur de connexion du bridge avant annulation de la source Dispatch (risque de
  réutilisation de fd) → fermeture dans le cancel handler.
* `fetchReminders` : closure inférée `@MainActor` appelée sur la file d’EventKit (piège Swift 6 = crash à
  l’exécution) → closure `@Sendable` explicite.
* Compilation macOS : imports CoreGraphics, constantes CoreAudio non typées, accès `mach_task_self_`
  (remplacé par `proc_pid_rusage`).

### Revue indépendante (sous-agent, lecture adversariale du code critique)

Aucun chemin d’autorisation sans clic trouvé. 8 défauts relevés, tous corrigés et testés quand c’était
testable : SIGPIPE pouvant tuer l’app ; course écriture/fermeture sur le bridge ; rejeu possible d’une
autorisation Codex après redémarrage d’app-server (ids JSON-RPC réutilisés) ; installateurs pouvant réécrire
un fichier illisible, casser un lien symbolique ou écraser la sauvegarde d’origine ; demande orpheline si le
hook part avant l’enregistrement ; réentrance du rafraîchissement OAuth ; callbacks loopback forgés ;
umask non restauré en cas d’erreur.

### Tests réellement exécutés

* Linux (Docker swift:6.1-noble, Swift 6.1.3) : `swift test` → 108 tests, 0 échec.
* macOS (CI `macos-15`, Xcode 16.4, Swift 6.1.2) : `swift build`, `swift test` → 114 tests (108 + 6 tests de
  rendu SwiftUI hors écran), `scripts/build-app.sh` → `Espazio.app` signée ad hoc, `codesign --verify` OK.
* Manuel sur Mac : **aucun**.

### Risques et limites connus

* Comportement réel des fenêtres (niveau, survol, espaces, plein écran) non observé.
* Verr. Maj global peut exiger la permission Accessibilité.
* Le HUD de volume système reste affiché (le masquer exigerait des API privées).
* « Écran actif » = écran sous le pointeur.
* Google Chat dépend de la configuration Workspace.
* Mesures de performance non réalisées.

## Identité visuelle : logo et icône d’app

* Symbole dérivé de `NotchShape` (port exact de la géométrie) avec le contenu de l’état peek ; logotype Inter
  Display SemiBold vectorisé ; icône d’app macOS (variantes claire et sombre). Détails : `docs/BRAND.md`.
* Générateurs : `scripts/generate-brand.py` (SVG), `scripts/render-iconset.js` (PNG de l’iconset).
* `build-app.sh` produit `AppIcon.icns` via `iconutil` ; `Info.plist` déclare `CFBundleIconFile`.
* Vérifié : rendu des SVG et PNG dans Chromium (Linux). Affichage de l’icône dans le Finder et le Dock :
  **non vérifié sur Mac**.
* Icône d’app revue (retour : peu reconnaissable dans le Dock) : trois notches emboîtées sur fond noir,
  choisie parmi plusieurs pistes comparées à 16–200 px ; variante claire `AppIcon-Light.svg`.
