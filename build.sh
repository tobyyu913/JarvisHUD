#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=build/JarvisHUD.app
SIGN="Apple Development: yutan@me.com (V2R79MY3H2)"
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
# App icon + DMG art are rendered from Art/render.swift (cached in build/art)
if [ ! -f build/art/AppIcon.icns ]; then
  mkdir -p build/art/AppIcon.iconset
  swift Art/render.swift build/art >/dev/null
  mv build/art/icon_*.png build/art/AppIcon.iconset/
  iconutil -c icns build/art/AppIcon.iconset -o build/art/AppIcon.icns
fi
cp build/art/AppIcon.icns $APP/Contents/Resources/
swiftc -O -target arm64-apple-macos15.0 -framework Cocoa -framework QuartzCore -framework IOKit -framework Speech -framework AVFoundation Sources/*.swift -o $APP/Contents/MacOS/JarvisHUD
swiftc -O -target arm64-apple-macos15.0 -framework IOKit Sources/Stats.swift Helper/main.swift -o $APP/Contents/MacOS/jarvisfan
cp Info.plist $APP/Contents/
codesign --force --sign "$SIGN" $APP/Contents/MacOS/jarvisfan
codesign --force --options runtime --entitlements entitlements.plist --sign "$SIGN" $APP
echo "Built $APP"
