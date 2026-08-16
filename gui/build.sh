#!/bin/bash
# Builds OBSBOT Control.app: a menubar app controlling the OBSBOT Meet 2.
# Route (A): links the vendored VVUVCKit framework directly via a bridging header.
set -e
cd "$(dirname "$0")"

APP="OBSBOT Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"

# Self-contained bundle: copy the vendored frameworks in and point rpath at them.
cp -R ../vendor/VVUVCKit.framework ../vendor/USBBusProber.framework "$APP/Contents/Frameworks/"

swiftc ObsbotApp.swift \
  -parse-as-library \
  -import-objc-header Bridging.h \
  -F ../vendor \
  -framework VVUVCKit \
  -framework Cocoa -framework IOKit -framework AVFoundation -framework CoreMedia \
  -framework CoreAudio -framework AudioToolbox \
  -target arm64-apple-macos13.0 \
  -O \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/OBSBOT Control"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>design.constellation.obsbot-control</string>
    <key>CFBundleName</key><string>OBSBOT Control</string>
    <key>CFBundleExecutable</key><string>OBSBOT Control</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key><string>Shows a live preview of your OBSBOT camera while you adjust its settings.</string>
    <key>NSMicrophoneUsageDescription</key><string>Shows a live level meter for your OBSBOT microphone.</string>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS will run it.
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Built: $(pwd)/$APP"
