# Versions et releases

Les versions sont calculées et publiées automatiquement par
[semantic-release](https://semantic-release.gitbook.io) (job `Release` de `.github/workflows/ci.yml`,
configuration `release.config.js`), après le succès des jobs Linux et macOS, sur chaque **push**.

| Branche | Version publiée | Exemple |
|---|---|---|
| `main` | release stable, tag `vX.Y.Z` | `v1.2.0` |
| `claude/*`, `feature/*`, `feat/*`, `fix/*` | pré-version bêta (release GitHub marquée *Pre-release*), incrémentée jusqu’à la release suivante | `v1.3.0-beta.1`, `v1.3.0-beta.2` |

Sur `main` uniquement, les releases sont aussi publiées dans **GitHub Packages** (onglet *Packages* du dépôt)
sous forme d’artefact OCI `ghcr.io/v1rtualax3/espazio:<version>` (+ `latest`) contenant le DMG et le PKG
(`scripts/publish-package.sh`, outil [oras](https://oras.land)). Téléchargement :
`oras pull ghcr.io/v1rtualax3/espazio:latest`.

Sur `main` uniquement : `CHANGELOG.md` est mis à jour et committé (`chore(release): X.Y.Z [skip ci]`), puis
les pré-versions bêta (releases et tags) sont supprimées, la version stable les remplaçant. Les branches de
travail ne committent jamais de changelog : les notes de chaque bêta sont dans sa release GitHub.

Chaque release GitHub contient en pièces jointes le **DMG** et le **PKG** construits pour cette version
(`scripts/release-build.sh` : version injectée dans `Info.plist` du workspace CI, puis
`scripts/package.sh` et test de lancement `scripts/smoke-test.sh`). Les notes de version sont générées
depuis les commits.

> Toutes les branches de travail publient sur le même canal `beta` : une bêta compte comme précédente pour
> toute branche qui contient son commit, et les jobs de release s’exécutent un par un. Deux branches qui
> divergent pourraient néanmoins viser le même numéro : une seule branche de travail à la fois devrait
> publier des bêtas.

## Convention de commits (obligatoire)

Le numéro de version découle des messages de commit ([Conventional Commits](https://www.conventionalcommits.org/fr/)) :

| Préfixe | Effet |
|---|---|
| `feat: …` | version mineure (1.**2**.0) |
| `fix: …`, `perf: …`, `refactor: …`, `build: …` | correctif (1.2.**1**) |
| `feat!: …` ou pied `BREAKING CHANGE:` | version majeure (**2**.0.0) |
| `docs:`, `test:`, `ci:`, `chore:`, `style:` | pas de nouvelle version |

Un push sans commit publiable ne crée pas de version. Le job CI `Commits` (commitlint,
`commitlint.config.js`) refuse tout message non conforme ; les notes de version regroupent les commits par
sections (Fonctionnalités, Corrections, Performance…).

## Prérequis du dépôt

- Réglages › Actions › General › *Workflow permissions* : « Read and write permissions » (ou laisser les
  permissions par job : le job `Release` demande `contents: write`).
- Les tags `v*` ne doivent pas être protégés contre le `GITHUB_TOKEN`.
- Si `main` est protégée, autoriser GitHub Actions à y pousser le commit de changelog (ou utiliser un jeton
  dédié), sinon l’étape `@semantic-release/git` échoue.

## Builds signés

Sans configuration, les builds de la CI sont signés **ad hoc** : leur identité change à chaque build, et
macOS redemande l’accès au Trousseau (jetons Google) après chaque mise à jour.

**Identité auto-signée stable (recommandé, gratuit).** Une seule fois, sur un Mac :

```sh
scripts/create-signing-identity.sh
gh secret set MACOS_SIGNING_P12 < ~/.espazio-signing/espazio-signing.p12.b64
gh secret set MACOS_SIGNING_PASSWORD < ~/.espazio-signing/password.txt
```

La CI importe ce certificat (`scripts/import-signing-identity.sh`) et signe toutes les versions avec : le
Trousseau ne pose plus la question qu’une fois (« Toujours autoriser »). Gatekeeper affiche toujours
l’app comme provenant d’un développeur non identifié. Conservez `~/.espazio-signing` : un nouveau
certificat redemande l’accès une fois.

**Developer ID (distribution publique).** Pour des binaires notarisés, passer un certificat
« Developer ID Application » dans `CODESIGN_IDENTITY` (runtime renforcé activé automatiquement) et
`INSTALLER_IDENTITY` (voir [UPDATES.md](UPDATES.md)).
