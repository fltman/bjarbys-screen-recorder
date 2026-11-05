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

echo "→ bygger ($KONFIG)"
xcodebuild -project Skarminspelare.xcodeproj -scheme Skarminspelare \
    -configuration "$KONFIG" -derivedDataPath build \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="$IDENTITET" DEVELOPMENT_TEAM="$TEAM" \
    -quiet build

BYGGD="build/Build/Products/$KONFIG/Skarminspelare.app"
echo "→ kopierar till $APP_UT"
rm -rf "$APP_UT"
mkdir -p dist
# Att döpa om .app-mappen bryter inte signaturen; den täcker innehållet.
ditto "$BYGGD" "$APP_UT"

# whisper.cpp:s verktyg i appen (Contents/Helpers), så att talet fungerar utan whisper.cpp.
# Byggs med scripts/build-whisper.sh; saknas de byggs appen utan (då krävs en whisper.cpp-mapp).
# SKARMINSPELARE_TIDSSTAMPEL=1 (release.sh) ger säker tidsstämpel, som notariseringen kräver.
TS="--timestamp=none"; [ "${SKARMINSPELARE_TIDSSTAMPEL:-0}" = 1 ] && TS="--timestamp"
HJALP=build/whisper-static
if [ ! -x "$HJALP/bin/whisper-cli" ] && [ -f "${WHISPER_CPP:-$HOME/Projekt/whisper.cpp}/CMakeLists.txt" ]; then
    ./scripts/build-whisper.sh
fi
if [ -x "$HJALP/bin/whisper-cli" ] && [ -x "$HJALP/bin/vad-speech-segments" ]; then
    echo "→ lägger whisper-verktygen i appen"
    mkdir -p "$APP_UT/Contents/Helpers" "$APP_UT/Contents/Resources/Licenses"
    cp "$HJALP/bin/whisper-cli" "$HJALP/bin/vad-speech-segments" "$APP_UT/Contents/Helpers/"
    cp "$HJALP/LICENSE" "$APP_UT/Contents/Resources/Licenses/whisper.cpp-LICENSE.txt"
    for h in "$APP_UT/Contents/Helpers/"*; do
        codesign --force --sign "$IDENTITET" --options runtime $TS "$h"
    done
    codesign --force --sign "$IDENTITET" --options runtime $TS \
        --preserve-metadata=entitlements,requirements,flags "$APP_UT"
elif [ "$TS" = "--timestamp" ]; then
    echo "✗ whisper-verktygen saknas (scripts/build-whisper.sh)"; exit 1
else
    echo "  (utan whisper-verktyg: kör scripts/build-whisper.sh för att få med dem)"
fi
if [ "$TS" = "--timestamp" ]; then
    codesign --force --sign "$IDENTITET" --options runtime --timestamp \
        --preserve-metadata=entitlements,requirements,flags "$APP_UT"
fi

codesign --verify --deep --strict --verbose=1 "$APP_UT" 2>&1 | sed 's/^/  /'
# Bara dist-appen ska vara registrerad: annars kan `open`, URL-schemat och Genvägar
# starta byggkopian i build/ (samma bundle-id), som Dock dessutom visar utan ikon.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$PWD/$BYGGD" 2>/dev/null || true
"$LSREG" -f "$PWD/$APP_UT" 2>/dev/null || true
plutil -p "$APP_UT/Contents/Info.plist" | grep -q NSAudioCaptureUsageDescription \
    || { echo "✗ NSAudioCaptureUsageDescription saknas i den byggda Info.plist"; exit 1; }
echo "→ klart: $APP_UT"
