#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Linelens.app"
DEST="/Applications/$APP_NAME"
BUNDLE_ID="com.kotaro.linelens"
EXECUTABLE_NAME="Linelens"

SIGN_ID="4916E1C0238028347FB81F66F4D47798C09F686C"

echo "Building (Release)..."
swift build -c release --package-path "$PROJECT_DIR" >/dev/null
BIN="$(swift build -c release --package-path "$PROJECT_DIR" --show-bin-path)/$EXECUTABLE_NAME"
[ -x "$BIN" ] || { echo "Build product not found at $BIN" >&2; exit 1; }

echo "Rendering app icon..."
ICON_PNG="$PROJECT_DIR/.build/icon.png"
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
swift "$PROJECT_DIR/make-icon.swift" "$ICON_PNG" >/dev/null
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz       "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}.png"     >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/.build/AppIcon.icns"

echo "Assembling ${APP_NAME}..."
STAGE="$PROJECT_DIR/.build/$APP_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/$EXECUTABLE_NAME"
cp "$PROJECT_DIR/.build/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Linelens</string>
  <key>CFBundleDisplayName</key><string>Linelens</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Linelens</string>
</dict>
</plist>
PLIST

echo "Quitting any running instance..."
pkill -f "$APP_NAME/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || true
sleep 1

echo "Installing to ${DEST}..."
rm -rf "$DEST"
cp -R "$STAGE" "$DEST"

echo "Signing with stable identity..."
xattr -cr "$DEST"
codesign --force --deep --options runtime --sign "$SIGN_ID" "$DEST" 2>/dev/null \
  || codesign --force --deep --sign "$SIGN_ID" "$DEST"

echo "Launching..."
open "$DEST"

echo "Linelens installed and running."
echo "  Press ⌘⇧2 (or click the menu-bar icon) to capture text. Quit from the menu."
