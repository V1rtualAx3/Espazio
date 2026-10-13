# Performance et consommation

## Statut des mesures

**Aucune mesure sur Mac n’a encore été réalisée** : le développement a eu lieu dans un conteneur Linux
(Claude Code Cloud) et la CI macOS ne lance pas l’interface. Les cibles du cahier des charges restent des
objectifs à mesurer ; ce document décrit les choix de conception et le protocole de mesure.

| Mesure | Cible | Statut |
|---|---|---|
| Mémoire au repos (somme des processus) | ≤ 80 Mo | non mesuré |
| Mémoire en activité normale | ≤ 150 Mo | non mesuré |
| CPU au repos | ≤ 0,5 % | non mesuré |
| Animations | 60 fps visés | non mesuré |
| Réactivité | aucune latence perceptible | non mesuré |

## Choix de conception

* **Zéro boucle au repos** : aucun timer périodique. Événements uniquement : CoreAudio property listeners,
  `IOPSNotificationCreateRunLoopSource`, `flagsChanged`, notifications distribuées Spotify,
  `EKEventStoreChanged`, `NSWorkspace`, dispatch source du bridge.
* **Un seul timer d’expiration** (prochaine expiration du routeur) et **un seul timer d’agenda** (prochaine
  échéance : 5 min avant un événement, début/fin, rappel, minuit), tolérances 0,1 s et 2 s.
* `TimelineView` (progression de lecture, compte à rebours de décision) uniquement dans des vues visibles
  — rien ne tourne quand la notch est repliée.
* Animation d’ondes Spotify via `symbolEffect` (Core Animation), désactivée en pause ou avec Reduce Motion.
* Pochettes : vignette 96 px décodée directement (`CGImageSourceCreateThumbnailAtIndex`), cache LRU
  12 entrées / 2 Mo.
* Gmail : métadonnées uniquement (jamais le corps), 8 messages max ; synchronisation par `history`
  (1 requête si rien n’a changé). Chat : 1 requête `spaces.list` par cycle, messages seulement pour les
  espaces actifs (3 max). Intervalle par défaut 3 min, backoff jusqu’à 30 min, pause pendant la veille.
* Routeur borné (64 éléments), sessions d’agents bornées (32), demandes en attente bornées (64), cache de
  messages Chat borné (8 espaces).
* Fenêtres : une par écran hébergé, redimensionnée à l’état courant ; contenu SwiftUI partagé via un état
  observable (une seule source, aucune requête dupliquée entre écrans).
* `codex app-server` lancé à la demande, arrêté après 15 min d’inactivité.
* `espazio-hook` : binaire en ligne de commande sans résidence.

## Protocole de mesure (à exécuter sur Mac)

1. `CONFIGURATION=release scripts/build-app.sh`, lancer `build/Espazio.app`, attendre 2 min.
2. Réglages › Diagnostic › « Mesurer maintenant » (empreinte `phys_footprint`, temps CPU cumulé, CPU moyen).
3. Instruments : *Allocations* + *Leaks* (30 min), *Time Profiler* au repos (5 min, CPU attendu ≈ 0),
   *Animation Hitches* sur expand/collapse.
4. Activity Monitor : colonne Mémoire et CPU de `Espazio`, `espazio-hook` (transitoire), `codex`.
5. Scénarios : à froid / à chaud ; 1 écran / 2 écrans (« Tous les écrans ») ; Google connecté ou non ;
   agents actifs ou non ; après plusieurs heures.
6. Reporter les résultats ci-dessous avec la machine (puce, macOS, nombre d’écrans).

## Résultats

_À compléter lors de la première validation sur Mac._
