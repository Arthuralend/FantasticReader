#!/bin/bash
# Собирает FantasticReader.app и (по желанию) копирует в /Applications
set -e
cd "$(dirname "$0")"
swift build -c release
APP="FantasticReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/FantasticReader "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>FantasticReader</string>
<key>CFBundleIdentifier</key><string>com.fantasticreader.app</string>
<key>CFBundleExecutable</key><string>FantasticReader</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Готово: $(pwd)/$APP"
echo "Установить: cp -R $APP /Applications/"
