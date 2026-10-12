#!/bin/zsh
# Builds release binaries and wraps each in a .app bundle with its own Info.plist,
# so macOS asks for Bluetooth permission for that bundle (ad-hoc signed, unsandboxed).
#   build/MS-100BT Link.app   the SwiftUI app
#   build/zoomprobe.app       the CLI, launched through scripts/zoomprobe
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product MS100BTLinkApp
swift build -c release --product zoomprobe
BIN=$(swift build -c release --show-bin-path)

make_bundle() { # name exec_name bundle_id extra_plist_keys
  local app="build/$1.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$BIN/$2" "$app/Contents/MacOS/$2"
  mkdir -p "$app/Contents/Resources"
  cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Anthony Essaye (anthonyessaye@outlook.com). MIT License.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Connects to the Zoom MS-100BT pedal over Bluetooth to read and edit its patches, and to Bluetooth MIDI controllers.</string>
  $4
</dict>
</plist>
EOF
  codesign --force --sign - "$app"
  echo "built $app"
}

make_bundle "MS-100BT Link" MS100BTLinkApp com.anthonyessaye.ms100bt "<key>NSHighResolutionCapable</key><true/>"
make_bundle "zoomprobe" zoomprobe com.anthonyessaye.ms100bt.zoomprobe "<key>LSBackgroundOnly</key><true/>"
