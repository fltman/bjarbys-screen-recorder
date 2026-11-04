# Bjarbys skärminspelare

Nativ skärminspelare för macOS 26+ (Swift, SwiftUI/AppKit, ScreenCaptureKit, AVFoundation,
Core Image på Metal). Inspelningen sparas som **data** — skärmen utan markör, egna ljudspår,
kamera och markör-/klickhändelser — och all polish (zoom, markör, bakgrund) läggs på i
efterhand och går att ändra. Underlaget finns i `docs/utredningar/`.

## Bygga och prova

```bash
./scripts/build.sh          # signerad app → dist/Bjarbys skärminspelare.app
./scripts/test.sh           # enhetsprov i RecorderKit (swift test via Xcodes verktygskedja)
open Skarminspelare.xcodeproj
```

- `xcode-select` pekar på Command Line Tools på den här datorn. Skripten sätter
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` per anrop — ändra inte systemet.
- Projektfilen är **handskriven** (XcodeGen gick inte att installera). Mapparna `App/` och
  `Config/` är mappsynkroniserade grupper: nya filer i `App/` kommer med automatiskt, ingen
  omgenerering. All logik ligger i det lokala Swift-paketet `RecorderKit/`.
- Signeras med *Developer ID Application: Brattoo AB (V783A2L763)*. Stabil signatur = TCC-
  behörigheterna (skärminspelning, mik, kamera) överlever ombyggen.
- Provlägen i appbinären: se `docs/VERIFIERAD-STACK.md`.

## Struktur

- `App/` — gränssnittet (menyrad, HUD, områdesväljare, bibliotek, redigerare). Svenska i
  `Localizable.xcstrings`, engelska som översättning.
- `RecorderKit/Sources/RecorderKit/` — `Capture/` `Writing/` `Telemetry/` `Project/`
  `Motion/` `Render/` `Export/`. Identifierare på engelska, kommentarer på svenska.
- `docs/FORMAT.md` — projektpaketet `.bsrec`. `docs/VERIFIERAD-STACK.md` — uppmätta fakta.
  `docs/FÄRDPLAN.md` — faserna.
- `vault/` — Obsidian-valv för arbetsanteckningar, gitignorerat, kommer aldrig in i repot.

## Fällor (läs innan du ändrar inspelningen)

- ⚠️ **Varje typ som skrivs till disk har handskriven `init(from:)` med `decodeIfPresent` +
  standardvärde.** Swift använder inte standardvärden när en nyckel saknas; ett nytt fält
  gör annars gamla projekt tyst oläsbara. Provet `MinimalJSONTests` håller efter det.
- Använd **inte** `SCRecordingOutput` med mikrofon — ospelbara filer (Apple Developer Forums
  805892). Vi skriver själva med en AVAssetWriter per spår.
- `NSAudioCaptureUsageDescription` m.fl. ligger i den **fysiska** `Config/Info.plist`.
  Som `INFOPLIST_KEY_*` tappar Xcode nyckeln och Core Audio-tappar ger bara nollor.
  `build.sh` kontrollerar med `plutil -p`.
- `NSWindow.sharingType = .none` ignoreras av ScreenCaptureKit sedan 15.4. Appens egna fönster
  (HUD, nedräkning, kameraförhandsvisning) hålls ute genom att appen utesluts ur `SCContentFilter`.
- HDR (senare fas): sätt ingen explicit färgrymd, då tonmappas allt tyst till SDR.
- VideoToolbox-avkodning var 3–4,5× långsammare än mjukvara på M5 i Kairos när rutorna drogs
  till CPU. Här ska rutorna stanna i IOSurface/Metal. Mät, anta inte.
- Döda aldrig en process utifrån en sökträff — bara en pid vi själva startat, eller
  `osascript -e 'tell application id "com.brattoo.skarminspelare" to quit'`.
- ⚠️ Disken är nästan full (≈12 GB ledigt nov 2026). Provinspelningar hålls korta och raderas.
