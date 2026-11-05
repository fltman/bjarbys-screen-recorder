#!/bin/bash
# Bygger whisper.cpp:s verktyg statiskt (bara systemets ramverk, Metal-shadern inbäddad) till
# build/whisper-static/bin, för att följa med appen: den som laddar ned appen behöver då varken
# whisper.cpp, Xcode eller Homebrew. Användning: scripts/build-whisper.sh [whisper.cpp-mapp]
set -euo pipefail
cd "$(dirname "$0")/.."
KALLA="${1:-${WHISPER_CPP:-$HOME/Projekt/whisper.cpp}}"
[ -f "$KALLA/CMakeLists.txt" ] || { echo "✗ hittar inte whisper.cpp i $KALLA (ange mappen)"; exit 1; }
command -v cmake >/dev/null || { echo "✗ cmake saknas"; exit 1; }
UT=build/whisper-static
echo "→ whisper.cpp $(git -C "$KALLA" rev-parse --short HEAD 2>/dev/null || echo '?') → $UT"
cmake -S "$KALLA" -B "$UT" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF > "$UT.log" 2>&1
cmake --build "$UT" --config Release -j 8 --target whisper-cli vad-speech-segments >> "$UT.log" 2>&1
cp "$KALLA/LICENSE" "$UT/LICENSE"
git -C "$KALLA" rev-parse HEAD > "$UT/VERSION" 2>/dev/null || true
# Bara systemets bibliotek får länkas.
if otool -L "$UT/bin/whisper-cli" "$UT/bin/vad-speech-segments" | grep -E '@rpath|/opt/|/usr/local/'; then
    echo "✗ verktygen länkar mot bibliotek utanför systemet"; exit 1
fi
echo "→ klart: $UT/bin/whisper-cli, vad-speech-segments"
