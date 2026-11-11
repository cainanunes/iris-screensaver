#!/bin/zsh
# Build and install the Iris screensaver without Xcode (Command Line Tools only).
# Usage: ./build.sh            → build and install to ~/Library/Screen Savers
#        ./build.sh --no-install
set -euo pipefail
cd "$(dirname "$0")"

NAME=IrisScreenSaver
OUT="build/$NAME.saver"
ARCH="$(uname -m)"

rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "→ swiftc ($ARCH)"
swiftc -O \
  -target "$ARCH-apple-macos13.0" \
  -module-name "$NAME" \
  -emit-library \
  -o "$OUT/Contents/MacOS/$NAME" \
  -framework ScreenSaver -framework Metal -framework QuartzCore -framework IOSurface -framework AppKit \
  Sources/*.swift

cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp Sources/iris.metal "$OUT/Contents/Resources/iris.metal"

echo "→ codesign (ad hoc)"
codesign --force --deep --sign - "$OUT"

echo "✓ $OUT"

if [[ "${1:-}" != "--no-install" ]]; then
  DEST="$HOME/Library/Screen Savers/$NAME.saver"
  rm -rf "$DEST"
  cp -R "$OUT" "$DEST"
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  # Kill the legacy screensaver host so it reloads the new bundle
  killall legacyScreenSaver 2>/dev/null || true
  echo "✓ installed to $DEST"
  echo "  System Settings → Screen Saver → Iris (quit and reopen System Settings if it does not show up)"
fi
