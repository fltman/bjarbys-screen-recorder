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
- Provlägen i appbinären (`dist/Bjarbys skärminspelare.app/Contents/MacOS/Skarminspelare …`):
  - `--prov-inspelning <s> [--mik] [--kamera] [--katalog <mapp>]` — spelar in huvudskärmen
  - `--prov-aterstall <mapp>` — räddar avbrutna paket
  - `--prov-rendera <paket> <t1,t2,…> <mapp>` — färdiga rutor som PNG (läs dem som bild!)
  - `--prov-exportera <paket> mp4-1080|mp4-4k|prores|gif|ljud-m4a|ljud-wav|ljud-spar <fil> [--utsnitt a,b] [--fps n] [--ljudniva -14] [--kvalitet small|normal|high]`
  - `--prov-redigerare <paket> <png> [--markera-zoom]` — redigerarens layout utanför skärmen
  - `--prov-transkribera <paket> [--modell <fil>] [--sprak sv]` — whisper.cpp, skriver orden
  - `--prov-maskera <paket> <t1,…> <mapp>` — söker känslig text och renderar rutor (sparar inte)
  - `--prov-ljudstyrka <ljudfil>` — LUFS enligt BS.1770 och förstärkningen till −16
  - `--prov-rostisolering <ljudfil> <ut.caf>` — Apples röstisolering offline
  - `--prov-flashback <del-s> <buffert-s> <kör-s> <spara-s> <mapp>` — bufferten i drift, mäter skarvarna
  - `--prov-teleprompter <png>` — teleprompterrutan efter 6 s rullning, utanför skärmen
  - `--prov-vyer <mapp> <paket>` — alla fönster och paneler (ljust och mörkt, inspektörens flikar)
    som PNG; material och videolager ritas inte utanför skärmen
  - `--prov-bildfrekvens <mapp> [bilder/s]` — verklig bildtakt: eget fönster rör sig varje bildruta
  - `--prov-trim <paket>` — trimningens gränser (grannar, inspelningens ändar, minsta längd)
  - `--prov-fonsterflytt <mapp>` — fönsterinspelning där fönstret flyttas mitt i
  - `--prov-hdr <mapp>` — ett eget EDR-fönster spelas in i HDR; fälten mäts i inspelning och export
  - `--prov-hdr-syntetisk <mapp>` — samma mätning på ett påhittat HDR-paket, utan skärm
  - `--prov-appljud <mapp> [--behall]` — ljud per app med egna toner: separation och synk mot SCK
  - `--prov-tappglapp <mapp> tappar|sck|bada[+ny]` — var tonen saknas, med/utan tappar och SCK,
    `+ny` = en ny ljudprocess ansluter mitt i
  - `--prov-ansikten <paket>` — ansiktena i kameraspåret (Vision), skrivs ut men sparas inte
  - `--prov-penna <png>` — pennans fönster med syntetiska mushändelser (visas inte): strecken,
    punkterna i globala koordinater, livebilden som PNG och att strecken tonas bort
  - `--prov-slaihop <mapp> <paket> <paket> …` — slår ihop tagningar till ett nytt paket och mäter
    spåren, händelserna och orden
  - `--prov-uppladdning <fil> <http://127.0.0.1:port>` — uppladdningen mot en lokal provserver
    med påhittade provnycklar (aldrig riktiga)
  Startad från terminalen lånar binären terminalens skärminspelningsbehörighet.
- `./scripts/sync-check.sh` mäter A/V-synk mot en blixt+pip-referens i QuickTime.
- `swift scripts/make-icon.swift <png>` ritar appikonen (skalas in i `App/Assets.xcassets`).
- `python3 scripts/strings.py check` efter ett bygge: hittar gränssnittstexter som saknas i
  `Localizable.xcstrings` eller saknar engelska. xcodebuild extraherar dem men skriver inte in
  dem i katalogen (bara Xcode-fönstret gör det). `… add fil.json` lägger in `{"sv": "en"}`.

## Struktur

- `App/` — gränssnittet (menyrad, HUD, områdesväljare, bibliotek, redigerare). Svenska i
  `App/Localizable.xcstrings` (källspråk sv), engelska som översättning. Användarsynlig text
  ska vara `LocalizedStringKey`/`String(localized:)`, annars hamnar den inte i katalogen.
- `RecorderKit/Sources/RecorderKit/` — `Capture/` `Writing/` `Telemetry/` `Project/`
  `Motion/` `Render/` `Export/`. Identifierare på engelska, kommentarer på svenska.
- `docs/FORMAT.md` — projektpaketet `.bsrec`. `docs/VERIFIERAD-STACK.md` — uppmätta fakta.
  `docs/FÄRDPLAN.md` — faserna.
- `vault/` — Obsidian-valv för arbetsanteckningar, gitignorerat, kommer aldrig in i repot.

## Utseende

- Datum och decimaltal formateras med `AppLocale` (gränssnittets språk), inte `Locale.current`
  (systemets region) — annars "Nov 4" och "2.0" mitt i svensk text.
- Inspektören har flikar (Stil, Rörelse, Tal, Dölj) så att varje flik ryms utan att rulla;
  det markerade (zoom, del) visas överst oavsett flik.

## Språk

Gränssnittet är låst till svenska: `SkarminspelareApp.lockLanguage()` sätter `AppleLanguages`
i appens egen domän före första lokaliserade text (den här Macen har en-US först). Engelska
finns kvar i katalogen; `defaults write com.brattoo.skarminspelare followSystemLanguage -bool true`
låter appen följa systemspråket.

## Producenten (AI-redigering)

Som i Generativet-studion: AI:n (Claude Code via MCP, prompten `producera`) fattar besluten,
verktygen renderar dem. `RecorderKit/Guide/Producer.swift`: `overview` (underlaget i källtid:
tal, klick med elementnamn och ram, dödtid), `preflight` (regler) och `coverage` (täcker en ruta
det som klickas — räknat i färdig bild med zoom). Bildlagret: `Project/Overlays.swift`,
ritas i `Render/OverlayRenderer.swift`. Regeln från demo-creator: det som sägs ska synas —
producenten renderar och läser varje ruta med lager/berättarröst innan leverans. Berättarröst
görs med elevenlabs-dialogue-skillen (kostar pengar, fråga om röst och språk först).

## Styrning utifrån

- `Skarminspelare --mcp` — MCP-server över stdio (`App/Automation/MCPServer.swift`). stdout är
  protokollet: skriv aldrig `print()` i kod som kan köras där; logga till stderr.
- `skarminspelare://spela-in|stoppa|vaxla|paus|omrade|fonster|bibliotek|oppna?sokvag=…`
  (`URLCommands.swift`), och App Intents för Genvägar i samma fil.

## Tal (whisper.cpp)

Transkriberingen kör whisper.cpp som extern process: `whisper-cli` och `vad-speech-segments`
i `<rot>/build/bin`, modeller i `<rot>/models` (KB-Whisper för svenska, `ggml-silero-v5.1.2.bin`
för taldetektering). Roten letas upp i `~/Projekt/whisper.cpp` m.fl., eller väljs i appen.
⚠️ Använd inte `whisper-cli --vad` — ordtiderna hamnar på en hoptryckt tidslinje. Se
`RecorderKit/Speech/Whisper.swift` och `docs/VERIFIERAD-STACK.md`.

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
- HDR: sätt ingen egen färgrymd ovanpå SCK-förvalet (då tonmappas allt tyst till SDR). SDR-vitt
  ligger på 100 nits i inspelningen men 203 i Core Image — renderaren lyfter ×2,03. En komposition
  med HDR-källa får **inga färgegenskaper** (annars gör AVFoundation om rutorna själv, till grått),
  och SDR-utritningen går via en linjär mellanbild (annars knä-kurva: vitt 229). Se
  `docs/VERIFIERAD-STACK.md` och mät med `--prov-hdr-syntetisk` (behöver ingen skärm).
- VideoToolbox-avkodning var 3–4,5× långsammare än mjukvara på M5 i Kairos när rutorna drogs
  till CPU. Här ska rutorna stanna i IOSurface/Metal. Mät, anta inte.
- Döda aldrig en process utifrån en sökträff — bara en pid vi själva startat, eller
  `osascript -e 'tell application id "com.brattoo.skarminspelare" to quit'`.
- Förrenderade bilder i renderingen ska ligga i IOSurface-backade pixelbuffertar
  (`RenderPlan.prerender`), aldrig som `CGImage` — de laddas annars upp till GPU:n varje ruta.
- Efter en krasch visar AppKit en modal "Öppna fönstren igen?" vid nästa start; provlägen och
  `--mcp` slår av det med `ApplePersistenceIgnoreState` (annars hänger de, osynligt).
- ProRes får bara skrivas i .mov (i .mp4 kastar AVAssetWriter ett undantag).
- `./scripts/test.sh` bygger bara RecorderKit-paketet, inte appen. Provlägen kör appbinären i
  `build/` — bygg den med xcodebuild (eller `build.sh`) efter en ändring, annars mäter du den
  gamla koden (hände: en övertoning "fungerade inte" i en mätning mot en gammal binär).
- Ljudvolymer byggs som `GainEnvelope` (kurvor som multipliceras och blir rampar kant i kant);
  lägg aldrig `setVolumeRamp` som kan överlappa.
- Ljud per app (`Capture/AppAudio.swift`): **inget annat än IOProc på tappens ljudkö** — att
  räkna om processlistan där gav 0,2 s glapp varje gång en app började spela. Aggregatenheten
  har bara tappen (inga högtalare). Utan appar tas datorljudet som förr från ScreenCaptureKit.
- Musdata: ett glapp > 0,1 s mellan händelser betyder att musen stod still. Interpolera aldrig
  över det (`CursorPath.stillGap`).
- Prov som spelar in skärmens innehåll (HDR-fältet, bildtakten) måste köras med **upplåst**
  skärm: med låsskärmen ritas inga fönster och strömmen ger långa svep av `idle`-rutor som ser ut
  som tappade bilder. Provlägena vägrar då (`ScreenLock.isLocked`).
- ⚠️ Provinspelningar fångar det som är på skärmen just då (en gång ett pågående Teams-möte med
  andra i bild): radera direkt, och prova renderingen med syntetiska paket när det går.
- ⚠️ Disken är nästan full (≈12 GB ledigt nov 2026). Provinspelningar hålls korta och raderas.
