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

## Redigeraren och exporten (fas 2)

Uppmätt 2026-11-04 på en 21 s områdesinspelning (1874×1434) med `--prov-rendera`,
`--prov-exportera` och `--prov-redigerare`.

- **Samma kompositör i förhandsvisning och export** (`PolishCompositor`, `AVVideoCompositing` +
  Core Image på Metal). `AVMutableVideoComposition` är föråldrad i macOS 26 — vi använder
  `AVVideoComposition(configuration:)`.
- **Export, alla förval:** MP4 H.264 1080p60 (1263 rutor, 21,05 s = redigerad längd + 1 ruta,
  AAC), MP4 HEVC 3840×2160, ProRes 422 1080p med 24-bitars PCM (597 MB för 21 s — väntat),
  GIF 800×450. Klipp + 2× hastighet + stående 9:16: 15,05 s mot väntade 15,04.
- **Exportfart 1080p60:** 19,8 s → 17,3 s med parallell kompositörkö → **10,4 s** när de
  förrenderade bilderna (bakgrund, skugga, ring, markörer) lades i IOSurface-backade
  pixelbuffertar i stället för `CGImage`. En sampling visade `AGX…processCompressedRegion2D`:
  varje `CGImage` laddades upp till GPU:n på nytt för varje ruta. CPU-tiden halverades.
  Vid senare körningar 5–6 s (≈ 3,5× realtid). Det som återstår är CIContext-lås och AAC.
- **GIF-fördröjning** anges i hundradelar: 1/15 s avrundades till 0,07 och filmen blev 5 %
  för lång (22,12 s mot 21,05). Fördröjning per ruta följer nu den exakta klockan: 21,07 s.
- **Markören vid klick:** utjämnad markör släpar ~0,1 s och stod 2–3 % från klickpunkten när
  klicket skedde. Löst genom att tona över till den råa banan 0,25 s före klicket.
- **Glapp i musdata = stillastående.** En rörlig mus skickar 60–240 händelser/s. Linjär
  interpolation över ett 1,5 s-glapp (musen stod still, nästa händelse kom först vid nästa
  rörelse) flyttade markören 40 punkter från klickpunkten. Glapp > 0,1 s hålls nu.
- **Zoom i annat format än källan:** mittpunkten begränsas efter vad som täcker *bildytan*
  axel för axel, inte bara innehållet; annars förskjuts liggande innehåll i 9:16 och lämnar
  tom bakgrund på ena sidan.
- **Kompositionsspår med senare start** (mikrofonen ~0,5 s in) läggs in där de finns via
  `insertTimeRange` på skärningen med spårets `timeRange`.
- `NSHostingView.cacheDisplay` ritar layouten utanför skärmen men inte `AVPlayerView`s
  videolager — spelarytan blir svart i `--prov-redigerare`; rutorna granskas med
  `--prov-rendera`.

## Fas 3: tal (2026-11-05)

Uppmätt på syntetiskt svenskt tal (`say -v Alva`, två meningar med 4 s tystnad emellan, lagt
som mikrofonspår som börjar 1,0 s in), whisper.cpp i `~/Projekt/whisper.cpp`, Apple M5.

- ⚠️ **whisper-cli `--vad` ger ordtider på en hoptryckt tidslinje.** Tystnaden tas bort före
  avkodningen och tokentiderna räknas inte tillbaka: «Först», som sägs vid ~8,6 s i filen,
  fick 4,75 s. Därför gör appen uppdelningen själv: `vad-speech-segments` (samma Silero-modell)
  → taldelarna läggs efter varandra med 0,4 s tystnad → en körning av whisper-cli →
  `SpeechChunks` räknar tillbaka. `vad-speech-segments` skriver tider i **hundradelar**.
- ⚠️ **Utan DTW driver ordtiderna över tystnader** även utan VAD: samma ord fick 4,49 s på
  hela filen. Med `-dtw small` (KB-Whispers modeller är finjusterade ur OpenAI:s och har samma
  uppmärksamhetshuvuden) fick det 8,74 s. `t_dtw` i `-ojf` är i hundradelar.
- whisper sätter gärna början på ett ord i pausen före det; en tid i tystnaden mellan två
  taldelar räknas därför till delen efter, och ett ord räknas alltid inom en och samma del.
- Resultat med DTW + egen uppdelning: «Hej» 0,97 s (sägs ~1,04), «Först» 9,74 s (~9,64).
  Ordtiderna är alltså ±0,1 s; ett klipp i texten går därför till mitten av pausen mot
  grannorden, inte till ordets kant.
- Hastighet på 14 s tal: KB small 0,9 s, KB medium 2,3 s (hela kedjan, inklusive VAD och
  modellladdning). Båda transkriberade texten ordagrant rätt; medium satte punkt där small satte
  komma.
- Inbrända undertexter kostar inget märkbart i exporten: 8,2 s 1080p60 på 2,33 s (3,5× realtid).
- **Ljudstyrka (EBU R128 / BS.1770-4)** i `Loudness.swift`, kalibrerad mot ffmpeg `ebur128`:
  syntetiskt tal −18,36 (ffmpeg −18,3), JFK-provet −15,47 (−15,5), 1 kHz-sinus −41,07 (−41,1).
- **AVAudioMix förstärker över 1,0**: mikrofonvolym 0,5 / 1 / 2 gav medelnivå −26,2 / −20,2 /
  −14,3 dB, men topparna klipps vid 0 dBFS (ingen limiter). Utjämningen begränsar därför
  förstärkningen så att topparna stannar under −1 dBFS.
- Exporten lägger monomikrofonen i båda kanalerna: filmen blir 3 dB starkare än spåret ensamt.
  Prov: spår −32,37 LUFS → +13,36 dB → exporten mätte −16,0 LUFS, topp −3,5 dBFS.

## Fas 4: dölja känsligt (2026-11-05)

Provpaket: 1920×1080, vit bakgrund, en e-postadress, en `sk-proj-…`-nyckel, ett telefonnummer
som scrollar 300 px under 3–4 s, och en rad vanlig text (ffmpeg `drawtext`, Arial 34 px).

- Vision (`.accurate`, sv+en, utan språkkorrigering) hittade alla tre; den vanliga raden
  lämnades orörd. Sökning på 6 s: 0,8 s med fyra rutor åt gången.
- ⚠️ **En ruta i sekunden räcker inte när text rör sig**: masken stod kvar där numret senast
  lästes, och numret syntes mitt i scrollen (ruta 3,5 s). Rättat: där bilden ändrats mellan
  två läsningar (64×40-gråskala, någon pixel > 3 nivåer) läses fem rutor i sekunden, masken
  täcker både förra och nästa läge mellan nyckelrutorna, och den sträcker sig till läsningen
  före första och efter sista träffen. Därefter täckt hela scrollen.
- Att hoppa över rutor som "ser likadana ut" användes inte: en ny textrad på en stor skärm
  ändrar för lite i en liten jämförelsebild.
- Känd gräns: text som glider in över annan text (två rader ovanpå varandra) läses inte av OCR,
  och kan då synas i kanten under en kort stund. Därför: kontrollera filmen innan den delas.
- En nyckel lästes olika i olika rutor (med och utan prefix) och blev två masker som tillsammans
  täckte hela tiden — rätt resultat, men listan kan visa samma sak två gånger.

## Brusreducering (2026-11-05)

`AUSoundIsolation` (Apples röstisolering, `HighQualityVoice` från macOS 15) körd offline med
`AVAudioEngine` i manuellt renderingsläge. Prov: syntetiskt tal + rosa brus (amplitud 0,05),
mikrofonen förskjuten 1,0 s.

- 10,5 s ljud tog 0,29 s. Enheten rapporterar 92,5 ms fördröjning; den dras bort.
- Bruset i pausen: −42,3 → −95,4 dBFS i den isolerade filen, −42,5 → −114 dBFS i exporten.
  Talet −17,5 → −17,3 dBFS (orört).
- Synk mot det rena talet (hölje i 1 ms-steg, korskorrelation): 0 ms, både i filen och i
  exporten. Den inledande sekunden (mikrofonens senare start) är tyst i filen.

## Styrning utifrån (2026-11-05)

- MCP-servern (`--mcp`) provad med en riktig JSON-RPC-klient över stdin/stdout: initialize
  (protokoll 2025-06-18), tools/list (8 verktyg), ping, okänd metod → −32601, och alla verktyg.
  `record_screen` 3 s → 3,0 s, 3024×1964 (Terminals behörighet). Transkribering 1,0 s,
  redigering (Reel, undertexter, röstisolering, −16 LUFS, dödtid) direkt, två rutor 0,2 s,
  export 11,5 s → 8,5 s 1080p på 1,9 s med `.srt`. Processen avslutas rent när stdin stängs.
- Transkriberingen läser den röstisolerade mikrofonen om den finns: på brusprovet blev
  "längst och upp till höger" (rått) rätt "längst upp till höger" (isolerat), både small och medium.
- ⚠️ Sökvägar med å/ä/ö kan ligga i en annan Unicode-form på disken än i en sträng i skalet;
  jämför normaliserat (NFC) innan något raderas.

## Steg-för-steg-guide (2026-11-05)

Provad genom MCP (`make_guide`) på brusprovet med två klick, ett elementnamn och ⌘E.
- whisper lade båda meningarna i ett segment; stegen fick då all text i steg 1. Meningar delas
  nu också vid .!? och pauser > 1 s, och hamnar på rätt steg.
- Instruktionerna kom ut på engelska mitt i svenskt tal: processen följer systemspråket, och
  den här Macen har `AppleLanguages = (en-US, sv-SE)` — appens gränssnitt visas alltså på
  engelska här. Guiden skrivs nu på transkriptets språk (annars förstaspråket).
- Guidens bilder ärvde Reel-läge och undertext från filmen; nu görs de i inspelningens format,
  utan undertext (texten står i guiden), med zoom, markör och bakgrund kvar.

## Flashback-buffert (2026-11-05)

Byggd av vanliga sessioner som avlöser varandra (SDK 26.1 saknar `SCClipBufferingOutput`).
Prov `--prov-flashback 4 10 13 10`: delar à 4 s, buffert 10 s, 13 s drift, spara 10 s,
huvudskärmen + datorljud.
- ⚠️ **Utan omkodning börjar bilden vid en nyckelruta**: den första sparade versionen hade
  ingen bild de första 1,41 s (biten började mitt mellan nyckelrutor, varannan sekund).
  Rättat: starten flyttas bakåt till närmaste nyckelruta — sparat blev 11,75 s i stället för 10.
- Därefter: första rutan vid 0, största avstånd mellan rutor i hela biten 75 ms (två skarvar
  ingår), ljudet utan glapp (14 buffertar, sammanhängande), sparandet tog 0,32 s (rakt över,
  ingen omkodning). Arbetsmappen borta efter stopp; tre delar kvar i bufferten vid sparandet.
- En ny del måste ha fått sin första ruta innan den gamla stoppas; annars blir skarven ett hål.
  `FlashbackPlan` lämnar ett verkligt hål (misslyckad rotation) som hål i stället för att flytta tid.
- Språklåset: `AppleLanguages = (sv)` i appens domän före första lokaliserade text ger svenskt
  gränssnitt redan vid första starten (redigerarens ögonblicksbild), trots en-US först i systemet.
