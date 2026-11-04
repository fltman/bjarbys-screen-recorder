# Verifierad stack

Bara uppmätta eller provade fakta hör hemma här, med datum och hur det mättes.
Maskin: Apple M5, macOS 26.1 (25B78), Xcode 26.1.1, SDK MacOSX26.1.

## Bygget

- 2026-11-04: Handskriven `project.pbxproj` (objectVersion 77, mappsynkroniserade grupper +
  lokalt Swift-paket) bygger med `xcodebuild` och signeras med Developer ID. `codesign
  --verify --strict` godkänner. Hardened runtime på (flags=0x10000).
- Release injicerade `com.apple.security.get-task-allow` tills
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` sattes — skulle ha fällt en notarisering.
- SDK 26.1 saknar `SCClipBufferingOutput` och `SCRecordingEditor` (macOS 27). `CATapDescription`
  finns. `NSCursor.currentSystemCursor` är `API_TO_BE_DEPRECATED` men finns.

## Inspelningsmotorn (fas 1)

Uppmätt 2026-11-04 med `--prov-inspelning`, `scripts/sync-check.sh` och kraschprov.

- **Spåren delar tidslinje.** Skärm: HEVC 3024×1964 (inbyggd Retina, skala 2), tidsbas 1/600,
  presentationstider strikt ökande. Datorljud: `pcm_s24le` 48 kHz stereo med `start_time`
  0,0485 s — AVAssetWriter lägger en tom redigering före första bufferten i stället för att
  flytta ljudet till noll, så synken mot bilden bevaras.
- **A/V-synk mot riktig referens:** blixt + 1 kHz-pip varje sekund, spelat i QuickTime Player
  på AirPods. Uppmätt bild minus ljud: medel +175,9 ms, median +175,4 ms, spridning 13,3 ms
  (7 par). Core Audio anger AirPods-latensen till **170,7 ms** (7680 + 512 ramar @ 48 kHz) och
  QuickTime fördröjer bilden med den för att hålla synk i örat, medan ScreenCaptureKit tar
  ljudet före hårdvaran. **Kvar för vår pipeline: ≈ +5 ms** — under en ruta vid 60 fps.
  ⚠️ Kör synkprovet med vetskap om utgångsenheten; med Bluetooth dominerar dess latens.
- **Kraschprov:** `kill -9` på provprocessen efter ~10,5 s inspelad tid. Skärmspåret går att
  spela till 10,08 s, datorljudet till 10,00 s (fragmentgränsen på 2 s). `--prov-aterstall`
  hittar paketet, märker det `recovered` och räknar ut längden. Hela filen avkodas utan fel.
- SCK levererar rutor bara när skärmen ändras (138 rutor på 5 s vid stillastående skärm) och
  ibland tätare än `minimumFrameInterval` = 1/60 (minsta steg 8,3 ms på ProMotion-skärmen).
- **Behörighet:** körs binären direkt från en terminal tillskriver TCC inspelningen
  terminalen ("Terminal has accessed your screen…"), inte appen. Appen startad med `open`
  ber om sin egen behörighet.
- `ffmpeg -f null` klagar på "non monotonically increasing dts" för VFR-filen — det är
  null-muxerns avrundning; paketens egna tider ökar strikt (kontrollerat med ffprobe).
