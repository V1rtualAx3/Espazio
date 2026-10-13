# Architecture d’Espazio

## Vue d’ensemble

Espazio est **un seul paquet Swift** (`Package.swift`, Swift 6, macOS 14+). Xcode ouvre directement
`Package.swift` ; `scripts/build-app.sh` assemble et signe `Espazio.app`.

```
                 ┌──────────────────────── Espazio.app (processus unique) ───────────────────────┐
                 │                                                                               │
  NSScreen ──────┤  DisplayManager ──► NotchWindowController ×N ──► NotchRootView (SwiftUI)     │
                 │         ▲                    ▲ (présentation locale à l’écran)               │
                 │         │                    │                                               │
                 │  AppCoordinator (@MainActor) ── EspazioState (@Observable, état unique)       │
                 │    │  ActivityRouter (P0…P4, coalescence, expiration, focus)                  │
                 │    │  ApprovalCenter (actor, refus par défaut, idempotent)                    │
                 │    │                                                                          │
                 │    ├─ SystemServices : AudioMonitor (CoreAudio), PowerMonitor (IOKit),        │
                 │    │                   KeyboardMonitor, BluetoothMonitor, SpotifyProvider     │
                 │    ├─ ProductivityProviders : EventKitProvider (Calendrier, Rappels)          │
                 │    ├─ GoogleController ─► GoogleProvider (OAuth PKCE, Gmail, Chat, Agenda)    │
                 │    └─ Agents : BridgeServer (socket Unix) ◄── espazio-hook ◄── Claude Code     │
                 │                CodexAppServerClient ◄─stdio─► `codex app-server` (à la demande)│
                 └───────────────────────────────────────────────────────────────────────────────┘
```

Processus additionnels :

| Processus | Quand | Justification |
|---|---|---|
| `espazio-hook` | lancé par Claude Code à chaque hook (vie de quelques ms, ou durée d’une décision) | Les hooks Claude Code sont des commandes ; c’est le mécanisme documenté. Binaire minimal, aucune résidence. |
| `codex app-server` | uniquement quand l’utilisateur lance une session Codex depuis Espazio ; arrêté après 15 min d’inactivité | Seul moyen officiel de piloter Codex (approbations, questions). |

Aucun port réseau n’est ouvert, sauf un écouteur **127.0.0.1 éphémère** pendant la connexion Google
(redirection OAuth loopback), fermé dès le retour ou après 5 min.

## Cibles

| Cible | Plateforme | Rôle |
|---|---|---|
| `EspazioCore` | multiplateforme | Modèles, `ActivityRouter`, `FocusPolicy`, `ApprovalCenter`, `AgentSessionStore`, géométrie de notch, `DisplayPlanner`, réglages, recherche des actions rapides, cache borné, backoff, token bucket, `Redactor`, `AuditLog`. |
| `EspazioBridge` | multiplateforme | Socket Unix, protocole versionné (`BridgeRequest`/`BridgeReply`, trames bornées à 2 Mio), serveur et client. |
| `AgentIntegrations` | multiplateforme | Hooks Claude Code (décodage, mapping, sortie de décision, installateur), client Codex app-server, intégration `notify` Codex. |
| `GoogleProvider` | multiplateforme | OAuth 2.0 PKCE + loopback, session de jetons, API Gmail/Chat/Agenda, classification d’erreurs. |
| `espazio-hook` | multiplateforme | Assistant de hook (stdin → socket → stdout). |
| `SystemServices` | macOS | CoreAudio, IOKit, NSEvent, IOBluetooth, Spotify. |
| `ProductivityProviders` | macOS | EventKit. |
| `EspazioUI` | macOS | Design system, vues SwiftUI, `EspazioState`, protocoles d’actions, previews. |
| `Espazio` | macOS | Cycle de vie, fenêtres, multi-écrans, raccourcis, Keychain, coordinateur. |

Règle : **toute logique testable vit dans une cible multiplateforme** (compilée et testée sous Linux en CI) ;
les cibles macOS sont de fines couches d’adaptation.

## Flux principaux

### Activités et notch

1. Un module produit un événement (volume, nouvel e-mail, demande d’agent…).
2. Il est converti en `ActivityItem` (priorité, clé de coalescence, expiration) et posté dans `ActivityRouter`.
3. `AppCoordinator.publish()` calcule le *peek* (élément le plus prioritaire autorisé par la `FocusPolicy`),
   met à jour `EspazioState` et programme **un seul** `Timer` pour la prochaine expiration.
4. Chaque `NotchWindowController` (un par écran hébergé) passe en `peek`/`collapsed` ; l’état `expanded` est
   local à l’écran survolé/cliqué. Le contenu étant partagé, une action faite sur un écran est visible partout
   et exécutée une seule fois.

### Décision d’agent (Claude Code)

```
Claude Code ─PermissionRequest (JSON stdin)─► espazio-hook ─trame─► BridgeServer
   ▲                                                                   │ handleClaudeHook
   │                                                                   ▼
   └── stdout {"hookSpecificOutput":{"decision":{"behavior":"allow"|"deny"}}} ◄── ApprovalCenter.submit
                                                                       ▲
                                    clic « Autoriser une fois » / « Refuser » (ApprovalCard)
```

* Délai écoulé → `deny(timeout)`. Déconnexion du hook → la tâche est annulée → `deny(disconnected)`.
* Espazio fermé ou bridge injoignable → le hook n’écrit rien → Claude Code affiche **sa propre** demande.
* Aucune portée « toujours autoriser » n’est jamais envoyée (`updatedPermissions` absent).

### Codex

Sessions lancées depuis Espazio : `codex app-server` (JSON par ligne). Les requêtes serveur
`item/commandExecution/requestApproval`, `item/fileChange/requestApproval` et `item/tool/requestUserInput`
passent par le même `ApprovalCenter`. Toute requête serveur inconnue reçoit une erreur (-32601) pour ne
jamais bloquer le serveur. Sessions CLI indépendantes : `notify` → `espazio-hook codex-notify` →
session **en lecture seule** (jamais présentée comme pilotable).

### Google

`GoogleController` : boucle de synchronisation unique (partagée par tous les écrans), intervalle
configurable (60 s–60 min, 3 min par défaut), backoff exponentiel avec gigue, `Retry-After` respecté,
token bucket, pause pendant la veille. Gmail : un seul appel `history` quand rien n’a changé.

## Concurrence

* UI et coordination : `@MainActor`.
* `ApprovalCenter`, `GoogleAuthSession`, `GmailMonitor`, `CodexAppServerClient` : `actor`.
* Bridge : sources Dispatch (aucun thread parqué au repos), handler `async` annulé si le pair se déconnecte.
* Mode Swift 6 strict sur toutes les cibles.

## Choix et alternatives écartées

* **SwiftPM plutôt qu’un `.xcodeproj` généré** : diff lisible, compilable en CI Linux pour la logique ;
  Xcode ouvre le paquet. L’app est assemblée par script (Info.plist, entitlements, signature).
* **AppleScript + notifications distribuées pour Spotify** plutôt que MediaRemote (API privée).
* **Socket Unix** plutôt que XPC : le client est un exécutable lancé par Claude Code, pas un service lancé
  par launchd ; XPC Mach nécessiterait un LaunchAgent permanent.
* **Fenêtre redimensionnée par état** plutôt qu’une grande fenêtre transparente permanente : ne masque pas
  la barre des menus, cliquable uniquement là où la notch est visible.
