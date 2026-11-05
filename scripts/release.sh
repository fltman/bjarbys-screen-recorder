#!/bin/bash
# En nedladdningsbar, notariserad DMG: dist/Bjarbys-skarminspelare-<version>.dmg (+ .sha256),
# och en kopia som site/download/Bjarbys-skarminspelare.dmg för produktsajten.
#
# 1. Appen byggs med whisper-verktygen och säker tidsstämpel (build.sh).
# 2. Appen notariseras och biljetten häftas på appen — då öppnas den även utan nät efter att
#    den kopierats ur skivavbilden.
# 3. DMG:n görs, signeras, notariseras och får sin biljett.
#
# Notariseringen kräver en sparad profil (en gång, i Terminal, med ett appspecifikt lösenord
# från appleid.apple.com):
#   xcrun notarytool store-credentials skarminspelare --apple-id <din-apple-id> --team-id V783A2L763
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROFIL="${SKARMINSPELARE_NOTARY:-skarminspelare}"
IDENTITET="${SKARMINSPELARE_SIGNERING:-Developer ID Application: Brattoo AB (V783A2L763)}"
APP="dist/Bjarbys skärminspelare.app"

if ! xcrun notarytool history --keychain-profile "$PROFIL" >/dev/null 2>&1; then
    echo "✗ ingen notarytool-profil «${PROFIL}». Kör en gång i Terminal:"
    echo "  xcrun notarytool store-credentials $PROFIL --apple-id <din-apple-id> --team-id V783A2L763"
    exit 2
fi

SKARMINSPELARE_TIDSSTAMPEL=1 ./scripts/build.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BYGGE=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
DMG="dist/Bjarbys-skarminspelare-$VERSION.dmg"

# Kontroller före Apple: tidsstämpel, hardened runtime, verktygen med.
codesign -dvv "$APP" 2>&1 | grep -q '^Timestamp=' || { echo "✗ appen saknar säker tidsstämpel"; exit 1; }
codesign -dvv "$APP" 2>&1 | grep -q 'flags=.*runtime' || { echo "✗ appen saknar hardened runtime"; exit 1; }
[ -x "$APP/Contents/Helpers/whisper-cli" ] || { echo "✗ whisper-verktygen saknas i appen"; exit 1; }
codesign --verify --deep --strict "$APP"

ARBETE=$(mktemp -d)
trap 'rm -rf "$ARBETE"' EXIT

echo "→ notariserar appen ($VERSION, bygge $BYGGE)"
ditto -c -k --keepParent "$APP" "$ARBETE/app.zip"
xcrun notarytool submit "$ARBETE/app.zip" --keychain-profile "$PROFIL" --wait
xcrun stapler staple "$APP"

echo "→ skivavbild"
mkdir "$ARBETE/innehall"
ditto "$APP" "$ARBETE/innehall/Bjarbys skärminspelare.app"
ln -s /Applications "$ARBETE/innehall/Applications"
rm -f "$DMG"
hdiutil create -volname "Bjarbys skärminspelare" -srcfolder "$ARBETE/innehall" -fs APFS -format ULFO -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITET" --timestamp "$DMG"

echo "→ notariserar skivavbilden"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFIL" --wait
xcrun stapler staple "$DMG"

echo "→ Gatekeeper"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type execute -vv "$APP"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
mkdir -p site/download
cp "$DMG" site/download/Bjarbys-skarminspelare.dmg
echo "$VERSION" > site/download/VERSION
echo "→ klart: $DMG ($(du -h "$DMG" | cut -f1)), kopia i site/download/"
