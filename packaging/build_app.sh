#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TokenScope"
BUNDLE_ID="com.tokenscope.app"
VERSION="1.1.5"
BUILD_DIR="$ROOT/dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
rm -rf "$APP_DIR" "$BUILD_DIR/TokenScope.iconset"
mkdir -p "$MACOS" "$RESOURCES"

printf 'Building universal release executable (arm64 + x86_64)...\n'
ARCH_FLAGS="--arch arm64 --arch x86_64"
swift build -c release --product TokenScope $ARCH_FLAGS
EXECUTABLE="$(swift build -c release --product TokenScope $ARCH_FLAGS --show-bin-path)/TokenScope"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Missing release executable: $EXECUTABLE" >&2
  exit 1
fi
cp "$EXECUTABLE" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

printf 'Generating simple app icon...\n'
ICONSET="$BUILD_DIR/TokenScope.iconset"
mkdir -p "$ICONSET"
python3 - <<'PY' "$ICONSET"
import os, sys, subprocess
iconset = sys.argv[1]
svg = os.path.join(iconset, 'base.svg')
with open(svg, 'w') as f:
    f.write('''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#eafaff"/><stop offset="0.45" stop-color="#72e7ff"/><stop offset="1" stop-color="#8c4dff"/></linearGradient><filter id="s"><feDropShadow dx="0" dy="24" stdDeviation="30" flood-opacity="0.25"/></filter></defs>
<rect x="64" y="64" width="896" height="896" rx="188" fill="url(#g)" filter="url(#s)"/>
<rect x="170" y="242" width="684" height="540" rx="48" fill="rgba(255,255,255,0.62)" stroke="#143a7a" stroke-width="28"/>
<path d="M246 420h532M246 532h410M246 644h280" stroke="#10264f" stroke-width="54" stroke-linecap="round"/>
<circle cx="742" cy="642" r="64" fill="#7728ff"/><circle cx="742" cy="642" r="28" fill="#07e6ff"/>
</svg>''')
sizes = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for size, scale in sizes:
    px = size * scale
    name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
    out = os.path.join(iconset, name)
    subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', '--resampleHeightWidth', str(px), str(px), svg, '--out', out], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" >/dev/null 2>&1 || true

printf 'Ad-hoc signing app...\n'
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

printf '\nBuilt app bundle:\n  %s\n' "$APP_DIR"
