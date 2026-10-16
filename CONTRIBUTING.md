# Contribuer à Espazio

Merci de votre intérêt ! Espazio est sous licence [GNU GPL v3](LICENSE) : en proposant une contribution,
vous acceptez qu’elle soit distribuée sous cette licence.

## Avant de commencer

- Lisez [AGENTS.md](AGENTS.md) (règles permanentes : sécurité, confidentialité, performance) et le
  [cahier des charges](ESPAZIO_CAHIER_DES_CHARGES.md).
- Pour une fonctionnalité importante, ouvrez d’abord une issue pour en discuter.
- Une faille de sécurité ne se signale pas dans une issue : voir [SECURITY.md](SECURITY.md).

## Développement

```sh
swift build && swift test         # macOS : paquet complet
scripts/swift-linux.sh test       # logique multiplateforme dans Docker (swift:6.1-noble)
```

Une pull request doit passer la CI (commits, Linux, macOS). Indiquez ce que vous avez réellement testé,
et sur quel Mac le cas échéant.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/fr/), en anglais, vérifiés par commitlint :
`feat(ui): …`, `fix(google): …`, `docs: …`. Le type décide de la version publiée
(voir [docs/RELEASING.md](docs/RELEASING.md)). Un commit = une intention.

## Principes non négociables

- Aucune télémétrie, aucun secret dans le dépôt ni dans les journaux.
- Jamais d’autorisation automatique d’une action d’agent IA : refus par défaut.
- Seulement des API publiques et documentées d’Apple, de Google et des outils intégrés.
