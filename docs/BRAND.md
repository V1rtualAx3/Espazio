# Identité visuelle Espazio

Fichiers : `Resources/Brand/` (SVG vectoriels, texte vectorisé), `Resources/AppIcon.iconset/` (PNG 16 → 1024).

## Concept

**Icône d’app** : trois silhouettes `NotchShape` emboîtées qui descendent du bord supérieur — la notch qui
s’ouvre (repliée → aperçu → déployée). Aplats de gris, lisible dès 16 px.

**Symbole du logo** : il **est** la notch d’Espazio : la silhouette reprend exactement `NotchShape`
(`Sources/EspazioUI/NotchShape.swift`) — courbes supérieures vers l’extérieur qui se fondent dans le bord de
l’écran, coins inférieurs arrondis. À l’intérieur, l’état **peek** du design system : une icône à gauche, une
seule valeur à droite (barre de progression `EZProgressBar` : piste blanc 18 %, remplissage blanc).
« Espazio » = l’espace : la notch qui s’ouvre pour faire de la place à l’information.

## Déclinaisons

| Fichier | Usage |
|---|---|
| `AppIcon.svg` | Icône d’app (grille macOS 1024/824, coins continus) : fond noir, notches emboîtées gris foncé / gris / blanc. Source de l’iconset. |
| `AppIcon-Light.svg` | Variante claire (fond #F2F2F2, notches gris clair / gris / noir), pour supports clairs. |
| `Mark-Black.svg` / `Mark-White.svg` | Symbole seul : bord d’écran + notch, contenu peek en réserve. |
| `Logo-Black.svg` / `Logo-White.svg` | Symbole + logotype « Espazio ». |

## Règles

* Monochrome uniquement : noir, blanc, gris (`EZColor`). Jamais le rouge `deny` ni le vert `allow`, réservés à la
  décision IA.
* Aplats : pas de dégradé, de halo, d’ombre ni de flou.
* Logotype : Inter Display SemiBold vectorisée (licence SIL OFL), équivalent ouvert de SF Pro Display,
  approche −1 %.
* Zone de protection : la hauteur du bord d’écran du symbole ×2 tout autour. Taille minimale du symbole : 16 px de large.

## Régénérer

```sh
pip install fonttools
python3 scripts/generate-brand.py                       # → Resources/Brand/*.svg
node scripts/render-iconset.js Resources/Brand/AppIcon.svg Resources/AppIcon.iconset   # Playwright + Chromium
```

`scripts/build-app.sh` compile l’iconset en `AppIcon.icns` avec `iconutil` (macOS) ; `Info.plist` le référence
via `CFBundleIconFile`.
