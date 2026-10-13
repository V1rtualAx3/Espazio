# Identité visuelle Espazio

Fichiers : `Resources/Brand/` (SVG vectoriels, texte vectorisé), `Resources/AppIcon.iconset/` (PNG 16 → 1024).

## Concept

Trois silhouettes `NotchShape` emboîtées (géométrie exacte de `Sources/EspazioUI/NotchShape.swift` : courbes
supérieures vers l’extérieur, coins inférieurs arrondis) qui descendent du bord supérieur : la notch qui s’ouvre
(repliée → aperçu → déployée). « Espazio » = l’espace : la notch qui s’ouvre pour faire de la place à
l’information. Aplats de gris, lisible dès 16 px.

## Déclinaisons

| Fichier | Usage |
|---|---|
| `AppIcon.svg` | Icône d’app (grille macOS 1024/824, coins continus) : fond noir, notches emboîtées gris foncé / gris / blanc. Source de l’iconset. |
| `AppIcon-Light.svg` | Variante claire (fond #F2F2F2, notches gris clair / gris / noir), pour supports clairs. |
| `Logo-Horizontal.svg` | Logo horizontal pour fond clair : icône sombre + « Espazio » en noir. |
| `Logo-Horizontal-White.svg` | Logo horizontal pour fond sombre : icône claire + « Espazio » en blanc (l’icône sombre disparaîtrait sur du noir). |

## Règles

* Monochrome uniquement : noir, blanc, gris (`EZColor`). Jamais le rouge `deny` ni le vert `allow`, réservés à la
  décision IA.
* Aplats : pas de dégradé, de halo, d’ombre ni de flou.
* Logotype : Inter Display SemiBold vectorisée (licence SIL OFL), équivalent ouvert de SF Pro Display,
  approche −1 %.
* Logo horizontal : icône haute de 1,42 × la hauteur des capitales, espace icône–texte = 30 % de l’icône.
* Zone de protection : la moitié de la hauteur de l’icône tout autour. Taille minimale : icône 16 px, logo
  horizontal 20 px de haut.

## Régénérer

```sh
pip install fonttools
python3 scripts/generate-brand.py                       # → Resources/Brand/*.svg
node scripts/render-iconset.js Resources/Brand/AppIcon.svg Resources/AppIcon.iconset   # Playwright + Chromium
```

`scripts/build-app.sh` compile l’iconset en `AppIcon.icns` avec `iconutil` (macOS) ; `Info.plist` le référence
via `CFBundleIconFile`.
