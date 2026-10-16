# Design system Espazio

Implémentation : `Sources/EspazioUI/DesignSystem.swift`, `NotchShape.swift`.
Logo et icône d’app : [BRAND.md](BRAND.md).

## Principes

* Monochrome : noir, blanc, gris. Aucune teinte d’accentuation.
* **Seules exceptions chromatiques** : « Refuser » (`EZColor.deny`, rouge) et « Autoriser une fois »
  (`EZColor.allow`, vert) dans la carte de décision IA. Les pochettes d’album sont affichées telles quelles
  (donnée média) sans teinter l’interface.
* Surfaces opaques ; pas de flou plein écran, pas de halo, pas de dégradé décoratif, pas d’ombre coûteuse.
* Une seule information prioritaire dans les vues compactes.

## Surfaces

| Contexte | Apparence |
|---|---|
| Notch (collapsed / peek / expanded) | Toujours noire (se confond avec le boîtier caméra), texte blanc et gris, en mode clair comme sombre. |
| Réglages, Actions rapides | Suivent l’apparence système (couleurs sémantiques, `regularMaterial` pour la palette). |

## Jetons

| Jeton | Valeur |
|---|---|
| `notchBackground` | noir 100 % |
| `notchRaised` / `notchRaisedHover` | blanc 11 % / 16 % (gris) |
| `notchStroke` | blanc 8 %, filet 0,5 pt |
| `notchPrimary` / `notchSecondary` / `notchTertiary` | blanc 100 % / 62 % / 40 % |
| `deny` | rouge (0,84 ; 0,19 ; 0,19) |
| `allow` | vert (0,16 ; 0,62 ; 0,30) |

Typographie : San Francisco (système) — titre 13 pt semibold, corps 12 pt, légende 11 pt, commandes en
monospace 11,5 pt. Icônes : SF Symbols monochromes.

Rayons : carte 14 pt, bouton 9 pt, notch repliée 10 pt, notch déployée 26 pt (forme `NotchShape` avec
courbes supérieures vers l’extérieur, rayons animables).

## États de la notch

| État | Taille | Contenu |
|---|---|---|
| `collapsed` | taille exacte de la découpe (ou notch virtuelle 190×menu bar) ; la fenêtre réserve 8 pt dessous | rien — sauf un **point blanc de 5 pt** sous la notch tant qu’une décision IA attend (mode silencieux) : pulsation douce pendant l’attente uniquement, statique avec Réduire les animations, libellé VoiceOver, jamais interactif ni focalisant |
| `peek` | découpe + 2 ailes de 96 pt | icône à gauche, une valeur à droite (barre de volume, titre court, ondes Spotify) |
| `expanded` | 600 × (150 + notch) sur l’accueil, 600 × (230 + notch) pour Agents IA / Gmail / Chat ou une décision en attente ; la fenêtre réserve toujours la grande taille | onglets (Accueil, Agents IA, Gmail, Chat), mode concentration, réglages |

Transitions : ressort 0,38 s ; avec **Réduire les animations**, fondu 0,12 s.
À l’ouverture, le contenu apparaît en **3 paliers** décalés de 40 ms (en-tête, contenu principal, contenu
secondaire), en écho aux 3 couches de l’icône ; le dernier palier se termine avant la fin du ressort.
Avec Réduire les animations : simple fondu de 0,12 s, sans décalage ni déplacement. La fenêtre grandit avant
l’animation et ne rétrécit qu’après (0,40 s), sans animer le cadre de la fenêtre.

## Accueil (style « Dynamic Island »)

* Pas de cartes encadrées : deux sections (lecture / agenda) séparées par l’espace et un filet de 0,5 pt.
* Lecture : pochette 64 pt (rayon 12), titre 15 pt semibold, artiste 12,5 pt, barre de 3 pt avec temps
  écoulé et restant, commandes sans fond qui grossissent légèrement au survol.
* Agenda : heure en 20 pt chiffres tabulaires, titre 13 pt, compte à rebours discret, bouton rond vidéo
  pour rejoindre ; 2 rappels max puis « + N autres ».
* États vides et permissions : une seule ligne discrète (`QuietLine`), jamais un grand bloc vide.

## Composants

* `EZButtonStyle(.neutral | .subtle | .deny | .allow)` — `.deny`/`.allow` réservés à la décision IA.
* `EZIconButton`, `EZCard`, `EZProgressBar`, `EZPlaceholder` (états vides / permission / non pris en charge).
* `ApprovalCard` : fournisseur, projet, session, outil, **commande complète** (sélectionnable, défilante),
  répertoire, contexte, compte à rebours du refus automatique. Aucun raccourci clavier n’autorise.

## Accessibilité

* Libellés VoiceOver sur toutes les icônes et la carte de décision.
* Reduce Motion respecté (`EZMotion`), symboles animés désactivés.
* Surfaces opaques : Reduce Transparency n’a pas d’effet visuel à compenser (la palette utilise
  `regularMaterial`, que macOS rend opaque automatiquement).
* Contrastes : texte principal blanc sur noir (21:1), secondaire 62 % (≈ 9:1), tertiaire 40 % (≈ 4,6:1).

## Previews

`PreviewData` fournit des données hors ligne ; `NotchPreviews` couvre collapsed, peek (volume, autorisation),
expanded (accueil, agents, mail avec chaînes longues) et le mode clair. Aucun état ne nécessite de réseau.
