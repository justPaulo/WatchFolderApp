#!/bin/bash
# Builds WatchFolder.app (arm64 only) with the Command Line Tools — no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="WatchFolder"
BUNDLE_ID="com.example.WatchFolder"
VERSION="1.0"
OUT="build"
APP="$OUT/$APP_NAME.app"

if [ "$(uname -m)" != "arm64" ]; then
    echo "warning: this machine is not arm64; cross-building with --arch arm64" >&2
fi

echo "==> Compiling (release, arm64)"
swift build -c release --arch arm64 --product "$APP_NAME"
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing"
codesign --force --sign - "$APP"

echo "==> Verifying architecture"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"

echo "Done: $APP   (open it with: open $APP)"
