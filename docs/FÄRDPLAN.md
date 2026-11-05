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
