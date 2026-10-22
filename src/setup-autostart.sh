#!/bin/zsh
set -euo pipefail
INSTALLED_APP="$HOME/Applications/DictadoMac.app"
AGENT_LABEL=es.jorge.dictadomac.autostart
AGENT_PATH="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
SUPPORT_DIR="$HOME/Library/Application Support/DictadoMac"
[[ -x "$INSTALLED_APP/Contents/MacOS/DictadoMac" ]] || { print -u2 'Instala primero Dictado Mac.'; exit 1; }
if pgrep -x DictadoMac >/dev/null; then
  print -u2 'Sal de Dictado Mac desde su menú antes de configurar el inicio automático.'
  exit 1
fi
mkdir -p "$HOME/Library/LaunchAgents" "$SUPPORT_DIR"
if [[ -f "$AGENT_PATH" ]]; then cp -p "$AGENT_PATH" "$SUPPORT_DIR/autostart.previous.plist"; fi
/usr/bin/python3 - "$AGENT_PATH" "$INSTALLED_APP" "$SUPPORT_DIR" <<'PY'
import plistlib, sys
destination, app, support = sys.argv[1:]
config = {
    'Label': 'es.jorge.dictadomac.autostart',
    'ProgramArguments': [app+'/Contents/MacOS/DictadoMac', '--autostart'],
    'RunAtLoad': True,
    'KeepAlive': {'SuccessfulExit': False},
    'LimitLoadToSessionType': 'Aqua',
    'ProcessType': 'Interactive',
    'ThrottleInterval': 5,
    'ExitTimeOut': 5,
    'StandardOutPath': support+'/startup.log',
    'StandardErrorPath': support+'/startup.log'
}
with open(destination, 'wb') as output: plistlib.dump(config, output)
PY
plutil -lint "$AGENT_PATH"
launchctl bootout "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
for ATTEMPT in {1..30}; do
  if ! launchctl print "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
launchctl bootstrap "gui/$UID" "$AGENT_PATH"
launchctl print "gui/$UID/$AGENT_LABEL"
