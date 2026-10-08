#!/bin/zsh
# Builds the app and packages build/JarvisHUD.dmg
set -e
cd "$(dirname "$0")"
./build.sh
STAGE=build/dmg; rm -rf $STAGE; mkdir -p $STAGE
cp -R build/JarvisHUD.app $STAGE/
ln -s /Applications $STAGE/Applications
rm -f build/JarvisHUD.dmg
hdiutil create -volname "JarvisHUD" -srcfolder $STAGE -ov -format UDZO build/JarvisHUD.dmg
rm -rf $STAGE
echo "Packaged build/JarvisHUD.dmg"
