# Mises à jour automatiques (Sparkle 2)

Espazio intègre [Sparkle 2](https://sparkle-project.org) (seule dépendance tierce, macOS uniquement).
Le module de mise à jour **ne démarre que si le build contient une clé publique EdDSA** (`SUPublicEDKey`,
écrite par la CI dans `Resources/Info.plist` au moment de la release) : les builds de développement ne
contactent jamais le réseau pour les mises à jour.

## Activer les mises à jour (une fois)

Sur votre Mac, depuis le dépôt :

```sh
scripts/create-sparkle-key.sh
gh secret set SPARKLE_ED_PRIVATE_KEY --repo V1rtualAx3/Espazio < ~/.espazio-signing/sparkle-private-key.txt
```

La clé privée (Ed25519, générée avec CryptoKit) reste dans `~/.espazio-signing/` et dans le secret
GitHub, jamais dans le dépôt. **Gardez-en une copie** : avec une autre clé, les copies installées
refuseraient les mises à jour (il faudrait réinstaller à la main).

## Publication (automatique)

À chaque version publiée par semantic-release, le job de release :

1. écrit la clé publique dérivée du secret dans `SUPublicEDKey` (`scripts/release-build.sh`) ;
2. construit, signe et teste le DMG, crée la release GitHub ;
3. signe le DMG (EdDSA) et l’ajoute à l’appcast (`scripts/update-appcast.sh`, `scripts/appcast.py`).

L’appcast vit sur la branche `appcast` et est servi à l’adresse de `SUFeedURL` :
`https://raw.githubusercontent.com/V1rtualAx3/Espazio/appcast/appcast.xml`.

- Versions stables (`main`) : éléments sans canal, proposés à tout le monde. Une version stable retire
  les bêtas de l’appcast (leurs releases sont supprimées).
- Bêtas (branches de travail) : canal `beta`, proposées seulement si « Recevoir les versions bêta » est
  coché.
- Les 10 versions les plus récentes sont conservées.

Sans le secret `SPARKLE_ED_PRIVATE_KEY`, le build n’a pas de clé et l’appcast n’est pas modifié.

## Comportement

- Sparkle demande à l’utilisateur s’il souhaite vérifier automatiquement (à partir du 2ᵉ lancement).
- Réglages › Général › Mises à jour : vérification automatique, « Recevoir les versions bêta » et
  « Rechercher maintenant ».
- `SUEnableSystemProfiling` est désactivé : aucune information système n’est envoyée.
- Les archives sont vérifiées par signature EdDSA et par la signature de code de l’app.
- Sparkle retire la quarantaine de la mise à jour : pas d’alerte Gatekeeper « app non vérifiée » pour
  une version installée depuis Espazio. Sans Developer ID, macOS redemande en revanche l’accès au
  Trousseau (une fois) après chaque mise à jour.
