#!/bin/bash
# En nedladdningsbar, notariserad app — med Xcodes konto, utan lösenord i skriptet:
#   dist/Bjarbys-skarminspelare-<version>.zip (+ .sha256), kopia i site/download/.
#
# 1. Arkiv med Developer ID (byggsteget «Whisper-verktygen» lägger whisper.cpp:s verktyg i appen).
# 2. xcodebuild -exportArchive med destination «upload»: Xcode skickar appen till Apples
#    notarisering med kontot under Xcode › Inställningar › Konton (betalt utvecklarkonto, team
#    V783A2L763).
# 3. När Apple är klar hämtar xcodebuild -exportNotarizedApp appen med biljetten häftad.
# 4. Zip: en notariserad, häftad app i en zip behöver ingen egen notarisering och öppnas även utan
#    nät. (En DMG skulle behöva notariseras för sig, vilket kräver notarytool och lösenord.)
# `--hamta`: arkivet är redan uppladdat — vänta bara in Apple, hämta, kontrollera och packa.
set -euo pipefail
cd "$(dirname "$0")/.."
HAMTA=0; [ "${1:-}" = "--hamta" ] && HAMTA=1

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEAM="${SKARMINSPELARE_TEAM:-V783A2L763}"
NAMN="Bjarbys skärminspelare"
RELEASE=build/release
ARKIV="$RELEASE/Skarminspelare.xcarchive"

if [ "$HAMTA" = 0 ]; then
[ -x build/whisper-static/bin/whisper-cli ] || ./scripts/build-whisper.sh
rm -rf "$RELEASE"; mkdir -p "$RELEASE" dist

echo "→ arkiverar"
xcodebuild -project Skarminspelare.xcodeproj -scheme Skarminspelare -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARKIV" \
    CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual \
    -quiet archive
fi
I_ARKIV="$ARKIV/Products/Applications/Skarminspelare.app"
[ -x "$I_ARKIV/Contents/Helpers/whisper-cli" ] || { echo "✗ whisper-verktygen saknas i arkivet"; exit 1; }
VERSION=$(plutil -extract CFBundleShortVersionString raw "$I_ARKIV/Contents/Info.plist")
BYGGE=$(plutil -extract CFBundleVersion raw "$I_ARKIV/Contents/Info.plist")

if [ "$HAMTA" = 0 ]; then

cat > "$RELEASE/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST

echo "→ skickar $VERSION ($BYGGE) till Apples notarisering med Xcodes konto"
xcodebuild -exportArchive -archivePath "$ARKIV" -exportOptionsPlist "$RELEASE/ExportOptions.plist" \
    -exportPath "$RELEASE/uppladdad" -allowProvisioningUpdates
fi

echo "→ väntar på Apple (brukar ta några minuter)"
for i in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARKIV" -exportPath "$RELEASE/notariserad" >"$RELEASE/hamta.log" 2>&1; then
        break
    fi
    [ "$i" = 60 ] && { echo "✗ notariseringen blev inte klar på 30 min:"; tail -5 "$RELEASE/hamta.log"; exit 1; }
    sleep 30
done

APP="$RELEASE/$NAMN.app"
ditto "$RELEASE/notariserad/Skarminspelare.app" "$APP"
echo "→ kontrollerar"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute -vv "$APP" 2>&1 | tee "$RELEASE/gatekeeper.log"
grep -q 'Notarized Developer ID' "$RELEASE/gatekeeper.log" || { echo "✗ Gatekeeper ser inte appen som notariserad"; exit 1; }

ZIP="dist/Bjarbys-skarminspelare-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
mkdir -p site/download
cp "$ZIP" site/download/Bjarbys-skarminspelare.zip
echo "$VERSION" > site/download/VERSION
echo "→ klart: $ZIP ($(du -h "$ZIP" | cut -f1)), kopia i site/download/"
