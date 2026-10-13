# CLAUDE.md

Instructions pour Claude Code dans ce dépôt. Lire d’abord **[AGENTS.md](AGENTS.md)** (règles permanentes)
puis **[ESPAZIO_CAHIER_DES_CHARGES.md](ESPAZIO_CAHIER_DES_CHARGES.md)** (source de vérité produit).

## Commits : Conventional Commits (obligatoire)

Chaque commit suit [Conventional Commits](https://www.conventionalcommits.org/fr/) — vérifié par
`commitlint` en CI et utilisé par semantic-release pour calculer les versions :

```
<type>(<portée optionnelle>): <résumé à l’impératif, en anglais, ≤ 100 caractères>

<corps : pourquoi, et ce qui change>
```

| Type | Usage | Version |
|---|---|---|
| `feat` | nouvelle fonctionnalité | mineure |
| `fix` | correction de bug | correctif |
| `perf`, `refactor`, `build` | performance, restructuration, build / packaging | correctif |
| `docs`, `test`, `ci`, `chore`, `style` | documentation, tests, CI, maintenance | aucune |
| `feat!` / pied `BREAKING CHANGE:` | rupture de compatibilité | majeure |

Portées usuelles : `core`, `agents`, `google`, `ui`, `notch`, `app`, `brand`, `build`, `security`.
Un commit = une intention ; ne pas mélanger `feat` et `fix` sans rapport.

## Versions

- Branches de travail (`claude/*`, `feature/*`, `feat/*`, `fix/*`) → pré-versions `X.Y.Z-beta.N` publiées
  sur GitHub avec DMG et PKG.
- `main` → release `vX.Y.Z`, `CHANGELOG.md` mis à jour, bêtas supprimées.
- Détails : [docs/RELEASING.md](docs/RELEASING.md). Ne jamais créer de tag ni de release à la main.

## Vérifications avant de pousser

```sh
scripts/swift-linux.sh test     # logique multiplateforme (Docker swift:6.1-noble)
```

La CI macOS compile l’app, exécute les tests, assemble DMG/PKG et lance l’app 10 s (`scripts/smoke-test.sh`).
Ne jamais annoncer un résultat macOS sans l’avoir vu en CI ou sur un Mac.
