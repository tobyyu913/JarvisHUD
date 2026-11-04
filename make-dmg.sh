#!/bin/zsh
# Builds the app and packages build/JarvisHUD.dmg with a styled drag-to-Applications window.
# Layout is written straight into the image's .DS_Store by dmgbuild (no Finder scripting).
set -e
cd "$(dirname "$0")"
./build.sh
if [ ! -x build/venv/bin/dmgbuild ]; then python3 -m venv build/venv && build/venv/bin/pip -q install dmgbuild; fi
rm -f build/JarvisHUD.dmg
build/venv/bin/dmgbuild -s dmg-settings.py -D app=build/JarvisHUD.app -D art=build/art "JarvisHUD" build/JarvisHUD.dmg
echo "Packaged build/JarvisHUD.dmg"
