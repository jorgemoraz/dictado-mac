#!/bin/zsh
set -euo pipefail
SOURCE_DIR="${0:A:h}"
BUILD_DIR="${1:-${SOURCE_DIR:h}/build}"
SIGNING_CERT="DictadoMac Local Code Signing"
mkdir -p "$BUILD_DIR/module-cache"
APP_PATH="$BUILD_DIR/DictadoMac.app"
mkdir -p "$APP_PATH/Contents/MacOS"
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache" swiftc -O -swift-version 6 \
  -target arm64-apple-macos26.0 -parse-as-library "$SOURCE_DIR"/*.swift \
  -o "$APP_PATH/Contents/MacOS/DictadoMac" \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework ApplicationServices -framework Carbon -framework Speech -framework FoundationModels
cp -X "$SOURCE_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
# Las copias instaladas desde GitHub llevan su commit: así la app sabe si hay versión nueva.
if [[ -n "${DM_COMMIT:-}" ]]; then
  plutil -replace DMCommit -string "$DM_COMMIT" "$APP_PATH/Contents/Info.plist"
fi
plutil -lint "$APP_PATH/Contents/Info.plist"
CERT_SHA1="$(security find-identity -p codesigning | awk '/"DictadoMac Local Code Signing"/ {print $2; exit}')"
if [[ ! "$CERT_SHA1" =~ '^[0-9A-Fa-f]{40}$' ]]; then
  if [[ "${ALLOW_ADHOC:-0}" == "1" ]]; then
    print -u2 'Sin certificado local: firma ad hoc (en este Mac habrá que conceder permisos de nuevo tras cada recompilación).'
    xattr -cr "$APP_PATH" 2>/dev/null || true
    codesign --force --sign - --identifier es.jorge.dictadomac "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    print "App preparada: $APP_PATH"
    exit 0
  fi
  print -u2 'Falta la identidad estable de Dictado Mac en el llavero. No se usará una firma ad hoc.'
  exit 2
fi
# Only Finder metadata is removable; preserve quarantine and security attributes.
xattr -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
xattr -d com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
codesign --force --sign "$CERT_SHA1" --identifier es.jorge.dictadomac \
  --requirements "=designated => identifier \"es.jorge.dictadomac\" and certificate leaf = H\"$CERT_SHA1\"" \
  --timestamp=none "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --requirements - "$APP_PATH"
print "App preparada: $APP_PATH"
