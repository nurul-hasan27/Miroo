#!/bin/bash
# Builds the Miroo menu-bar app (build/Miroo.app) and the CLI test host (build/MirooLinkHost.app).
# Both share one bundle identifier + signing identity so macOS permission grants (Screen Recording, Accessibility) apply to both.
set -e
cd "$(dirname "$0")/.."
swift build -c release --jobs 2 --product MirooApp
swift build -c release --jobs 2 --product miroo-host
IDENT=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
BID=com.nurulhasan.MirooLinkHost

make_app() { # name exe displayname uielement
  APP="build/$1.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp ".build/release/$2" "$APP/Contents/MacOS/$2"
  [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleName</key><string>$3</string>
  <key>CFBundleDisplayName</key><string>$3</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Miroo streams your Mac display to your iPhone over the local network.</string>
  <key>NSBonjourServices</key><array><string>_miroolink._tcp</string></array>
  <key>NSScreenCaptureUsageDescription</key><string>Miroo captures the extra display it creates so it can show it on your iPhone.</string>
</dict></plist>
PLIST
  codesign --force --sign "$IDENT" --identifier $BID "$APP"
  echo "built $APP"
}
make_app Miroo MirooApp Miroo
make_app MirooLinkHost miroo-host MirooLinkHost
