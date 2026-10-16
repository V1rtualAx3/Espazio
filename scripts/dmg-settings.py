# dmgbuild settings for Espazio's drag-and-drop DMG (used by scripts/package.sh).
# Icon positions must match the arrow drawn in Resources/Brand/DMGBackground.svg.
app = defines["app"]  # noqa: F821  (provided by dmgbuild -D)
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]  # noqa: F821  (PNG; the @2x file next to it is used for Retina)
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
icon_size = 96
text_size = 12
icon_locations = {"Espazio.app": (180, 230), "Applications": (480, 230)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
format = "UDZO"
filesystem = "HFS+"
