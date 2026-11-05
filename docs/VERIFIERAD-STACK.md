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

## Teleprompter (2026-11-05)

- SwiftUI kapar en `Text` med "…" till förälderns höjd; för en rullande text krävs
  `.fixedSize(horizontal: false, vertical: true)` (syntes i första ögonblicksbilden).
- Appen har en egen `TimelineView` (tidslinjen) som skuggar SwiftUI:s — skriv `SwiftUI.TimelineView`.
- Ögonblicksbild efter 4 s rullning i 150 ord/min: ~10 ord lästa, raden med dem precis ovanför
  läslinjen; nederkanten tonar ut.

## ProRes 4444 med alfa (2026-11-05)

- Exporten: `prores, 4444, yuva444p12le`. Bildpunkter (RGBA, ffmpeg): hörnet 0,0,0,0; skärmen
  50,114,213,255; skuggan under 0,0,0,62; utanför det rundade hörnet alfa 2. Ovanpå magenta: mjuk
  skugga, rena hörn. Kräver en helt klar bas över hela bildytan (återanvända buffertar) och
  `kCVImageBufferAlphaChannelMode_PremultipliedAlpha` på rutorna.
- ⚠️ **ProRes i .mp4 kastar ett NSException** i `AVAssetWriter` — behållaren väljs nu efter
  filändelsen, inte efter `codec == .prores`.
- ⚠️ **Efter en krasch hänger varje följande start** på AppKits modala "Öppna fönstren igen?"
  (`NSPersistentUIRestorer`, syns i `sample`). Provlägen och `--mcp` registrerar
  `ApplePersistenceIgnoreState` för sin egen process.
- Färgskillnaden mot källan (51,102,204 → 50,114,213) finns likadant i MP4-exporten: provfilen
  från ffmpeg saknar färgmärkning och tolkas som BT.601 respektive BT.709. Riktiga inspelningar
  är märkta BT.709.

## Polerade skärmdumpar (2026-11-05)

- `SCContentFilter(desktopIndependentWindow:)` + `ignoreShadowsSingleWindow` ger fönstret i full
  upplösning med genomskinliga, egna rundade hörn; skuggan görs ur bildens alfa och följer
  formen. Finder-fönster: 1988×1076 med marginal. Område 600×400 pt → 1328×928.
- Okänd app i MCP-verktyget svarar med listan över appar som har fönster på skärmen.

## Felrapport (2026-11-05)

Via MCP på ett provpaket (källa: fönster «Finder», ett klick med elementnamn, ⌘⇧N, transkript):
rapport med "Program: Finder 26.1 (1828.1.8)", "macOS 26.1.0, Mac17,2", två steg med tid och
tal, film 0,57 MB, guide, 42 rader `log show` för Finder, zip 1,1 MB (`ditto -c -k --keepParent`).
`log show` utan admin fungerar; privata fält är redigerade av macOS.

## Delning till S3/R2 (2026-11-05)

- SigV4 kontrollerad mot AWS publicerade exempel: IAM ListUsers (signeringsnyckel
  c4afb1cc…, kanonisk begäran f536975d…, signatur 5d672d79…) och S3 GET Object (signatur
  f0e8bdb8…). ⚠️ S3-dokumentationens exempelnyckel är `…MDENG/bPxR…`, IAM-exemplets `…MDENG+bPxR…`;
  med fel nyckel blir signaturen fel fast koden är rätt.
- Uppladdning mot en lokal PUT-server med påhittade provnycklar: sökvägsstil
  `/hink/prefix/ÅÅÅÅ-MM-DD-namn-slump.mp4` (å→a), hela kroppen (300 000 byte), `UNSIGNED-PAYLOAD`,
  publik länk tillbaka. Inte provat mot riktig R2/S3 (kräver användarens nycklar).

## 120 bilder/s (2026-11-05)

- Export: syntetisk 120-fps-källa (ffmpeg `testsrc2`, 3 s) → MP4 1080p med `--fps 120`:
  `120/1`, 360 rutor, 360 unika (framemd5); med 60: 180 rutor, 180 unika. Fjädrarna är
  analytiska, så rörelsen är lika jämn i 120 som i 60.
- Inspelning i 120: valet finns bara om en skärm har `maximumFramesPerSecond ≥ 120`. Uppmätt
  med `--prov-bildfrekvens` (eget fönster där en ruta flyttas i varje bildruta, displaylänken 120
  gånger/s), hela Retina-skärmen 3024×1964: **108 rutor/s** (90 %), median 8,33 ms, 95:e
  percentilen 16,67 ms, längsta lucka 42 ms, inga tappade i skrivaren. I 60: 55 rutor/s, median
  16,67 ms.
- ⚠️ Första mätningarna gav långa svep av `idle`-rutor (1,0–2,5 s utan bilder), även i en
  fristående SCK-ström med standardinställningar — skärmen var låst. Med låsskärmen ritas inga
  fönster. Provlägena som mäter skärmens innehåll vägrar nu med låst skärm.

## Kameran (2026-11-05)

MacBook Pro-kameran, `--prov-inspelning 3 --kamera`:
- Spåret: HEVC 1920×1080, ~27 rutor/s, börjar 0,5–0,75 s efter skärmen.
- De första rutorna är nästan svarta (exponeringen ställer in sig, ~0,25–0,4 s): bubblan tonade
  in en mörk cirkel. Nu hoppas rutor med medelluma under 24 över (högst 1,5 s); första sparade
  rutan hade medelluma 157. Spårets start sparas i `meta.json` (`tracks[].start`) och bubblan
  tonas in och växer från 90 % på 0,3 s därifrån, i stället för att poppa fram.

## Producenten via MCP (2026-11-05)

Ett helt varv på ett demopaket (syntetisk skärm, tal med `say`, klick på «Exportera» med
elementram): prompts/list → `producera`; `get_overview` gav tal med tider, klicket med namn och
ram [0.781,0.013,0.083,0.039] och ⌘S; `set_segments`, `set_chapters` (YouTube 0:00/0:04),
`set_overlays` där markeringen fick ram och etikett ur klicket, `add_audio` (musik), preflight.
Renderade rutor: rubrikkort med dämpad bakgrund, kapitelrad, QR-kort ovanför undertexterna,
markering runt knappen. ⚠️ Faktarutan uppe till höger täckte knappen som just klickats — syntes
bara i bilden. Preflight har nu `coverage` (rutans ram mot klickade elements ram i färdig bild,
med zoom, ±2,5 s) och fångar det som fel.

## Textlager, bildlager och övergångar (2026-11-05)

Renderade rutor via MCP: textlager med platta (följer nu texten — först fick centrerad text hela
största bredden), utan platta (skuggad), bildlager med appikonen (⚠️ skuggan gjordes först som en
rektangel av hela bildytan och syntes som en grå fyrkant runt en PNG med genomskinlig marginal;
nu efter bildens alfa), oskärpeövergång 0,1 s från snittet (kortkommandot läsbart ovanpå —
lagren ritas efter övergången), intoning från svart vid 0,15 s.

## Videoinslag (2026-11-05)

Testklipp (ffmpeg `testsrc2` med tidskod + 880 Hz) via MCP: bild-i-bild vid källtid 2,0 och helbild
med `offset` 2 s vid 7,0. Rutorna visar klippets tidskod 00:00:01.100 vid utdatatid 2,5 (inslaget
börjar 1,4) och 00:00:02.600 vid 7,0 (2 + 0,6) — exakt. Inslagets ljud i exporten: −22,9 dB i
880 Hz-bandet under inslaget mot −40,6 dB utanför. Spår-id: bild 200+, ljud 300+ i videolagrens
ordning; kompositören skickar rutorna till renderaren via `PolishInstruction.mediaTrackIDs`.
Preflight räknar bild-i-bild-ramen i täckningskontrollen (fångade att inslaget låg över
exportknappen).

## Övertoning och övergång per snitt (2026-11-05)

Provpaket där skärmen visar sin egen tidskod; delar 0–4 och 7–12 s, övertoning 1 s in i del 2.
Rutor: vid 3,6 syns 6.6 svagt (B:s förrulle, 10 %), vid 4,0 blandas 04 och 07 till hälften, vid
4,4 finns 4.4 kvar svagt (A:s efterrulle). Exporten är 9,000 s — övertoningen tar materialet
utanför snitten ur skärmspår B (id 6) och ändrar inte filmens längd.
- ⚠️ **Ett tomt `AVMutableCompositionTrack` har ogiltig `timeRange` (NaN)**: jämförelser mot den
  blir falska och första versionen lade därför aldrig in något i spår B. Slutet hålls nu i en
  egen variabel.
- Maskerna läggs också på B-bilden, med dess egen källtid, så inget känsligt syns i övertoningen.

## Ljud i snitten (2026-11-05)

Mikrofon med 440 Hz 0–5 s och 660 Hz 5–12 s (källtid), delar 0–4 och 7–12 s, ProRes-export,
vänster kanal:
- Vanligt snitt, lagt utanför en nollgenomgång: största steget runt snittet 0,0432 = 660-tonens
  naturliga lutning — inget klick (20 ms toning ner och upp i varje snitt).
- Övertoning 1 s: 440 Hz 0,498 → 0,371 (3,75) → 0,194 (4,1) → 0,042 (4,4); 660 Hz spegelvänt —
  linjärt genom hela fönstret, huvudspår + B-spår summerar till 1. Mikrofonens och datorljudets
  B-spår (id 7, 8) har samma förrulle/efterrulle som skärmspår B.
- `AVAssetReaderAudioMixOutput` tillämpar volymrampar (fristående prov: 1 → 0,5 → 0).
- ⚠️ Första mätningen visade ingen övertoning: den kördes mot en appbinär byggd före ändringen
  (`test.sh` bygger bara paketet). Mät alltid efter xcodebuild.

## Ljudnivå vid export (2026-11-05)

En 440 Hz-ton (−32 dBFS) som ljudklipp, MP4-export, mätt med ffmpeg `ebur128`: utan utjämning
−32,7 LUFS (vår mätning −32,73); med mål −14 → −14,0 LUFS, med −16 → −16,0. Stereomätningen
summerar kanalernas effekt (BS.1770): samma signal i båda kanalerna är 3,01 dB över en kanal.

## Lupp (2026-11-05)

Provinspelning med en påhittad musrörelse och ett lupp-block (2,5×): luppen följer markören och
växer fram. ⚠️ Först förstorades den råa skärmbilden — en mask hade synts i luppen; nu förstoras
den maskade (provat med ifylld och pixlad mask: ingen läsbar text i luppen). ⚠️ En svart ruta
som bakgrund i `CIBlendWithMask` gav svarta hörn runt cirkeln; bakgrunden ska vara `.empty()`.

## Slå ihop inspelningar (2026-11-05)

- `AVMutableComposition` + `AVAssetExportPresetPassthrough` till .mov: tre syntetiska tagningar
  (2,5 + 1,5 + 3 s, testbild 30 bilder/s, toner 440/660/880 Hz) blev exakt 7,000 s och 210 rutor;
  tonerna låg där de skulle (438/658/878 Hz uppmätt vid 1,0/3,0/5,5 s). Ett appspår som bara fanns
  i mittentagningen fick `start_time` 2,5 i filen (tom redigering före), samma konvention som
  kamerans senare start — kompositionen läser det i inspelningens tid utan omräkning.
- Luckor läggs in uttryckligen (`insertEmptyTimeRange`), så att varje tagning hamnar på sin
  plats även när ett spår saknas i en tagning (oprövat utan: vi förlitar oss inte på hur
  `insertTimeRange` bortom spårets slut beter sig).

## Utsnitt (2026-11-05)

`--prov-exportera … --utsnitt 1.5,3.0` på en film på 5 s med en 440 Hz-ton: MP4 och ProRes 1,500 s
(bild och ljud), GIF 23 rutor. Ljudet tonas: topp 0,076 de första 2 ms mot 0,141 efter 30 ms,
0,012 de sista 2 ms — inget klick i kanterna.

## Klickljud (2026-11-05)

Provinspelning med tre påhittade klick (1,0, 2,5 och 3,2 s; delen 0–3 s behålls), ProRes-export:
klicken hörs vid 1,00–1,02 och 2,50–2,52 s (topp 0,47 vid volym 50 %), inte vid 3,2 (bortklippt).
- ⚠️ Insättningen misslyckades först med −11800/−12780: `AVURLAsset` skapades inne i uttrycket
  (`try await AVURLAsset(url:).loadTracks(…)`) och släpptes innan spåret lades in. Håll tillgången
  i en egen variabel så länge kompositionen byggs.

## Städad inspelning (2026-11-05)

- Fönsterlistan: skrivbordssymbolerna är ett helskärmsfönster från Finder på
  `kCGDesktopIconWindowLevel` (−2147483603); skrivbordsbilden ett fönster från Dock
  ("Wallpaper-", −2147483624); skrivbordswidgets och notiser fönster från
  `com.apple.notificationcenterui` (även Teams har en egen `…notificationcenter`).
- `--prov-inspelning 1 --stadad` mot en vanlig: en skrivbordssymbol nere till höger syns i den
  vanliga men inte i den städade (där syns skrivbordsbilden); Finders fönster och Docken finns i
  båda. En provnotis (osascript) syns i den vanliga men inte i den städade.

## Kamerabakgrund (2026-11-05)

Syntetiskt kameraspår (testbild 1280×720, ingen person), bubbla 40 %, export MP4 1080p av 4 s:
som den är 1,29 s (3,1× realtid), borttagen 1,94 s (2,1×) — segmenteringen per ruta kostar en
tredjedel. Utan person blir allt suddigt respektive utbytt (masken är tom), utan fel. Med en
riktig person: inte provat av mig (kräver kameran).

## Trimma delar (2026-11-05)

`--prov-trim` på delarna [0–1] och [2–3] i en inspelning på 4,18 s: slutet till 1,8 → 1,8; till
2,5 → 2,0 (nästa del börjar där); nästa dels början till 0,5 → 2,0 (förra slutar där); början
till −1 → 0; slutet till 99 → 4,18; början till 2,98 → 2,98 (minst 0,1 s kvar). Med musen: inte
provat av mig — dragningen räknar om med delens fart (källtid = förflyttning × fart).

## Videoinslag: hastighet, beskärning, mjuka kanter (2026-11-05)

- Hastighet: en provvideo med rutans nummer binärt i åtta fält (30 bilder/s), inlagd vid 0,5 s med
  `offset` 0,5 och `speed` 2. Renderat vid 0,75 / 1,0 / 1,5 s: källruta 30 / 45 / 75 — exakt det
  väntade (offset + förfluten tid × 2). Ljudet skalas lika (`scaleTimeRange`, spektral tonhöjd).
- Beskärning [0,25, 0, 0,5, 1] av en 16:9-video: mittersta hälften, 8:9, inpassad i ramen med
  rundade hörn och skugga; förhandsvisningens dragram följer det som syns (videons storlek läses
  en gång per fil). Mjuka kanter 1: masken krymps och suddas, skuggan tas bort.
- ⚠️ Att läsa rutnummer ur ljusstyrka gick inte: videonivåer, BT.709 och sRGB på vägen gör
  mappningen olinjär (±4 rutor). Binära fält är exakta.

## Fönster som flyttas (2026-11-05)

`--prov-fonsterflytt`: eget fönster (600×400 pt, röd ruta) inspelat som fönster i 3 s, flyttat
+300/+120 pt efter 1 s.
- `frame`-händelserna: (120, 128) vid 0,03 s och (420, 248) vid 1,14 s — 0,1 s efter flytten.
- Den röda rutan ligger kvar i skärmspåret: (0,233, 0,397) före och efter — inspelningen följer
  fönstret (`desktopIndependentWindow`).
- Rutans globala punkt före och efter, genom `ContentMapping`: (0,233, 0,398) båda gångerna —
  samma ställe som i spåret, så markören och zoomen hamnar rätt efter en flytt.

## GIF (2026-11-05)

Provinspelning med bakgrundsgradient, 800×450, 15 bilder/s, 2 s; kolumnen x = 6 i bakgrunden:
- ImageIO (palett per ruta, inget gitter): 205 kB, 11 färger, band upp till **110 px**.
- `CIDither` före ImageIO: står still mellan rutor men tar inte bort banden (49 px vid 0,04).
- Egen palett + Floyd–Steinberg: jämn, men **1,3 MB** (bruset komprimeras dåligt) och enstaka
  avvikande prickar där felet samlas.
- Egen palett + Bayer 8×8, spridning 10 (vald): 248 kB (+21 %), längsta band 22 px, bakgrunden
  identisk mellan rutorna. Spridning 6 räckte inte (58 px). Median cut måste vikta lådorna med
  antalet pixlar — bara omfånget lade färgerna på avvikare (8 färger i gradienten).
- Exporten tar två varv (palett, sedan gitter): 0,71 s för 2 s film mot 0,31 s.

## Rörelseoskärpa (2026-11-05)

- Core Images filter är inte i pixlar: `CIMotionBlur` med radie r ger ett streck på ~4,7 r
  (åt båda håll); `CIZoomBlur` drar ut en punkt ~0,023 × avståndet till mitten × `inputAmount`
  (mängd 10 på 500 px avstånd: 115 px). Första försöket med radien som halva längden och mängden
  i pixlar gjorde en snabb inzoomning (1 → 2,5× på 0,3 s) till oläsliga strimmor.
- Kalibrerat: slutare halva rutan (1/120 s), högst 18 px vid 1080p — texten går att ana mitt i
  samma zoom (provinspelning, ruta 0,95 s). Enhetsprov: stilla före och mitt i zoomen, rörelse i
  rampen, ingenting i ett snitt.

## Ljud per app (2026-11-05)

`--prov-appljud`: två `afplay` (440 och 660 Hz, volym 0,15) samtidigt; den ena får ett eget spår
(tapp per process), "övrigt datorljud" är en global tapp utom den och oss själva. Utgång: AirPods.
- **Separation:** appspåret 440 Hz 0,170 / 660 Hz 0,000002–0,00005, övrigt 660 Hz 0,170 /
  440 Hz 0,000004–0,00016 — 69–93 dB isär.
- **Synk mot ScreenCaptureKits datorljud:** samma `afplay` i båda, skarp 1 kHz-ansats, samma
  `RecordingClock`: 0,00–0,06 ms (aggregatenhet med bara tappen). Med högtalarna som underenhet
  i aggregatenheten 1,7 ms, och en gång −147 ms — därför bara tappen.
- `kAudioProcessPropertyBundleID` + `responsibility_get_pid_responsible_for_pid` (libSystem,
  odokumenterad) knyter hjälpprocesser till appen: `com.google.Chrome.helper` → Chrome,
  `com.apple.WebKit.GPU` → Mail respektive CodeRunner, `com.microsoft.teams2.modulehost` → Teams.
- ⚠️ **Inget annat på tappens ljudkö.** Att räkna om processlistan tar 80–190 ms
  (`NSRunningApplication` utanför huvudtråden); på ljudkön missade IOProc 0,19–0,25 s varje gång
  en app började eller slutade spela. Listan räknas nu på en egen kö och apparna cachas.
- En ny tapp ger nollor de första 50–200 ms.
- Ett hack på ~1 s i första körningen efter en paus, när en ny ljudklient ansluter: syns lika i
  ScreenCaptureKits datorljud **utan** tappar (`--prov-tappglapp … sck+ny`). Det är källan
  (`afplay` på AirPods via Bluetooth) som tystnar, inte inspelningen.
- Tillståndet (Ljudinspelning) gäller den ansvariga processen: från Terminal frågar macOS om
  Terminal; startad som app om appen. Frågan blockerar tappen tills den besvaras.

## HDR (2026-11-05)

Inbyggd XDR-skärm (`maximumPotentialExtendedDynamicRangeColorComponentValue` 16).
- **ScreenCaptureKits förval** (uppmätt på buffertarna): `captureHDRStreamLocal/CanonicalDisplay`
  ger `xf44` (4:4:4 10 bit) i Display P3 PQ; `captureHDRRecordingPreservedSDRHDR10` (macOS 26) ger
  `x420` i BT.2020 PQ, matris 2020 — direkt till HEVC Main10. Vi använder det senare. **Alla tre
  lägger SDR-vitt på 100 nits** (Y 509 av 64–940, PQ 0,508).
- **Core Image har SDR-vitt på 203 nits** (BT.2408): linjärt 1,0 → HLG 0,7495, PQ 0,581; PQ 100
  nits avkodas till 0,492. Renderaren lyfter därför skärmen ×2,03. HLG:s tak är 4,93 (1000/203).
- `CIToneMapHeadroom` 16 → 4,93 lämnar allt upp till 1,0 orört (1,5 → 1,42, 4 → 2,64, 16 → 4,93);
  mot 1,0 sänker den SDR-vitt till 0,35 — därför klipps högdagrarna till SDR i stället.
- ⚠️ **AVFoundation gör om källrutorna till kompositionens färgrymd** om den har färgegenskaper,
  trots `supportsHDRSourceFrames`: kompositören fick `x420` märkt HLG respektive BT.709. Dess egen
  PQ → SDR lägger vitt på 197 och 0,2 linjärt på 109. För HDR-inspelningar får kompositionen inga
  färgegenskaper; rutorna kommer då som PQ och kompositören märker utdata själv.
- ⚠️ **Core Image lägger en knä-kurva vid utritning till 8-bitars sRGB när en PQ-källa finns i
  grafen:** linjärt 0,999 blev 229 (0,2 rätt: 124), lika med `toneMapHDRtoSDR` = nej, innehålls-
  huvudrum 1 eller 0, `CIColorClamp`, `insertingIntermediate`, bitmap eller `CIRenderDestination`.
  Bara en uttrycklig mellanbild (linjärt RGBAh, intagen som ny bild) ger 255. Görs i bildytans
  storlek i SDR-kompositören, och för miniatyrer.
- **Syntetiskt paket** (`--prov-hdr-syntetisk`, HEVC Main10 PQ med 20/100/400 nits): HLG-export
  0,455 / 0,749 / 0,904 (Core Image: 0,456 / 0,750 / tonmappat 2,64 → 0,905); SDR-export 123 / 253
  / 253 (klippt); miniatyr 124 / 255 / 255 (generatorns egen SDR: 89 / 186 / 250).
- **Live** (`--prov-hdr`, eget fönster med 0,2, 1,0 och 4,0 linjärt via `preferredDynamicRange =
  .high`), efter rättningarna: inspelningen 20 / 100 / 398 nits, HLG-export 0,453 / 0,749 / 0,903,
  SDR-export 121 / 253 / 253 — som det syntetiska. Fältet 4,0 spelades in som 398 nits — 4× även när skärmens huvudrum just då var 2,3 (canonical
  följer innehållet, inte skärmens ljusstyrka).
- Exportfart, syntetiskt paket i full storlek (3024×1964, 60 bilder/s, 6 s, stillastående
  innehåll): "MP4 4K HDR" (3326×2160, HLG) 2,0× realtid; "MP4 1080p" från HDR, med den linjära
  mellanbilden, 4,8× realtid.
