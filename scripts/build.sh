#!/bin/bash
# Bygger och signerar «Bjarbys skärminspelare.app» till dist/.
# xcode-select pekar på Command Line Tools på den här datorn; vi pekar ut
# Xcode per anrop i stället för att ändra systemet.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
KONFIG="${1:-Release}"
# Bygger du en egen kopia: sätt din egen identitet och ditt team-id.
IDENTITET="${SKARMINSPELARE_SIGNERING:-Developer ID Application: Brattoo AB (V783A2L763)}"
TEAM="${SKARMINSPELARE_TEAM:-V783A2L763}"
APP_UT="dist/Bjarbys skärminspelare.app"

# whisper.cpp:s verktyg följer med appen (byggsteget «Whisper-verktygen» i Xcode lägger dem i
# Contents/Helpers). Byggs här första gången om en whisper.cpp-mapp finns.
if [ ! -x build/whisper-static/bin/whisper-cli ] && [ -f "${WHISPER_CPP:-$HOME/Projekt/whisper.cpp}/CMakeLists.txt" ]; then
    ./scripts/build-whisper.sh
fi

# Byggnumret = antalet commits. macOS (Dock, Finder) cachar appikonen per bundle-id, version och
# appmappens ändringstid: med samma nummer i varje bygge visade Dock den ikonlösa allra första
# versionen i ett dygn efter att ikonen kommit till.
BYGGNUMMER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "→ bygger ($KONFIG, bygge $BYGGNUMMER)"
xcodebuild -project Skarminspelare.xcodeproj -scheme Skarminspelare \
    -configuration "$KONFIG" -derivedDataPath build \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="$IDENTITET" DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BYGGNUMMER" \
    -quiet build

BYGGD="build/Build/Products/$KONFIG/Skarminspelare.app"
echo "→ kopierar till $APP_UT"
rm -rf "$APP_UT"
mkdir -p dist
# Att döpa om .app-mappen bryter inte signaturen; den täcker innehållet.
ditto "$BYGGD" "$APP_UT"
# ditto behåller byggkatalogens ändringstid (Xcode skapar .app-mappen bara en gång), och
# ikoncachen går på den: ny tid för varje bygge.
touch "$APP_UT"

codesign --verify --deep --strict --verbose=1 "$APP_UT" 2>&1 | sed 's/^/  /'
# Bara dist-appen ska vara registrerad: annars kan `open`, URL-schemat och Genvägar
# starta byggkopian i build/ (samma bundle-id), som Dock dessutom visar utan ikon.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$PWD/$BYGGD" 2>/dev/null || true
"$LSREG" -f "$PWD/$APP_UT" 2>/dev/null || true
plutil -p "$APP_UT/Contents/Info.plist" | grep -q NSAudioCaptureUsageDescription \
    || { echo "✗ NSAudioCaptureUsageDescription saknas i den byggda Info.plist"; exit 1; }
echo "→ klart: $APP_UT"
