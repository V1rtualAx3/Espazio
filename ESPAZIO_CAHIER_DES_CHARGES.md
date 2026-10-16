# ESPAZIO — Cahier des charges fonctionnel et technique
Version : 1.0 — 13 octobre 2026  
Cible : macOS 27, Mac Apple Silicon M2 à M5 (sous réserve des versions de macOS officiellement compatibles avec chaque appareil)  
Exécution du développement : Claude Code Cloud, dépôt GitHub, pull requests, validation native macOS  
Objectif : utilitaire de notch discret, performant, natif, moderne et orienté productivité.  

## 1. Mission et vision du produit

Développer Espazio, application macOS inspirée de l’ergonomie de Boring Notch, enrichie par les intégrations Google, Apple et les agents IA. La notch doit rester quasi invisible au repos, afficher de petites informations contextuelles, puis se développer uniquement lorsque l’utilisateur souhaite interagir ou doit prendre une décision.
Priorités ordonnées : (1) stabilité et sécurité ; (2) performance et faible empreinte mémoire ; (3) fluidité et ergonomie ; (4) fonctions natives utiles ; (5) richesse des connecteurs. Une intégration complexe ne doit jamais pénaliser la réactivité générale.
Non-objectifs V1 : navigateur intégré, Electron, WebView permanente, assistant conversationnel supplémentaire, tableau de bord matériel CPU/RAM permanent, File Shelf, minuteurs de concentration, conversation IA complète dans la notch.

## 2. Identité visuelle et design system

- Design Apple macOS contemporain, inspiré de Liquid Glass pour le volume, les formes et les animations ; surfaces opaques ou quasi opaques. Pas de glassmorphism excessif, de flou plein écran, de halo ou de dégradés décoratifs.
- Couleurs de l’interface : noir, blanc et nuances de gris exclusivement, en modes clair et sombre. Seules exceptions chromatiques volontaires : bouton « Refuser » rouge et bouton « Autoriser une fois » vert dans le centre IA. Les autres boutons restent neutres. Les pochettes d’albums peuvent conserver leur contenu visuel d’origine comme données média, sans teinter les commandes ou le thème.
- Typographie système San Francisco ; SF Symbols monochromes ; contrastes accessibles, tailles dynamiques lorsque pertinentes ; prise en compte de Reduce Motion et Reduce Transparency.
- Coins arrondis, bordures très fines, pas d’ombres coûteuses ; animations sobres et interrompues dès que l’interface n’est plus visible.
- États de notch : collapsed (repos), peek (notification contextuelle non intrusive) et expanded (actions et détails). Transition au clic/survol/raccourci ; les alertes critiques n’obligent pas à voler le focus.
- Les vues compactes doivent montrer une seule information prioritaire, jamais une accumulation permanente de widgets.
- Prévoir maquettes et previews SwiftUI pour chaque état (aucun état ne doit nécessiter une connexion réseau).

## 3. Périmètre fonctionnel obligatoire

### 3.1 Notch et écrans
- Positionnement natif précis autour de la notch physique ; fallback en notch virtuelle sur moniteur sans découpe.
- Paramètre utilisateur : écran principal uniquement (défaut) ou tous les écrans. Option « écran actif » facultative, pas prioritaire.
- Support connexion/déconnexion de moniteur, changement de résolution, espaces et plein écran. Ne pas confondre systématiquement écran principal et écran de la fenêtre au premier plan.
- État des notifications synchronisé entre les écrans ; une action ne peut être exécutée deux fois.

### 3.2 Médias : Spotify
- Titre, artiste, pochette, état de lecture, lecture/pause, suivant/précédent ; progression uniquement si disponible sans polling agressif.
- Favoriser les intégrations officielles/accessibles : AppleScript/ScriptingBridge pour Spotify local, puis autres mécanismes documentés si adaptés.
- Les solutions s’appuyant sur des API privées macOS sont optionnelles, expérimentales et désactivables ; aucun fonctionnement critique ne doit en dépendre.

### 3.3 Système
- Animation compacte du volume et des changements de périphérique audio.
- Verr. Maj et Verr. Num, si détectable de manière fiable selon clavier ; gérer explicitement les claviers non compatibles et exposer l’état « indisponible » plutôt que l’inventer.
- Événements matériels sobres : batterie faible, branchement/débranchement alimentation, changement de sortie audio et périphériques Bluetooth lorsqu’observable proprement.
- Surveillance événementielle de préférence au polling ; préférences par module.

### 3.4 Productivité Apple
- Calendrier via EventKit : prochains rendez-vous, compte à rebours, ouverture de l’événement, accès au lien de réunion quand disponible.
- Apple Rappels via EventKit : listes, tâches du jour/en retard, ajout, échéance, accomplissement. Respecter les droits distincts Calendrier et Rappels et leurs demandes de permission.
- Éviter de dupliquer un calendrier Google déjà synchronisé par macOS ; proposer en option une connexion Google directe si elle ajoute une capacité absente.

### 3.5 Google
- Gmail : authentification Google OAuth 2.0 PKCE, connexion/déconnexion, nombre de non-lus, aperçu, ouverture, marquer lu, archiver si autorisé ; historique incrémental, gestion des expirations de token et quotas.
- Google Calendar : privilégier EventKit lorsque le compte est synchronisé dans Calendrier macOS ; API Google directe uniquement sur demande ou besoin fonctionnel justifié, avec déduplication.
- Google Chat : afficher conversations/messages autorisés et, si les scopes et le compte Workspace le permettent, répondre depuis la notch. Prévoir un état « non pris en charge pour ce compte » sans dégrader les autres connecteurs.
- Scopes minimaux, consentement progressif, tokens en Keychain, aucune clé secrète codée en dur. Prévoir contraintes de consentement Google, comptes personnels vs Workspace et restrictions administrateur.
- Synchronisation modérée, avec délai configurable, backoff exponentiel, limites d’appels, cache mémoire borné ; ne pas installer d’infrastructure cloud serveur tant qu’elle n’est pas indispensable.

### 3.6 AI Activity Center — fonction différenciante
- Vue consolidée de Claude Code et Codex CLI : sessions, projet, état (actif, attente, terminé, échec), dernière activité, raccourci vers le terminal ou le client.
- Affichage et traitement bidirectionnel des demandes d’autorisation lorsque les interfaces prises en charge le permettent : Refuser ou Autoriser une fois. Les autres portées d’autorisation ne doivent pas être proposées par défaut.
- Questions courtes : réponse textuelle lorsque le protocole du fournisseur la prend en charge. Ne pas promettre de capturer toutes les interactions de clients tiers.
- Claude Code : privilégier hooks documentés (PermissionRequest, Notification, Stop, événements de session, etc.) avec helper qui reçoit l’entrée JSON et renvoie des décisions valides.
- Codex : privilégier codex app-server pour les sessions contrôlées par Espazio. Les sessions CLI indépendantes ne sont suivies/contrôlées que dans la mesure où des mécanismes officiellement accessibles l’autorisent.
- ChatGPT Desktop : intégration best effort (état de l’app, ouverture, notifications réellement accessibles). Pas de contrôle d’autorisations supposé possible sans API officielle ou preuve technique reproductible.
- Identifiants uniques de requête et de session, contrôle de l’origine, délais d’expiration, refus par défaut, réponses idempotentes, journal d’audit local minimal sans secrets.
- Gestion de plusieurs sessions simultanées et d’une file de demandes, synchronisée sur tous les écrans.

### 3.7 Focus intelligent
- Filtrage/priorisation des notifications selon le contexte, avec mode silencieux manuel et, lorsque les API publiques le permettent, adaptation au Focus système.
- Si l’état des modes Focus macOS n’est pas exposé par une API adaptée, adopter un mode manuel explicite. Ne pas dépendre d’API privées.
- Les autorisations IA attendues restent accessibles mais n’interrompent pas systématiquement le travail.

### 3.8 Quick Actions
- Palette compacte avec raccourci clavier configurable : créer un rappel, consulter le prochain événement, ouvrir une session IA, rechercher/ouvrir les contenus déjà synchronisés.
- Navigation clavier, aucune WebView lourde, actions modulaires et sécurisées.

## 4. Architecture logicielle recommandée

Technologies préférées : Swift 6, SwiftUI, AppKit, Swift Concurrency, EventKit, CoreAudio, Keychain, URLSession, Swift Package Manager. NSPanel personnalisé pour l’UI ; état observable et coordinator central ; connecteurs découplés via protocoles. Les choix définitifs pourront évoluer si Claude apporte une justification technique et des mesures.
Composants logiques :
1. EspazioApp : lifecycle, menu bar, settings, permissions, raccourcis.
2. EspazioUI : design system, notch multi-états, widgets, animations.
3. DisplayManager : écrans, fenêtres, placement, synchronisation des vues.
4. EspazioCore : modèles, coordinator, priorités, configuration, cache.
5. SystemServices et MediaProvider.
6. ProductivityProviders : Calendar, Reminders.
7. GoogleProvider : OAuth, Gmail, Google Chat, cache/quotas.
8. AgentIntegrations : Claude, Codex, ChatGPT (facultatif).
9. EspazioBridge uniquement si justifié par les hooks/communications avec les processus externes ; helper minimal, pas de service gourmand permanent.
La communication entre processus, si nécessaire, se fera de préférence par Unix Domain Socket local sécurisé avec messages versionnés et bornes de taille. Aucun port réseau ouvert par défaut. Des processus supplémentaires ne sont autorisés que si leur bénéfice est démontré.

## 5. Performance et consommation — exigences de premier rang

Les chiffres suivants sont des objectifs de conception à mesurer, non des garanties préalables :

|Mesure                            |Cible initiale            |Conditions                                            |
|----------------------------------|--------------------------|------------------------------------------------------|
|Mémoire totale au repos           |<= 80 Mo                  |Somme des processus Espazio, après stabilisation      |
|Mémoire totale en activité normale|<= 150 Mo                 |Avec connecteurs typiques chargés                     |
|CPU au repos                      |<= 0,5 %                  |Hors activité réseau et hors animation, mesure définie|
|UI animations                     |60 fps visés              |Sur machine de référence, si affichage compatible     |
|Réactivité                        |Aucune latence perceptible|Mesurer transitions et commandes courantes            |
Ne pas sacrifier la fiabilité pour atteindre un seuil arbitraire ; si une cible échoue, documenter la mesure, la cause et le plan d’optimisation. Mesurer avec Instruments, Allocations, Leaks, Activity Monitor et tests reproductibles macOS. Mesurer à froid/à chaud, une notch/deux écrans, avec et sans Google, avec et sans agents, en activité et après plusieurs heures.
Règles : aucun Electron, aucune WebView permanente, aucune boucle à 60 Hz au repos, pas de polling serré, ne pas charger une grande image si un thumbnail suffit, plafonner les caches, limiter les timers, interrompre les tâches non utiles, dédupliquer les requêtes réseau entre écrans, supprimer les observateurs/abonnements et détecter les fuites. Prévoir un panneau diagnostic léger et facultatif.

## 6. Politique de notifications et états

- Priorité P0 : autorisation / question bloquante d’agent.
- P1 : échéance imminente, événements système importants.
- P2 : Google Chat, Gmail (selon préférences).
- P3 : volume, batterie, changement de piste.
- P4 : présence discrète d’une activité/média.
Éviter les animations répétées pour des événements équivalents ; coalescer les notifications. Une notification Gmail ne doit pas masquer une demande IA. Ne jamais forcer le focus lors d’un événement passif.

## 7. Confidentialité et sécurité

- Fonctionnement local-first ; traitement à distance limité aux API Google choisies et aux services déjà utilisés par l’utilisateur.
- OAuth PKCE, stockage Keychain, scopes minimaux, révocation claire ; ne pas exposer tokens, contenu de mails ou commandes dans les logs.
- Pas de télémétrie ni analytics tiers par défaut.
- Autorisations IA : identité de session, commande complète, répertoire et contexte affichés avant décision ; aucune validation implicite ; timeout = refus/annulation sûre selon protocole.
- Une session IA non pilotée ne doit pas être présentée comme pilotable. Les actions destructrices sensibles requièrent une interaction explicite.
- Signatures, notarisation et permissions macOS documentées ; packaging hors Mac App Store si pertinent.

## 8. Développement autonome dans Claude Code Cloud

### 8.1 Autonomie du choix du modèle et du niveau de raisonnement
Claude est explicitement autorisé et encouragé à choisir, lorsque son environnement le permet, le modèle le plus adapté et le niveau d’effort/de raisonnement nécessaire pour chaque sous-tâche. Ne pas utiliser par défaut le modèle le plus avancé ou un raisonnement très poussé pour des tâches simples. Exemples :
- Tâches simples : renommage, documentation, formatage, tests triviaux, vérifications localisées -> modèle léger/rapide et effort faible si disponibles.
- Tâches intermédiaires : composants SwiftUI classiques, services simples, refactoring local, tests unitaires -> modèle équilibré et effort normal.
- Tâches critiques/complexes : sécurité du bridge, approbations d’agents, concurrence, architectures transverses, débogage difficile, API ambiguës -> modèle plus avancé et raisonnement approfondi lorsque justifié.
Claude peut augmenter ou diminuer l’effort en cours de tâche et déléguer des tâches simples à des sous-agents si les outils le permettent. Cette liberté ne donne pas la capacité fictive de changer de modèle ou de configurer l’effort quand la plateforme ne le permet pas : dans ce cas, adopter une méthode de travail proportionnée, limiter les recherches et les longues analyses inutiles, et signaler brièvement la limitation. Optimiser la consommation de tokens, le temps et le coût sans compromettre la sécurité, les tests et la qualité. Ne jamais exposer de chaîne de pensée privée : fournir seulement des décisions techniques vérifiables et leurs justifications succinctes.

### 8.2 Responsabilité de la qualité du code
Claude est propriétaire de la qualité de chaque modification qu’il livre : il doit relire son propre code, rechercher les régressions, vérifier la compilation lorsqu’un environnement macOS existe, écrire/mettre à jour les tests pertinents, contrôler les erreurs, les risques de concurrence, les fuites, les secrets et l’accessibilité. Avant toute PR, effectuer une revue structurée des changements et corriger les problèmes détectés.
Une passe de revue indépendante (sous-agent si disponible) est encouragée pour les modifications importantes. La présence d’une revue automatisée ne dispense jamais de vérification réelle. Aucun test inexécuté ne doit être annoncé comme réussi.

### 8.3 Boucle de réalisation
1. Inspecter dépôt, objectifs et dépendances ; clarifier techniquement les API incertaines avec documentation actuelle.
2. Planifier une unité de travail petite et livrable, noter hypothèses et risques.
3. Implémenter avec tests ; rester dans le périmètre des fichiers utiles.
4. Exécuter formatage, lint, analyse statique, tests disponibles ; corriger les défauts.
5. Effectuer une relecture critique du diff (sécurité, lisibilité, déduplication, performance, robustesse).
6. Actualiser documentation et journal de développement ; créer commit(s) cohérents.
7. Préparer une PR explicite avec preuves de validation et limites.
8. Passer à la tâche suivante si l’environnement et la session le permettent.
Pas de push vers la branche principale, pas de fusion automatique, pas de publication ni déploiement sans autorisation. Les opérations de fichier potentiellement destructives hors dépôt sont interdites.

### 8.4 Limites du cloud
Claude Code Cloud peut modifier le dépôt et travailler de manière asynchrone à la présence humaine, mais ne doit jamais prétendre tester l’interface macOS sur une machine Linux. Prévoir CI GitHub Actions macos pour compilation Swift/Xcode et tests compatibles ; garder une checklist manuelle pour fenêtre notch, multi-écrans, permissions EventKit, Spotify, animations et intégrations avec applications présentes. Si le CI macOS n’est pas disponible, marquer « non vérifié sur Mac ».

## 9. Tests et critères d’acceptation

- Tests unitaires pour le routeur d’événements, priorités, expiration, ID de session, déduplication et configuration des écrans.
- Tests d’intégration pour les fournisseurs avec doubles/fakes, gestion du réseau indisponible, droits refusés, token expiré, limite API.
- Tests de sécurité des approbations IA : requêtes en double, timeout, mauvaise session, fermeture/reconnexion, bridge interrompu.
- Tests UI : collapsed/peek/expanded, clair/sombre, Reduced Motion, navigation clavier, longues chaînes, multi-écrans.
- Benchmarks instrumentés et publication des résultats dans la PR.
- Definition of Done : code relu, tests disponibles passés, risques documentés, API documentées vérifiées, pas de secrets, documentation à jour, aucun résultat de test inventé.

## 10. Jalons de livraison

- M0 — Repository & architecture : projet Xcode/SPM, guide, règles, CI macOS, tests et simulateurs.
- M1 — Notch & multi-écrans : design monochrome final, états, réglages, comportement plein écran.
- M2 — Système & Spotify : volume, clavier, médias, événements matériels.
- M3 — Apple Productivity : Calendrier et Rappels.
- M4 — Agents IA : EventCoordinator, bridge justifié, Claude Code, Codex app-server, sécurité et approbations.
- M5 — Google : Gmail, Google Chat, Google Calendar sans doublons ; gestion OAuth/quotas.
- M6 — Focus & Quick Actions : règles contextuelles, palette et raccourcis.
- M7 — Stabilisation : profiling, robustesse, signature/notarisation, documentation d’installation.
Chaque jalon doit fournir un résultat vérifiable et une PR distincte autant que possible. La priorisation peut être adaptée par Claude si une dépendance technique l’impose, en la documentant.

## 11. Livrables demandés

- Code source Espazio et projet Xcode compilable sur macOS compatible.
- AGENTS.md, README.md, docs/ARCHITECTURE.md, docs/DESIGN_SYSTEM.md, docs/SECURITY.md, docs/PERFORMANCE.md, docs/DEVELOPMENT_LOG.md.
- CI macOS, tests unitaires/intégration et checklist de validation manuelle.
- Instructions de configuration OAuth Google et d’installation des intégrations Claude/Codex.
- Tableau des fonctionnalités : opérationnelles / partielles / expérimentales / indisponibles.
- Rapport final de fin de tâche / de jalon contenant : modifications, justification des choix, tests réellement exécutés, problèmes, compromis et consommation mesurée.

### Proposition obligatoire de nouvelles fonctionnalités en fin de mission
À la fin de chaque grand jalon et au bilan final, Claude doit proposer 3 à 5 fonctionnalités ou améliorations pertinentes pour Espazio, même non demandées initialement. Chaque suggestion comprend : intérêt utilisateur, coût de performance potentiel, difficulté, dépendances, risque, et recommandation V1/V2/à écarter. Les suggestions sont uniquement des propositions : Claude ne doit pas les implémenter sans validation explicite. L’objectif est d’améliorer le produit sans dériver vers un logiciel lourd et surchargé.

## 12. Consigne de démarrage pour Claude Code Cloud

> Lis ce document intégralement, puis inspecte le dépôt. Commence par M0, prépare une architecture minimale vérifiable et une première PR. Tu es responsable du code, de sa relecture critique, de la qualité et de sa performance. Choisis le modèle et l’effort de raisonnement adaptés à chaque tâche quand ton environnement te le permet ; évite toute dépense de calcul inutile. Travaille par lots vérifiables, avec tests, compte rendu honnête et propositions de fonctionnalités à la fin. Ne suppose pas qu’une API ou qu’un test macOS fonctionne sans preuve.

## 13. Références techniques à revalider au démarrage

- Claude Code Cloud : https://support.claude.com/fr/articles/12618689-claude-code-sur-le-web
- Claude Code hooks : https://code.claude.com/docs/en/hooks
- Codex app-server : https://developers.openai.com/codex/app-server/
- Apple EventKit : https://developer.apple.com/documentation/eventkit
- Apple AppKit : https://developer.apple.com/documentation/appkit
- Gmail API : https://developers.google.com/workspace/gmail/api
- Google Chat API : https://developers.google.com/workspace/chat/api
Règle : valider la documentation correspondant à la version réellement disponible des SDK, APIs et outils avant de coder des intégrations dépendantes de leurs détails.
