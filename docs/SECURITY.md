# Sécurité et confidentialité

## Principes

* Local-first. Seuls appels réseau : API Google choisies par l’utilisateur, pochettes Spotify (HTTPS).
* Aucune télémétrie, aucun analytics.
* Aucun secret dans le code ni dans le dépôt. Le Client ID OAuth est saisi par l’utilisateur ; le
  « client secret » des clients de bureau Google (documenté comme non confidentiel) est stocké dans le
  Trousseau.
* Jetons OAuth dans le Trousseau (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), jamais dans
  `UserDefaults` ni dans les journaux.

## Décisions d’agents IA

| Garantie | Mise en œuvre | Test |
|---|---|---|
| Refus par défaut | `ApprovalCenter` : délai → `deny(timeout)`, annulation → `deny(cancelled)`, déconnexion → `deny(disconnected)` | `ApprovalCenterTests.testTimeoutDenies`, `testDisconnectCancelsSessionRequests` |
| Aucune validation implicite | Seul un clic sur « Autoriser une fois » produit `.allowOnce` ; aucun raccourci clavier | revue `ApprovalCard` |
| Pas d’autorisation persistante | La sortie de hook ne contient jamais `updatedPermissions` ; Codex reçoit `accept`, jamais `acceptForSession` | `ClaudeHooksTests.testPermissionOutputs`, `CodexTests.testDecisionMapping` |
| Résolution unique / idempotente | Première résolution gagnante, les suivantes renvoient `.alreadyResolved` ; re-soumission = même décision | `testDuplicateResolutionIsIdempotent`, `testDuplicateSubmissionSharesTheSameDecision` |
| Contrôle de session | La résolution doit porter l’identifiant de session de la demande ; un identifiant réclamé par une autre session est refusé | `testWrongSessionCannotResolve`, `testSameIDFromAnotherSessionIsRefused` |
| Cohérence du type de réponse | Pas de réponse texte pour une commande, pas d’autorisation pour une question | `testResponseKindMustMatchRequestKind` |
| File bornée | 64 demandes en attente max, au-delà refus | `testPendingCapacityDeniesOverflow` |
| Contexte affiché | Fournisseur, projet, session, outil, commande complète (jusqu’à 16 Kio, sinon signalée tronquée), répertoire, raison | `testHugeCommandIsBoundedAndFlagged` |
| Session non pilotable | `AgentControlLevel.observeOnly` affiché « Lecture seule », jamais de boutons de décision | `AgentSessionStore` (pas de rétrogradation) |
| Journal d’audit | `~/Library/Application Support/Espazio/audit.log` (0600, rotation 512 Kio) : identifiants et issue uniquement, jamais la commande | `testAuditContainsNoCommandText`, `testAuditLogWritesNoSecretsAndRotates` |

Outils Claude Code nécessitant l’interface de Claude (`AskUserQuestion`, `ExitPlanMode`) : Espazio ne
répond pas (passage à Claude Code).

## Bridge local

* Socket Unix `~/Library/Application Support/Espazio/run/bridge.sock`, dossier 0700, socket 0600
  (création sous `umask 0177`, pas de fenêtre de course).
* Chaque pair doit appartenir au même utilisateur (`getpeereid`), sinon connexion fermée.
* Trames versionnées, taille max 2 Mio vérifiée **avant** allocation, délai de lecture 5 s, 32 connexions
  simultanées max.
* Si une autre instance écoute déjà, Espazio refuse de voler la socket ; un fichier orphelin est remplacé.
* Pas de port réseau.

Limite connue : tout processus de l’utilisateur peut se connecter au bridge et soumettre une demande
(il ne peut pas en résoudre : la résolution n’est possible que depuis l’interface). Un processus malveillant
déjà exécuté sous l’utilisateur dispose de toute façon de ses droits.

## Google OAuth

* Authorization Code + PKCE S256, `state` aléatoire vérifié, redirection loopback `127.0.0.1:<port éphémère>`
  ouverte seulement pendant la connexion (5 min max), navigateur système (pas de WebView).
* Consentement progressif (`include_granted_scopes=true`) : `gmail.readonly` d’abord, `gmail.modify`
  demandé au premier « marquer lu / archiver », `chat.messages.create` au premier envoi.
* « Déconnecter » révoque le jeton chez Google puis supprime le Trousseau.
* `invalid_grant` → jetons supprimés, état « Reconnexion nécessaire ».

## Journaux

`Redactor` masque jetons Bearer, `ya29.`, refresh tokens Google, clés `sk-`, jetons GitHub/Slack, clés AWS
et paires `token=…`. Les messages d’erreur Google affichés sont tronqués et expurgés.

## Signature, notarisation, permissions

* Hardened Runtime, entitlements : `automation.apple-events` (Spotify), `personal-information.calendars`
  (EventKit), `device.bluetooth`. Pas de sandbox (lecture/écriture de `~/.claude/settings.json`,
  `~/.codex/config.toml`, lancement de `codex`) → distribution hors Mac App Store.
* `scripts/build-app.sh` signe ad hoc par défaut ; pour distribuer : `CODESIGN_IDENTITY="Developer ID
  Application: …"` puis `xcrun notarytool submit build/Espazio.zip --wait` et `xcrun stapler staple`.
* Permissions demandées uniquement sur action : Calendrier, Rappels, Automatisation (Spotify), Bluetooth
  (option désactivée par défaut). Accessibilité recommandée seulement pour Verr. Maj global.
