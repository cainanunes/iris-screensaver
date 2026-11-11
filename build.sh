#!/bin/zsh
# Build + instalação do protetor Iris sem Xcode (só Command Line Tools).
# Uso: ./build.sh            → compila e instala em ~/Library/Screen Savers
#      ./build.sh --no-install
set -euo pipefail
cd "$(dirname "$0")"

NAME=IrisScreenSaver
OUT="build/$NAME.saver"
ARCH="$(uname -m)"   # arm64 no M5

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
  # Derruba o host de protetores legados para ele recarregar o bundle novo
  killall legacyScreenSaver 2>/dev/null || true
  echo "✓ instalado em $DEST"
  echo "  Ajustes → Papel de Parede e Protetor de Tela → Iris (fechar e reabrir os Ajustes se não aparecer)"
fi
