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

codesign --verify --strict --verbose=1 "$APP_UT" 2>&1 | sed 's/^/  /'
plutil -p "$APP_UT/Contents/Info.plist" | grep -q NSAudioCaptureUsageDescription \
    || { echo "✗ NSAudioCaptureUsageDescription saknas i den byggda Info.plist"; exit 1; }
echo "→ klart: $APP_UT"
