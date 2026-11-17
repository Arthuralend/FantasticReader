#!/bin/bash
# Собирает FantasticReader.dmg (запускать на Mac)
set -e
cd "$(dirname "$0")"
./build-app.sh
rm -rf dmg-root FantasticReader.dmg
mkdir dmg-root
cp -R FantasticReader.app dmg-root/
ln -s /Applications dmg-root/Applications
hdiutil create -volname FantasticReader -srcfolder dmg-root -ov -format UDZO FantasticReader.dmg
rm -rf dmg-root
echo "Готово: $(pwd)/FantasticReader.dmg"
