# Checklist de validation manuelle (Mac)

À exécuter sur un Mac Apple Silicon avant toute publication. Cocher, dater et noter la machine.
Rien dans cette liste n’a encore été exécuté (développement réalisé hors Mac).

Machine : ________ · macOS : ________ · Écrans : ________ · Date : ________

## N — Notch et écrans

- [ ] N1 Lancement : aucune icône Dock, icône dans la barre des menus, notch invisible au repos.
- [ ] N2 Survol de la découpe → déploiement après le délai ; sortie → repli ; aucune app ne perd le focus.
- [ ] N3 Clic sur la notch → déploiement sans activer Espazio ; champ des actions rapides utilisable.
- [ ] N4 Échap / clic ailleurs → repli.
- [ ] N5 ⌃⌥N bascule la notch ; ⌃⌥Espace ouvre les Actions rapides.
- [ ] N6 Écran externe sans découpe : notch virtuelle centrée, hauteur = barre des menus.
- [ ] N7 Réglage « Tous les écrans » : une notch par écran ; une décision prise sur un écran disparaît de l’autre ; exécutée une seule fois.
- [ ] N8 Brancher/débrancher un moniteur, changer la résolution, changer l’écran principal : notches repositionnées, pas de fenêtre orpheline.
- [ ] N9 App plein écran + option « Masquer en plein écran » : notch masquée, une demande P0 reste visible.
- [ ] N10 Changement d’espace (Mission Control) : notch présente sur chaque espace.
- [ ] N11 La barre des menus reste cliquable à gauche et à droite de la notch dans chaque état.
- [ ] N12 Mode clair et sombre ; Réduire les animations ; Augmenter le contraste ; VoiceOver lit la carte de décision.

## S — Système et Spotify

- [ ] S1 Touches volume : peek avec barre de progression, coalescé (pas d’animation répétée).
- [ ] S2 Changement de sortie audio (AirPods, HDMI) : nom affiché.
- [ ] S3 Verr. Maj : peek ; si rien ne s’affiche, accorder Accessibilité et vérifier le message de Réglages › Modules.
- [ ] S4 Verr. Num affiché « Indisponible ».
- [ ] S5 Débrancher/brancher l’alimentation ; batterie < 20 % puis < 10 % (P1).
- [ ] S6 Bluetooth (option) : connexion/déconnexion d’un périphérique.
- [ ] S7 Spotify : titre/artiste/pochette, lecture/pause/suivant/précédent (autorisation Automatisation demandée une fois), progression qui avance sans requête, ondes arrêtées en pause.
- [ ] S8 Spotify fermé : Espazio ne le relance jamais tout seul.

## P — Calendrier et Rappels

- [ ] P1 Autorisations Calendrier et Rappels demandées séparément, uniquement au clic.
- [ ] P2 Prochain événement + compte à rebours ; bouton « Rejoindre » pour Meet/Zoom/Teams.
- [ ] P3 Peek P1 5 min avant un événement ; réunion en cours → seules P0/P1 interrompent.
- [ ] P4 Rappels du jour et en retard ; cocher un rappel le termine dans l’app Rappels.
- [ ] P5 Actions rapides : « + acheter du pain demain 9h » crée le rappel avec échéance.
- [ ] P6 Agenda Google synchronisé dans Calendrier + option Google Agenda direct : pas de doublon.

## A — Agents IA

- [ ] A1 Installer les hooks : sauvegarde créée, autres hooks conservés.
- [ ] A2 Lancer Claude Code, commande nécessitant une autorisation → peek P0, carte avec commande complète, répertoire, session. « Autoriser une fois » → la commande s’exécute ; la suivante redemande.
- [ ] A3 « Refuser » → Claude reçoit le refus. Délai dépassé → refus. Quitter Espazio pendant l’attente → Claude affiche sa propre demande (ou refus).
- [ ] A4 Interrompre Claude (Échap) pendant l’attente → la carte disparaît.
- [ ] A5 Deux sessions simultanées → file 1/2, 2/2.
- [ ] A6 Mode silencieux → pas de peek animé, badge « N en attente ».
- [ ] A7 Session Codex depuis Espazio : demandes d’approbation de commande et de fichiers, réponse « accept » uniquement après clic.
- [ ] A8 `notify` Codex : session CLI affichée « Lecture seule », sans boutons de décision.
- [ ] A9 ChatGPT (option) : état ouvert/fermé, bouton d’ouverture.
- [ ] A10 `audit.log` : identifiants et issues seulement, aucune commande.

## G — Google

- [ ] G1 Connexion OAuth (navigateur système), retour automatique, compte affiché.
- [ ] G2 Non-lus + aperçus ; nouveau mail → peek P2 ; ne masque jamais une demande IA.
- [ ] G3 « Marquer comme lu » → demande de consentement `gmail.modify` la première fois, puis effet immédiat.
- [ ] G4 Wi-Fi coupé → état d’erreur avec prochain essai ; retour réseau → reprise.
- [ ] G5 Révoquer l’accès depuis myaccount.google.com → « Reconnexion nécessaire ».
- [ ] G6 Compte personnel + Google Chat → « Non pris en charge pour ce compte », Gmail intact.
- [ ] G7 Compte Workspace + Chat : message reçu → badge et aperçu en moins de 10 s ; message envoyé par soi → aucune notification ; conversation lue ailleurs → disparaît ; clic → ouverture dans Google Chat et retrait immédiat.
- [ ] G7b Conversation Chat en sourdine → aucun badge, aucun aperçu ; « Pour vous » → listée sans aperçu.
- [ ] G8 E-mail ouvert depuis la notch → retiré de la liste et du badge immédiatement.

## M — Mesures (voir PERFORMANCE.md)

- [ ] M1 Mémoire au repos ≤ 80 Mo (Réglages › Diagnostic + Activity Monitor).
- [ ] M2 CPU au repos ≈ 0 % (Time Profiler 5 min).
- [ ] M3 Instruments Leaks 30 min : aucune fuite.
- [ ] M4 Animation Hitches expand/collapse.
