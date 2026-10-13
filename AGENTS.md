# Espazio — Instructions permanentes aux agents de développement

Lis `ESPAZIO_CAHIER_DES_CHARGES.md` intégralement avant toute modification. Ce document est la source de vérité produit.

## Principes

- macOS natif (SwiftUI / AppKit), élégant, monochrome et extrêmement léger.
- Aucun Electron, aucune WebView permanente, aucun polling intensif, aucun ajout de dépendance injustifié.
- Contrôles colorés uniquement pour « Refuser » (rouge) et « Autoriser une fois » (vert) du centre IA.
- Sécurité, correction et stabilité priment sur une optimisation esthétique.
- Développement distant possible ; ne jamais affirmer qu’un test macOS a réussi sans l’avoir exécuté.

## Choix libre et proportionné des modèles

Tu peux choisir ou adapter librement, dans les limites des outils réellement exposés par ton environnement, le modèle, la délégation à des sous-agents et l’effort de raisonnement. Utilise le niveau le plus économique suffisant pour atteindre un résultat fiable. Réserve les configurations avancées aux tâches difficiles, critiques ou bloquées. Ne perds pas du temps à essayer de changer un paramètre non disponible. Ne dégrade jamais tests, sécurité ou exactitude pour économiser des tokens.

## Responsabilité de bout en bout

Tu es responsable de l’architecture, de l’implémentation, de la relecture critique du code, des tests, de la documentation et du suivi des performances. Relis chaque diff avant livraison ; corrige les défauts identifiés. Pour les modifications structurantes, sollicite si possible une seconde revue indépendante. N’invente jamais une mesure, un test, une API ou une compatibilité.

## Processus obligatoire

1. Délimiter une tâche, établir des critères d’acceptation.
2. Vérifier documentation/contraintes de plateforme lorsque nécessaire.
3. Implémenter une solution modulaire et testable.
4. Exécuter les tests réellement disponibles ; analyser et corriger les résultats.
5. Relire le diff, la gestion d’erreurs, le cycle de vie et les implications performance/sécurité.
6. Mettre à jour `docs/DEVELOPMENT_LOG.md` et la documentation pertinente.
7. Livrer une PR claire sans fusionner automatiquement dans `main`.
8. Fin de jalon : suggérer 3 à 5 améliorations/features avec bénéfice, difficulté et impact mémoire/CPU sans les implémenter sans validation.

## Interdictions

- Pas de secrets en clair ; pas de télémétrie par défaut.
- Ne pas autoriser automatiquement une action d’agent IA, même après timeout.
- Pas de commandes destructrices hors dépôt ni publication/déploiement sans autorisation.
- Pas de revendication de contrôle total d’apps tierces sans mécanisme officiel et validé.

## Repères techniques du dépôt

- Paquet Swift unique (`Package.swift`, Swift 6, macOS 14+). Xcode ouvre directement `Package.swift`.
- Cibles multiplateformes (compilées et testées aussi sous Linux) : `EspazioCore`, `EspazioBridge`, `AgentIntegrations`, `GoogleProvider`, `espazio-hook`.
- Cibles macOS uniquement (déclarées sous `#if os(macOS)` dans le manifeste) : `SystemServices`, `ProductivityProviders`, `EspazioUI`, `Espazio` (l’app).
- Toute logique testable (priorités, files, sécurité des approbations, géométrie, parsing réseau) va dans une cible multiplateforme ; les cibles macOS restent de fines couches d’adaptation.
- Commandes :
  - `swift build` / `swift test` (macOS ou Linux ; sous Linux via l’image Docker `swift:6.1-noble`).
  - `scripts/build-app.sh` (macOS) : assemble et signe ad hoc `build/Espazio.app`.
- CI : `.github/workflows/ci.yml` (job Linux pour la logique, job macOS pour l’app complète).
- Un test qui n’a pas tourné sur Mac doit être signalé « non vérifié sur Mac ».
