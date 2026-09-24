#!/bin/bash
set -e

#
# build_mac_app.sh
# Packages MirooMac into a standalone macOS Application Bundle (MirooMac.app)
# and optional DMG installer for production distribution.
#

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/Release"
APP_NAME="MirooMac.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "=================================================="
echo "    Miroo macOS Production App Packaging (Phase 12)"
echo "=================================================="

# 1. Compile Release Binary with SPM
echo "[1/5] Compiling release binary with Swift Package Manager..."
cd "$ROOT_DIR"
swift build -c release --product MirooMac

SPM_BIN_PATH="$ROOT_DIR/.build/release/MirooMac"
if [ ! -f "$SPM_BIN_PATH" ]; then
    # In Xcode / SPM new layout, check Products/Release
    SPM_BIN_PATH="$(find "$ROOT_DIR/.build" -name "MirooMac" -type f -perm +111 | grep -E "release|Release" | head -n 1)"
fi

if [ ! -f "$SPM_BIN_PATH" ]; then
    echo "ERROR: Compiled MirooMac binary not found!"
    exit 1
fi

echo "Found release binary at: $SPM_BIN_PATH"

# 2. Assemble .app Directory Structure
echo "[2/5] Assembling $APP_NAME bundle layout..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$SPM_BIN_PATH" "$MACOS_DIR/MirooMac"
chmod +x "$MACOS_DIR/MirooMac"

# 3. Write Production Info.plist
echo "[3/5] Generating Info.plist..."
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.miroo.MirooMac</string>
    <key>CFBundleName</key>
    <string>Miroo</string>
    <key>CFBundleDisplayName</key>
    <string>Miroo</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleExecutable</key>
    <string>MirooMac</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Miroo requires screen capture access to stream your extended display to your iPhone.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Miroo requires local network access to stream display content to your iPhone.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_miroo._tcp</string>
    </array>
</dict>
</plist>
EOF

# 4. Code Sign with Ad-Hoc Signature
echo "[4/5] Applying ad-hoc code signature..."
codesign --force --deep --sign - "$APP_DIR"

# 5. Optional DMG Packaging
echo "[5/5] Packaging optional DMG installer..."
DMG_PATH="$BUILD_DIR/Miroo.dmg"
rm -f "$DMG_PATH"
if command -v hdiutil &>/dev/null; then
    hdiutil create -volname "Miroo" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH" > /dev/null
    echo "Created DMG at: $DMG_PATH"
fi

echo "=================================================="
echo "🎉 MirooMac.app successfully built and packaged!"
echo "   Bundle: $APP_DIR"
if [ -f "$DMG_PATH" ]; then
    echo "   DMG:    $DMG_PATH"
fi
echo "=================================================="
