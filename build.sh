#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=build/JarvisHUD.app
SIGN="Apple Development: yutan@me.com (V2R79MY3H2)"
mkdir -p $APP/Contents/MacOS
swiftc -O -framework Cocoa -framework QuartzCore -framework IOKit Sources/*.swift -o $APP/Contents/MacOS/JarvisHUD
swiftc -O -framework IOKit Sources/Stats.swift Helper/main.swift -o $APP/Contents/MacOS/jarvisfan
cp Info.plist $APP/Contents/
codesign --force --sign "$SIGN" $APP/Contents/MacOS/jarvisfan
codesign --force --options runtime --sign "$SIGN" $APP
echo "Built $APP"
