# Färdplan

Prioritetsordningen kommer ur utredningarna (`docs/utredningar/`): först att aldrig tappa en
tagning, sedan redigerbar polish, sedan resten.

| Fas | Innehåll | Läge |
|---|---|---|
| 0 | Stomme: repo, Xcode-projekt, signering, tom menyradsapp | klar 2026-11-04 |
| 1 | Inspelningsmotor: skärm/fönster/område, mik + datorljud på egna spår, kamera, markör som data, fragmenterad skrivning, kraschåterställning, disk- och mikvakt, HUD | klar 2026-11-04 |
| 2 | Polish-redigerare: fjäderzoom, syntetisk markör, bakgrund, kamerabubbla, tidslinje, export MP4/HEVC/ProRes/GIF | klar 2026-11-04 |
| 3 | Transkript och redigering via text, utfyllnadsord/tystnad bort, undertexter, brusreducering, loudness, ducking. ⚠️ SpeechTranscriber kan inte svenska → KB-Whisper/whisper.cpp | klar 2026-11-05: transkript, text-redigering, undertexter (inbrända + .srt), dödtid, eh/öh, ducking, utjämning till −16 LUFS, brusreducering (Apples röstisolering) |
| 4 | Maskning av känslig info: Vision-OCR, masker som följer texten, ogenomskinliga fyllningar | klar 2026-11-05 (egna masker justeras med reglage eller genom att dra i bilden) |
| 5 | Flashback-buffert (egen, SDK saknar SCClipBufferingOutput), App Intents, URL-schema, CLI + MCP, steg-för-steg-guide, felrapport | klar 2026-11-05: MCP-server, URL-schema, Genvägar, steg-för-steg-guide, flashback-buffert, felrapport |
| 6 | HDR, 120 fps med jämn takt, ProRes 4444 med alfa, ljud per app (CATapDescription), teleprompter, stillbild/rullande skärmbild, delning till egen S3/R2 | klar 2026-11-05: teleprompter, ProRes 4444 med alfa, polerade skärmdumpar, delning till S3/R2, 120 fps (inspelning 108 rutor/s uppmätt), ljud per app (Core Audio-tappar, ett spår per app, uppmätt), HDR (10 bit PQ in, HLG eller SDR ut, uppmätt) |

## Kvar från fas 1–2 att pröva eller göra

- Redigeraren interaktivt med mus (dra zoomblock, dela, ångra) — layouten är granskad utanför
  skärmen, rutorna och exporten är provade, men ingen har suttit och klickat i den än.

## Byggt efter fas 2

- Redigering som en riktig klippredigerare (2026-11-05, påbörjad): fritt textlager, bildlager
  från fil, övergångar i snitten (via svart, oskärpa med zoomstöt, blixt), toning in/ut, extra
  ljudklipp, videoinslag (eget videospår och ljud per inslag, bild-i-bild eller helbild).
  Övertoning mellan delar (skärmspår B med för- och efterrulle, filmens längd oförändrad) och
  övergång per snitt (`transitionIn` på delen), ljudövertoning (B-spår för mik och datorljud)
  och 20 ms toning i varje snitt, lager som dras och skalas direkt i förhandsvisningen.

- Delning (fas 6, 2026-11-05): `RecorderKit/Share/S3.swift`, egen SigV4 (CryptoKit), PUT med
  `UNSIGNED-PAYLOAD` i sökvägsstil; inställningar under «Delning …», hemlig nyckel i nyckelringen.
  «Ladda upp och kopiera länk» efter export; MCP `export` med `upload: true`.
- Felrapport (fas 5, 2026-11-05): `RecorderKit/Guide/BugReport.swift`. `rapport.md` (vad som
  sades, miljö med programmets version, steg för att återskapa med tider), filmen, guiden och
  programmets systemlogg (`log show` för inspelningens tid ± 1 min), som mapp och zip.
  Exportfönstret och MCP-verktyget `make_bug_report`.
- Polerade skärmdumpar (fas 6, 2026-11-05): fönster (utan systemets skugga, med egna hörn),
  område eller hela skärmen på filmernas bakgrund med marginal och skugga som följer formen.
  Menyn sparar i biblioteket under Skärmdumpar och kopierar till urklipp; MCP-verktyget
  `screenshot` tar en apps största fönster — för README-bilder.
- Teleprompter (fas 6, 2026-11-05): manus i ett eget fönster, rullar i ord/min i en ruta högt
  upp vid kameran under inspelningen, pausar med inspelningen. Klick i appens egna paneler
  (teleprompter, HUD, kamerabubbla) loggas inte längre — de blev annars zoomar mot knappar
  som inte syns i filmen.
- Flashback (fas 5, 2026-11-05): `RecorderKit/Capture/Flashback.swift`. Sessioner à 60 s
  som överlappar, i `~/Library/Caches/com.brattoo.skarminspelare/flashback`; "Spara senaste
  N min" (⌃⌥⌘S, menyn, `skarminspelare://flashback-spara`, Genvägar) syr ihop dem rakt över till
  ett vanligt paket och öppnar redigeraren. Mikrofonen bara om den väljs uttryckligen.
- Steg-för-steg-guide (fas 5, 2026-11-05): `RecorderKit/Guide/`. Varje klick och kortkommando
  blir ett steg med en färdig bild; det som sades kring handlingen blir texten, annars en
  instruktion med elementets namn ("Klicka på knapp «Exportera»", sparas sedan nu vid klick
  med Tillgänglighet). `guide.md` + fristående `guide.html`. I exportfönstret och via MCP.
- Styrning utifrån (fas 5, 2026-11-05): `Skarminspelare --mcp` är en MCP-server (stdio) med
  åtta verktyg — spela in, transkribera, redigera, rendera rutor, exportera — så att agenter
  kan göra demofilmer. URL-schemat `skarminspelare://` och Genvägar-åtgärder styr den vanliga appen.
- Dölj känsligt (fas 4, 2026-11-05): `RecorderKit/Privacy/`. Mönster för e-post, telefon,
  personnummer, kort (Luhn) och nycklar/lösenord; Vision läser skärmspåret; masker med
  nyckelrutor i innehållets koordinater (oskärpa, pixlar eller fylld). Egna masker läggs till
  vid spelhuvudet och justeras med reglage, eller dras och skalas direkt i bilden (alla
  nyckelrutor följer med, så en mask som följer rullande text flyttas som helhet).
- Tal (fas 3, 2026-11-05): transkribering med whisper.cpp (KB-Whisper för svenska) i
  `RecorderKit/Speech/`, `transcript.json` i paketet. Textpanel i redigeraren där överstrukna
  ord är bortklippta och går att ta tillbaka; inbrända undertexter och .srt vid export; "dödtid"
  (inget tal, ingen mus, inga tangenter) klipps bort på en knapp; datorljudet sänks under tal.
  Mikrofonen jämnas ut till −16 LUFS på en knapp (mätt enligt BS.1770, kalibrerad mot
  ffmpeg). Bakgrundsljud tas bort med Apples röstisolering, körd offline till
  `derived/mic-isolated.caf`. Utfyllnadsord finns som knapp, men
  KB-Whisper skriver sällan ut "eh" (tränad på textning som stryker dem).

- Kortkommandon i filmen (2026-11-05): bubbla nere eller uppe i mitten, räknar upp
  upprepningar ("⌘Z ×3"), visas i utdatatid så att 4×-delar inte blinkar förbi.
- Snabba upp pauser och ordmarkering (2026-11-05): dödtiden kan spelas i 4× i stället för att
  klippas (nya snitt utan övergång; MCP `speed_up_dead_time`). Undertexterna kan markera ordet
  som sägs i gult (ordens starttider per ruta; MCP `caption_highlight`).
- Animerade lager (2026-11-05): In — tona, glid upp, poppa (växer med en liten studs) eller
  skrivmaskin (text och rubrik, 35 ms per tecken, 0,4–1,5 s; kortet har full storlek från början
  eftersom resten ritas genomskinligt). MCP: `animation` i `set_overlays`.
- Ljudnivå vid export (2026-11-05): Som den är / −14 LUFS / −16 LUFS. Hela mixen (eller
  utsnittet) mäts i stereo enligt BS.1770 och varje ljudbuffert skalas; förstärkningen begränsas
  så att topparna stannar under −1 dBFS. MCP: `loudness`.
- Strålkastare och fästpunkter (2026-11-05): zoomblockets tredje sort dämpar skärmytan (55 %)
  utom en mjuk cirkel kring markören. Zoomblock och lager som dras i tidslinjen fäster (6 px)
  mot spelhuvudet, I/O, snitten och filmens ändar, med en gul linje; ⌘ stänger av.
- Lupp (2026-11-05): ett zoomblock kan vara av sorten Lupp — kameran står still och ett runt
  förstoringsglas (18 % av skärmhöjden, vit kant, skugga) följer markören och förstorar det som
  syns, med maskerna; växer fram och krymper bort på 0,25 s. "Ny lupp" vid spelhuvudet.
- Fönsterram (2026-11-05): Stil › Bild › Fönsterram — ingen, macOS-fönster (titelrad med de tre
  prickarna och titel) eller webbläsare (adressfält med en egen adress), ljus eller mörk. Raden
  tar plats ovanför skärmen (skärmytan krymper), ritas en gång till en IOSurface och omfattas av
  ramens rundade mask och skugga; kameralayouterna flyttar hela fönstret. Inte i Reel-läge.
  MCP: `window_frame`, `window_frame_dark`, `window_title`, `window_address`.
- Kapitel i filen och Dela (2026-11-05): kapitlen skrivs som kapitelspår (tx3g-text kopplad med
  `chap` till video- eller ljudspåret) i MP4, MOV och M4A — för ett utsnitt räknade från dess
  början, med kapitlet som pågår där först. Efter exporten: Dela … (systemets Dela-meny) och
  Kopiera kapitel (YouTube-tidsstämplar). MCP `export` svarar med tidsstämplarna.
- Pennan (2026-11-05): rita på skärmen under inspelningen (⌃⌥⌘D, HUD:ens penna, menyn; 1–5
  färg, Esc slutar). Ett genomskinligt fönster per skärm tar emot musen; strecken syns direkt och
  tonas bort efter 3 s, men appen är utesluten ur inspelningen, så de sparas som `ink`-händelser
  och ritas av renderaren — i innehållet (zoomar med det, skarpa i zoomens upplösning), under
  markören, avstängbara och med valfri tid kvar (Rörelse › Pennan; MCP `ink`, `ink_hold`).
  Medan pennan är på blir musens drag rörelser (markören följer pennan) och nedtrycken loggas
  inte (annars hade strecken blivit klick och zoomar). Producentens underlag listar strecken.
- Bara ljudet (2026-11-05): exportens förval Ljud M4A (AAC 256 kbit/s), Ljud WAV (24 bit, 48 kHz)
  och Ljudspår var för sig — en mapp med en WAV per källa (mikrofon och datorljud med sina
  B-spår, varje app, berättarröst, musik, ljudeffekter, videoinslag, klick), lika långa som
  filmen och med mixens volymer, duckning, snitt-toningar och ljudnivå, så att de summerar till
  mixen. Ingen bild renderas. MCP: `export` med `ljud-m4a`, `ljud-wav`, `ljud-spar`.
- Slå ihop inspelningar (2026-11-05): Biblioteket › högerklick › Slå ihop med andra … lägger de
  valda efter varandra i tidsordning i ett nytt paket. Spåren kopieras rakt över (passthrough,
  ingen omkodning; ett spår som saknas i en tagning blir en lucka), händelserna flyttas i tid och
  mot den första tagningens ram, varje tagning börjar med en `frame`-händelse, markörbilder och
  transkript följer med (en ny tagning börjar en ny undertextrad). Samma upplösning och samma
  HDR/SDR krävs. `RecorderKit/Project/RecordingMerger.swift`; MCP `merge_recordings`.
- Utsnitt och stillbild (2026-11-05): I och O sätter in- och utpunkt, X tar bort (tonat i
  tidslinjen); exporten kan ta bara utsnittet (alla förval, ljudet tonas 20 ms i kanterna, .srt
  räknad från utsnittets början; MCP `range`). Exportfönstrets Mer › Spara bild vid spelhuvudet
  ger den färdiga rutan som PNG, 4K på kortaste sidan.
- Klickljud (2026-11-05): Rörelse › Markör › Klickljud och volym; ett syntetiserat mjukt klick
  (60 ms, i appens cache) på ett eget ljudspår vid varje musklick som finns kvar i filmen. Följer
  med i standardutseendet. MCP: `click_sound`.
- Kameralayout per del (2026-11-05): Markerad del › Kamera — bubbla, stor (fyller bilden; skärmen
  tonas bort), sida vid sida (skärmen inpassad bredvid en kamerapanel; staplat i stående format)
  eller dold. Bytet efter ett snitt glider på 0,5 s: skärmlagret (med markör och markeringar)
  flyttas och skalas som helhet, kameran beskärs till layoutens proportioner. MCP: fjärde
  elementet i `set_segments`.
- Städad inspelning (2026-11-05): Inspelning › Dölj skrivbordssymboler / Dölj notiser och widgets
  (skärm och område; MCP `hide_desktop_icons`, `hide_notifications`). Ingenting på skärmen eller i
  systemet ändras: Finder och notisapparna utesluts ur filtret, Finders vanliga fönster tas med
  och filtret byts när nya Finderfönster öppnas.
- Kamerabakgrund (2026-11-05): Stil › Kamera › Bakgrund — som den är, suddig eller borttagen
  (filmens bakgrund, något mörkare, bakom personen). `VNGeneratePersonSegmentationRequest`
  (balanserad) på en nedskalad kopia per ruta, mjuk maskkant. MCP: `camera_backdrop`.
- Standardutseende (2026-11-05): Stil › Standardutseende sparar projektets utseende (bakgrund,
  ram, format, markör, kamera, kortkommandon, undertexter, övergångar, zoomnivå) i
  inställningarna; nya projekt får det (`EditProject.standardStyle`, också i MCP-läget), och
  "Använd här" ger ett befintligt projekt det. Innehållet rörs aldrig.
- Trimma delar i tidslinjen (2026-11-05): dra i en dels ände för att flytta början eller slutet
  i inspelningen (inget tas bort, materialet går att dra fram igen; stannar vid grannarna, vid
  inspelningens ändar och vid 0,1 s); ⌥-dra för att sträcka delen till en ny fart (0,25–8×).
  Spelhuvudet hamnar på den nya kanten; tidslinjen ritas direkt ur delarna medan man drar.
  Den markerade delen dras till en ny plats (spöke och insättningsmärke); Q och W trimmar
  början och slutet av delen under spelhuvudet till spelhuvudet (som i Premiere; ⌥[ och ⌥]
  gick inte att trycka på ett svenskt tangentbord, där klamrarna själva kräver ⌥).
- Videoinslag med hastighet 0,25–4×, beskärning och mjuka kanter (2026-11-05), i lagrets
  inspektör och via MCP (`speed`, `crop`, `softness`). Delarna kan nu också gå i 0,25×.
- GIF utan band (2026-11-05): ImageIOs palett per ruta bandade (uppmätt), så GIF:en får en
  egen gemensam palett (median cut ur stickprov från hela filmen) och ordnat gitter (Bayer 8×8)
  — inget gifski-beroende. `RecorderKit/Export/GIFPalette.swift`.
- Rörelseoskärpa (2026-11-05): valfri under Rörelse › Zoom (`motionBlur`). Kamerans rörelse
  under 1/60 s ger riktad oskärpa vid panorering och radiell vid zoom, slutare halva rutan,
  högst 18 px vid 1080p; ingenting i snitt eller när kameran står still.
- Ändringsbara kortkommandon (2026-11-05): Inställningar › Kortkommandon …, ett fält per
  åtgärd; tryck den nya kombinationen (⌘, ⌃ eller ⌥, eller en F-tangent). Krockar inom appen
  byter plats; upptagna av andra program varnas. Menyerna och panelerna visar de valda.
- Reel-läge (2026-11-05): `framing: fill` låter inspelningen fylla en bildyta med andra
  proportioner. Kameran följer då markören även utan zoom, med samma säkra zon och
  framförhållning som inom en zoom.
