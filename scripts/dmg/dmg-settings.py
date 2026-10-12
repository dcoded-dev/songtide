# dmgbuild settings for Songtide's installer window (used by scripts/release-direct.sh).
# Passed in with -D: app (path to Songtide.app), background (multi-resolution TIFF).
import os.path

app = defines["app"]
format = "ULFO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

background = defines["background"]
window_rect = ((200, 140), (640, 400))   # matches the 640x400 background
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
icon_size = 128
text_size = 13
arrange_by = None
# Icon centres, lined up with the arrow drawn in make-background.py.
icon_locations = {"Songtide.app": (170, 150), "Applications": (470, 150)}
hide_extensions = ["Songtide.app"]
