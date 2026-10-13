# Espazio

Utilitaire de notch pour macOS : discret au repos, contextuel quand il le faut, décisif pour vos agents IA.
SwiftUI + AppKit natifs, monochrome, local-first, sans Electron ni WebView.

> **Statut : V1 « non vérifiée sur Mac ».** Le code a été écrit et testé dans un environnement Linux
> (logique) et compilé/testé par la CI GitHub Actions macOS. L’interface n’a pas encore été lancée sur un
> Mac réel : suivez [la checklist manuelle](docs/MANUAL_TEST_CHECKLIST.md).

## Fonctionnalités

| Domaine | Fonction | Statut |
|---|---|---|
| Notch | États repliée / aperçu / déployée, survol, clic, raccourci, Échap | Opérationnelle* |
| Notch | Notch virtuelle sur écran externe, écran principal ou tous les écrans | Opérationnelle* |
| Notch | Écran « actif » (écran sous le pointeur) | Partielle — approximation sans permission Accessibilité |
| Notch | Masquage en plein écran | Partielle — détection heuristique (fenêtre couvrant l’écran) |
| Système | Volume, sortie audio (CoreAudio) | Opérationnelle* (le HUD système reste affiché) |
| Système | Batterie, alimentation (IOKit) | Opérationnelle* |
| Système | Verr. Maj | Partielle — global peut nécessiter Accessibilité |
| Système | Verr. Num | Indisponible — non exposé par les claviers Mac (affiché tel quel) |
| Système | Bluetooth (option) | Opérationnelle* |
| Médias | Spotify : titre, artiste, pochette, contrôles, progression | Opérationnelle* (notifications + AppleScript) |
| Médias | Autres lecteurs, MediaRemote privé | Indisponible (volontairement) |
| Apple | Calendrier : prochain événement, compte à rebours, lien de réunion, ouverture | Opérationnelle* |
| Apple | Rappels : du jour / en retard, création, accomplissement | Opérationnelle* |
| IA | Claude Code : sessions, état, autorisations « Refuser / Autoriser une fois » | Opérationnelle* (hooks documentés) |
| IA | Claude Code : questions (`AskUserQuestion`) | Indisponible — laissées à Claude Code |
| IA | Codex : sessions lancées depuis Espazio (app-server), approbations, questions | Opérationnelle* (questions : API expérimentale) |
| IA | Codex CLI indépendant | Partielle — lecture seule via `notify` (fin de tour) |
| IA | ChatGPT Desktop | Expérimentale — ouvert/fermé + ouverture |
| Google | Gmail : non-lus, aperçu, ouverture, marquer lu, archiver | Opérationnelle* |
| Google | Google Chat : espaces, messages, réponse | Partielle — comptes Workspace avec app Chat configurée |
| Google | Google Agenda direct + dédoublonnage EventKit | Opérationnelle* |
| Focus | Modes Normal / Concentré / Silencieux, réunion & plein écran | Opérationnelle* |
| Focus | Synchronisation avec les modes Concentration macOS | Indisponible — pas d’API publique adaptée |
| Actions rapides | Palette ⌃⌥Espace, recherche locale, « + rappel demain 9h » | Opérationnelle* |
| Diagnostic | Mémoire, CPU, compteurs (à la demande) | Opérationnelle* |

\* Compilée et couverte par des tests automatisés ; comportement réel à confirmer avec la checklist manuelle.

## Installation (depuis les sources)

Prérequis : macOS 14 ou plus récent, Xcode 16 ou plus récent (Swift 6).

```sh
git clone https://github.com/V1rtualAx3/Espazio.git && cd Espazio
scripts/build-app.sh            # → build/Espazio.app (signature ad hoc)
cp -R build/Espazio.app /Applications/
open /Applications/Espazio.app
```

La CI publie aussi `Espazio.app` (artefact *Espazio-app* de chaque exécution, signature ad hoc :
clic droit › Ouvrir au premier lancement).

Distribution signée : `CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh`, puis
`xcrun notarytool submit build/Espazio.zip --keychain-profile … --wait` et
`xcrun stapler staple build/Espazio.app`.

## Premiers pas

1. Barre des menus › Espazio › Réglages.
2. **Modules** : autoriser Calendrier et Rappels.
3. **Agents IA** : installer les hooks Claude Code ; optionnellement le suivi Codex CLI. Détails :
   [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).
4. **Google** : créer un client OAuth puis se connecter. Guide : [docs/GOOGLE_OAUTH.md](docs/GOOGLE_OAUTH.md).

Raccourcis par défaut : ⌃⌥N (notch), ⌃⌥Espace (Actions rapides).

## Développement

```sh
swift build && swift test                 # sur Mac : tout le paquet
scripts/swift-linux.sh test               # logique multiplateforme dans Docker (swift:6.1-noble)
open Package.swift                        # Xcode
```

Documentation : [Architecture](docs/ARCHITECTURE.md) · [Design system](docs/DESIGN_SYSTEM.md) ·
[Sécurité](docs/SECURITY.md) · [Performance](docs/PERFORMANCE.md) ·
[Journal de développement](docs/DEVELOPMENT_LOG.md) · [Cahier des charges](ESPAZIO_CAHIER_DES_CHARGES.md) ·
[Règles des agents](AGENTS.md).

## Confidentialité

Aucune télémétrie. Jetons dans le Trousseau. Pas de port réseau ouvert (hors écouteur 127.0.0.1 temporaire
pendant la connexion Google). Les décisions d’agents sont refusées par défaut. Voir
[docs/SECURITY.md](docs/SECURITY.md).
