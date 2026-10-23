#!/bin/bash
# Instala o actualiza Dictado Mac desde GitHub y la deja arrancando al iniciar sesión.
# Primera instalación (una sola vez por Mac, en Terminal):
#   curl -fsSL https://raw.githubusercontent.com/jorgemoraz/dictado-mac/main/instalar.sh | bash
# Desinstalar (conserva ajustes, diccionario y certificado):
#   curl -fsSL https://raw.githubusercontent.com/jorgemoraz/dictado-mac/main/instalar.sh | bash -s -- desinstalar
# La propia app llama a este script con «--auto <sha>» cuando detecta una versión nueva en main.
set -uo pipefail

REPO="jorgemoraz/dictado-mac"
BIN="DictadoMac"
LABEL="es.jorge.dictadomac.autostart"
CERT_NAME="DictadoMac Local Code Signing"
DEST="$HOME/Applications/DictadoMac.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/DictadoMac"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DOMAIN="gui/$(id -u)"
MODE="${1:-}"
SHA="${2:-}"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

mkdir -p "$SUPPORT"
say() { echo "[$(date '+%Y-%m-%d %H.%M.%S')] $*"; }
fail() {
  say "ERROR: $*"
  [[ -n "$SHA" ]] && echo "$SHA" > "$SUPPORT/failed"
  [[ "$MODE" == "--auto" ]] && /usr/bin/osascript -e 'display notification "La actualización no se ha podido instalar. Sigue la versión anterior." with title "Dictado Mac"' >/dev/null 2>&1
  exit 1
}

if [[ "$MODE" == "desinstalar" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -x "$BIN" 2>/dev/null || true
  rm -rf "$DEST" "$AGENT"
  echo "Desinstalada. Ajustes, diccionario y certificado se conservan."
  exit 0
fi

xcrun --find swiftc >/dev/null 2>&1 || fail "Faltan las Command Line Tools de Xcode. Ejecuta: xcode-select --install y repite."

# Identidad de firma local y estable: con ella macOS conserva Micrófono y Accesibilidad entre versiones.
if ! security find-identity -p codesigning | grep -q "$CERT_NAME"; then
  if [[ "$MODE" == "--auto" ]]; then
    # Sin firma estable, actualizar quitaría el permiso de Accesibilidad sin avisar.
    fail "No hay identidad de firma en este Mac. Ejecuta el instalador una vez a mano."
  fi
  say "Creando la identidad de firma local (solo existe en este Mac)…"
  TMP="$(mktemp -d)"
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CFG
  PASS="$(/usr/bin/openssl rand -hex 16)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null \
    && /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$CERT_NAME" \
      -passout "pass:$PASS" -out "$TMP/id.p12" \
    && security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
  STATUS=$?
  rm -rf "$TMP"
  (( STATUS == 0 )) || fail "No se ha podido crear la identidad de firma."
  echo
  echo "Para que las actualizaciones firmen sin preguntar, escribe la contraseña de este Mac"
  echo "(la de iniciar sesión; no se ve al escribir) y pulsa Intro:"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$CERT_NAME" "$KEYCHAIN" </dev/tty >/dev/null \
    && say "Llavero preparado." \
    || say "No se ha ajustado el llavero: si aparece un aviso al firmar, pulsa «Permitir siempre»."
fi

if [[ -z "$SHA" ]]; then
  # Último commit que cambia la app de Mac (src/), el mismo que comprueba la app para actualizarse.
  SHA="$(curl -fsSL "https://api.github.com/repos/$REPO/commits?sha=main&path=src&per_page=1" \
    | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)" \
    || fail "No se ha podido consultar GitHub."
fi
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "Commit no válido: $SHA"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
say "Descargando la versión ${SHA:0:7}…"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$SHA" | tar -xz -C "$BUILD_DIR" --strip-components 1 \
  || fail "No se ha podido descargar ${SHA:0:7}."
cd "$BUILD_DIR" || fail "Carpeta temporal no disponible."
mkdir -p build/module-cache

for TEST_DIR in tests/*/; do
  NAME="$(basename "$TEST_DIR")"
  [[ -f "$TEST_DIR/fuentes.txt" ]] || continue
  SOURCES=()
  while IFS= read -r FILE; do [[ -n "$FILE" ]] && SOURCES+=("src/$FILE"); done < "$TEST_DIR/fuentes.txt"
  say "Pruebas: $NAME"
  CLANG_MODULE_CACHE_PATH=build/module-cache xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 \
      "${SOURCES[@]}" "$TEST_DIR/main.swift" -o "build/pruebas-$NAME" >/dev/null \
    && "./build/pruebas-$NAME" | tail -1 \
    || fail "Fallan las pruebas «$NAME» de ${SHA:0:7}."
done

say "Compilando…"
DM_COMMIT="$SHA" zsh src/build-app.sh "$BUILD_DIR/build" >/dev/null || fail "No compila la versión ${SHA:0:7}."
codesign --verify --deep --strict "build/DictadoMac.app" || fail "Firma no válida."

# No reiniciar en mitad de un dictado (la app marca «dictando» mientras graba).
for _ in $(seq 1 120); do
  FLAG="$SUPPORT/dictando"
  [[ -f "$FLAG" ]] && kill -0 "$(cat "$FLAG" 2>/dev/null)" 2>/dev/null || break
  sleep 1
done

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
NEW_PLIST="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/$BIN</string><string>--autostart</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$SUPPORT/startup.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT/startup.log</string>
</dict>
</plist>
EOF
)"

if [[ "$MODE" == "--auto" && -f "$AGENT" && "$(cat "$AGENT")" == "$NEW_PLIST" ]]; then
  # La copia en marcha conserva su ejecutable; kickstart la reinicia con la nueva.
  rm -rf "$DEST" && ditto "build/DictadoMac.app" "$DEST" || fail "No se ha podido copiar la app."
  launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || open -g "$DEST" --args --autostart
else
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -x "$BIN" 2>/dev/null || true
  sleep 1
  if [[ -d "$DEST" && ! -d "$SUPPORT/anterior.app" ]]; then ditto "$DEST" "$SUPPORT/anterior.app"; fi
  rm -rf "$DEST" && ditto "build/DictadoMac.app" "$DEST" || fail "No se ha podido copiar la app."
  printf '%s\n' "$NEW_PLIST" > "$AGENT"
  launchctl bootstrap "$DOMAIN" "$AGENT" || open "$DEST"
fi

echo "$SHA" > "$SUPPORT/version"
rm -f "$SUPPORT/failed"
VERSION="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
say "Listo: Dictado Mac $VERSION (${SHA:0:7}) instalada. Se actualizará sola desde GitHub."
if [[ "$MODE" == "--auto" ]]; then
  /usr/bin/osascript -e "display notification \"Versión $VERSION (${SHA:0:7}) instalada.\" with title \"Dictado Mac\"" >/dev/null 2>&1
else
  echo "Si es la primera vez con esta firma: Ajustes del Sistema → Privacidad y seguridad → Accesibilidad,"
  echo "quita «Dictado Mac» con − y vuelve a activarla. A partir de ahora se conserva en cada actualización."
fi
