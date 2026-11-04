# dmgbuild settings: styled drag-to-Applications window (used by make-dmg.sh)
import os
app = defines.get("app", "build/JarvisHUD.app")
art = defines.get("art", "build/art")
format = "UDZO"
size = None
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(art, "AppIcon.icns")
background = os.path.join(art, "dmg-bg.png")   # 660x400 (@2x variant picked up automatically if present)
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {"JarvisHUD.app": (165, 200), "Applications": (495, 200)}
