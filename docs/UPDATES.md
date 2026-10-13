# Mises à jour automatiques (Sparkle 2)

Espazio intègre [Sparkle 2](https://sparkle-project.org) (seule dépendance tierce, macOS uniquement).
Le module de mise à jour **ne démarre que si le build contient une clé publique EdDSA** (`SUPublicEDKey`
dans `Resources/Info.plist`) : les builds de développement et ad hoc ne contactent jamais le réseau pour les
mises à jour.

## Activer les mises à jour (une fois)

1. Récupérer les outils Sparkle (archive de la release Sparkle correspondant à `Package.swift`, dossier `bin/`).
2. Générer la paire de clés — la clé privée reste dans **votre** Trousseau, jamais dans le dépôt :

   ```sh
   ./bin/generate_keys            # affiche la clé publique
   ```

3. Copier la clé publique dans `Resources/Info.plist` → `SUPublicEDKey`.
4. `SUFeedURL` pointe sur
   `https://github.com/V1rtualAx3/Espazio/releases/latest/download/appcast.xml` : l’appcast est publié comme
   pièce jointe de chaque release GitHub.

## Publier une version

```sh
# 1. Incrémenter CFBundleShortVersionString et CFBundleVersion dans Resources/Info.plist
# 2. Construire et signer (Developer ID requis pour une distribution publique)
CODESIGN_IDENTITY="Developer ID Application: …" INSTALLER_IDENTITY="Developer ID Installer: …" scripts/package.sh
# 3. Notariser
xcrun notarytool submit build/Espazio-<version>.dmg --keychain-profile <profil> --wait
xcrun stapler staple build/Espazio-<version>.dmg
# 4. Générer / mettre à jour l’appcast (signe l’archive avec la clé privée du Trousseau)
mkdir -p updates && cp build/Espazio-<version>.dmg updates/
./bin/generate_appcast updates/
# 5. Créer la release GitHub et y joindre le .dmg et updates/appcast.xml
```

## Comportement

- Sparkle demande à l’utilisateur s’il souhaite vérifier automatiquement (à partir du 2ᵉ lancement).
- Réglages › Général › Mises à jour : vérification automatique et « Rechercher maintenant ».
- `SUEnableSystemProfiling` est désactivé : aucune information système n’est envoyée.
- Les archives sont vérifiées par signature EdDSA et par la signature de code Apple.
