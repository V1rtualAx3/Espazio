<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/Brand/Logo-Horizontal-White.svg">
    <img src="Resources/Brand/Logo-Horizontal.svg" alt="Espazio" height="64">
  </picture>
</p>

<p align="center">
  <strong>La notch de votre Mac, enfin utile.</strong><br>
  Discrète au repos, contextuelle quand il le faut, décisive pour vos agents IA.
</p>

<p align="center">
  <a href="https://github.com/V1rtualAx3/Espazio/actions/workflows/ci.yml"><img src="https://github.com/V1rtualAx3/Espazio/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-000000?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M5-000000" alt="Apple Silicon">
</p>

---

Espazio transforme la découpe de l’écran des MacBook en un espace d’information natif : musique, prochaine
réunion, rappels, e-mails et — surtout — **les demandes d’autorisation de Claude Code et Codex**, que vous
acceptez ou refusez d’un clic sans quitter ce que vous faites.

100 % SwiftUI + AppKit · monochrome · local-first · aucune télémétrie · ni Electron ni WebView.

## Sommaire

- [Fonctionnalités](#fonctionnalités)
- [Installation](#installation)
- [Premiers pas](#premiers-pas)
- [Confidentialité et sécurité](#confidentialité-et-sécurité)
- [Développement](#développement)
- [Documentation](#documentation)
- [État du projet](#état-du-projet)

## Fonctionnalités

### Une notch à trois états

| État | Quand | Ce que vous voyez |
|---|---|---|
| **Repliée** | au repos | rien — ou une seule information continue de votre choix |
| **Aperçu** | un événement survient | une icône et une valeur de part et d’autre de la caméra |
| **Déployée** | survol, clic ou <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd> | lecture, agenda, rappels, agents IA, Gmail, Chat |

Notch virtuelle sur les écrans externes, écran principal ou tous les écrans, masquage optionnel en plein écran.

### Affichage continu

Choisissez ce que la notch garde à l’écran au repos : morceau en cours (même en pause), compte à rebours de
la prochaine réunion, agents IA actifs, e-mails non lus. Une seule information à la fois, par priorité.

### Centre d’activité IA

- **Claude Code** — via les hooks officiels : sessions, état, et demandes d’autorisation avec la commande
  complète ou le **diff** des fichiers modifiés. Deux boutons, et seulement deux : **Refuser** ou
  **Autoriser une fois**.
- **Codex** — sessions lancées depuis Espazio via `codex app-server` (approbations, questions) ; sessions CLI
  suivies en lecture seule.
- **Refus par défaut** : sans réponse, la demande est refusée. Aucune autorisation permanente n’est jamais créée.

### Médias et système

- Spotify et Musique : titre, pochette, progression, commandes — sans interrogation périodique.
- Volume, sortie audio, batterie, alimentation, Verr. Maj, Bluetooth (option).

### Productivité

- **Calendrier** : prochain événement, compte à rebours, bouton pour rejoindre Meet / Zoom / Teams.
- **Rappels et Google Tasks** : du jour et en retard, création et accomplissement.
- **iMessage** : nombre de messages non lus (badge de l’app Messages, sans lire leur contenu).
- **Gmail** : non-lus, aperçu, marquer comme lu, archiver ; badge discret dans la notch.
- **Google Chat** (Workspace) : conversations non lues et badge dans la notch ; on lit et répond dans Google Chat.
- **Actions rapides** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Espace</kbd> : recherche locale, et `+ appeler Paul demain 9h`
  pour créer un rappel.
- **Concentration** : modes Normal, Concentré, Silencieux ; interruptions limitées en réunion ou en plein écran.

## Installation

### DMG ou PKG

Téléchargez le DMG ou le PKG depuis les
[**Releases**](https://github.com/V1rtualAx3/Espazio/releases) : version stable (depuis `main`) ou
pré-version bêta (branches de travail).

- **DMG** — ouvrez-le et glissez Espazio dans *Applications*.
- **PKG** — installe Espazio dans `/Applications`.

> [!NOTE]
> Les builds de la CI ne sont pas notarisés. Au premier lancement : clic droit sur l’app ›
> **Ouvrir**, ou Réglages Système › Confidentialité et sécurité › **Ouvrir quand même**. Si macOS demande
> l’accès au Trousseau « app.espazio.google », choisissez **Toujours autoriser**
> ([pourquoi](docs/RELEASING.md#builds-signés)).

### Depuis les sources

Prérequis : macOS 14+, Xcode 16+.

```sh
git clone https://github.com/V1rtualAx3/Espazio.git
cd Espazio
scripts/package.sh                # build/Espazio.app, .dmg et .pkg
open build/Espazio.app
```

### Désinstaller

Quittez Espazio (barre des menus › Quitter), retirez les hooks dans Réglages › Agents IA, puis supprimez
`/Applications/Espazio.app` et `~/Library/Application Support/Espazio`.

## Premiers pas

Au premier lancement, un écran de bienvenue en 3 étapes vous guide (relançable depuis les Réglages).

1. Barre des menus › icône Espazio › **Réglages…**
2. **Général** — ouverture à la connexion, écrans, affichage continu, raccourcis, mises à jour.
3. **Modules** — autorisez Calendrier et Rappels, choisissez vos lecteurs.
4. **Agents IA** — installez les hooks Claude Code (une sauvegarde de votre configuration est conservée).
   → [Guide des intégrations](docs/INTEGRATIONS.md)
5. **Google** — créez votre client OAuth puis connectez-vous. → [Guide Google](docs/GOOGLE_OAUTH.md)

> [!TIP]
> Seules les sessions Claude Code lancées **sur ce Mac** apparaissent dans Espazio. Les sessions cloud
> (claude.ai/code) tournent sur une autre machine.

## Confidentialité et sécurité

- **Local-first** : seuls les services que vous connectez (Google) et les pochettes d’album sont contactés.
- **Aucune télémétrie**, aucun analytics.
- **Jetons dans le Trousseau**, jamais en clair ni dans les journaux.
- **Aucun port réseau ouvert** : communication avec les agents par socket Unix réservée à votre utilisateur ;
  écouteur `127.0.0.1` temporaire uniquement pendant la connexion Google.
- **Décisions d’agents** : refus par défaut, résolution unique, contrôle de session, journal d’audit sans
  contenu de commande.

Détails : [docs/SECURITY.md](docs/SECURITY.md). Signaler une vulnérabilité : [SECURITY.md](SECURITY.md).

## Développement

```sh
swift build && swift test         # macOS : paquet complet
scripts/swift-linux.sh test       # logique multiplateforme dans Docker (swift:6.1-noble)
open Package.swift                # Xcode
```

```
Sources/
├── EspazioCore            modèles, priorités, approbations, géométrie, réglages      (multiplateforme)
├── EspazioBridge          socket Unix locale et protocole versionné                  (multiplateforme)
├── AgentIntegrations      hooks Claude Code, Codex app-server                        (multiplateforme)
├── GoogleProvider         OAuth PKCE, Gmail, Chat, Agenda                            (multiplateforme)
├── EspazioHook            exécutable espazio-hook                                    (multiplateforme)
├── SystemServices         CoreAudio, IOKit, clavier, Bluetooth, lecteurs             (macOS)
├── ProductivityProviders  EventKit                                                   (macOS)
├── EspazioUI              design system et vues SwiftUI                              (macOS)
└── Espazio                application : fenêtres, écrans, raccourcis, coordinateur   (macOS)
```

La CI compile et teste la logique sous Linux, puis l’application complète sous macOS, et publie
`Espazio.app`, le `.dmg` et le `.pkg`.

Avant de contribuer, lisez [AGENTS.md](AGENTS.md) et le [cahier des charges](ESPAZIO_CAHIER_DES_CHARGES.md).

## Documentation

| Document | Contenu |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | cibles, flux, concurrence, choix techniques |
| [Design system](docs/DESIGN_SYSTEM.md) | jetons, états de la notch, composants, accessibilité |
| [Identité visuelle](docs/BRAND.md) | logo, icône, règles |
| [Intégrations IA](docs/INTEGRATIONS.md) | Claude Code, Codex, ChatGPT |
| [Google](docs/GOOGLE_OAUTH.md) | configuration OAuth, limites de Google Chat |
| [Mises à jour](docs/UPDATES.md) | Sparkle, clés, appcast, notarisation |
| [Versions](docs/RELEASING.md) | semantic-release, convention de commits, releases bêta et stables |
| [Sécurité](docs/SECURITY.md) | garanties et modèle de menace |
| [Performance](docs/PERFORMANCE.md) | choix de conception et protocole de mesure |
| [Checklist manuelle](docs/MANUAL_TEST_CHECKLIST.md) | validation sur Mac avant publication |
| [Journal](docs/DEVELOPMENT_LOG.md) | décisions, défauts corrigés, tests exécutés |

## État du projet

**Version 0.1 — préversion.** Les premiers tests manuels sur Mac sont en cours ; les mesures de performance
restent à réaliser.

| Domaine | État |
|---|---|
| Notch, multi-écrans, affichage continu, raccourcis configurables | ✅ |
| Volume, audio, batterie, Verr. Maj, Bluetooth | ✅ |
| Spotify, Musique | ✅ |
| Calendrier, Rappels | ✅ |
| Claude Code (hooks, autorisations, diffs) | ✅ |
| Codex app-server | ✅ · CLI indépendant en lecture seule |
| Gmail · Google Agenda | ✅ |
| Google Chat | ◐ comptes Workspace uniquement |
| Ouverture à la connexion · mises à jour Sparkle | ✅ · Sparkle à activer avec une clé de signature |
| Verr. Num | — non exposé par les claviers Mac |
| Modes Concentration de macOS | — pas d’API publique : mode manuel intégré |
| ChatGPT Desktop | ◐ état et ouverture uniquement |
