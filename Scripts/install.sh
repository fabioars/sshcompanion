#!/bin/bash
# Build Release do SSH Companion, instalação em /Applications e extensão do Raycast.
#
# Uso: Scripts/install.sh [--no-raycast] [--dest /Applications]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications"
WITH_RAYCAST=1
for arg in "$@"; do
    case "$arg" in
        --no-raycast) WITH_RAYCAST=0 ;;
        --dest=*) DEST="${arg#--dest=}" ;;
        --dest) shift; DEST="$1" ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    esac
done

DERIVED="$ROOT/build/Release"
APP_NAME="SSHCompanion.app"
BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME"
INSTALLED_APP="$DEST/$APP_NAME"

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }

step "Build Release"
xcodebuild \
    -project "$ROOT/SSHCompanion.xcodeproj" \
    -scheme SSHCompanion \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation \
    -quiet build
[ -d "$BUILT_APP" ] || { echo "App não encontrado em $BUILT_APP" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$BUILT_APP/Contents/Info.plist")"
echo "SSH Companion $VERSION compilado."

step "Instalar em $DEST"
if pgrep -x SSHCompanion >/dev/null; then
    echo "Encerrando a instância em execução…"
    osascript -e 'tell application "SSHCompanion" to quit' 2>/dev/null || pkill -x SSHCompanion || true
    sleep 1
fi
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
echo "Copiado para $INSTALLED_APP"

step "Registrar esquema sshcompanion://"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# Cópias de build (Debug/Release) também registram o esquema; remove para que /Applications responda.
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
for debug_app in "$HOME"/Library/Developer/Xcode/DerivedData/SSHCompanion-*/Build/Products/Debug/SSHCompanion.app; do
    [ -d "$debug_app" ] && "$LSREGISTER" -u "$debug_app" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
echo "Pronto: open 'sshcompanion://connect?server=nome' abre o app."

if [ "$WITH_RAYCAST" = 1 ]; then
    step "Extensão do Raycast"
    if [ ! -d /Applications/Raycast.app ]; then
        echo "Raycast não encontrado em /Applications; pulando."
    elif ! command -v npm >/dev/null; then
        echo "npm não encontrado; instale Node.js e rode: cd raycast && npm install && npx ray develop"
    else
        cd "$ROOT/raycast"
        npm install --silent --no-audit --no-fund
        npx ray build -e dist >/dev/null
        # `ray develop` registra a extensão no Raycast; alguns segundos bastam para a importação.
        npx ray develop >/tmp/sshcompanion-ray-develop.log 2>&1 &
        RAY_PID=$!
        sleep 12
        kill "$RAY_PID" 2>/dev/null || true
        echo "Extensão importada em modo desenvolvimento. No Raycast, procure o comando \"SSH\"."
        echo "Log: /tmp/sshcompanion-ray-develop.log"
    fi
fi

step "Concluído"
echo "Abra $INSTALLED_APP uma vez para gerar o índice de servidores usado pelo Raycast."
