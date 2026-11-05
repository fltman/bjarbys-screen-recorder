# Färdplan

Prioritetsordningen kommer ur utredningarna (`docs/utredningar/`): först att aldrig tappa en
tagning, sedan redigerbar polish, sedan resten.

| Fas | Innehåll | Läge |
|---|---|---|
| 0 | Stomme: repo, Xcode-projekt, signering, tom menyradsapp | klar 2026-11-04 |
| 1 | Inspelningsmotor: skärm/fönster/område, mik + datorljud på egna spår, kamera, markör som data, fragmenterad skrivning, kraschåterställning, disk- och mikvakt, HUD | klar 2026-11-04 |
| 2 | Polish-redigerare: fjäderzoom, syntetisk markör, bakgrund, kamerabubbla, tidslinje, export MP4/HEVC/ProRes/GIF | klar 2026-11-04 |
| 3 | Transkript och redigering via text, utfyllnadsord/tystnad bort, undertexter, brusreducering, loudness, ducking. ⚠️ SpeechTranscriber kan inte svenska → KB-Whisper/whisper.cpp | klar 2026-11-05: transkript, text-redigering, undertexter (inbrända + .srt), dödtid, eh/öh, ducking, utjämning till −16 LUFS, brusreducering (Apples röstisolering) |
| 4 | Maskning av känslig info: Vision-OCR, masker som följer texten, ogenomskinliga fyllningar | klar 2026-11-05 (egna masker justeras med reglage, inte genom att dra i bilden) |
| 5 | Flashback-buffert (egen, SDK saknar SCClipBufferingOutput), App Intents, URL-schema, CLI + MCP, steg-för-steg-guide, felrapport | |
| 6 | HDR, 120 fps med jämn takt, ProRes 4444 med alfa, ljud per app (CATapDescription), teleprompter, stillbild/rullande skärmbild, delning till egen S3/R2 | |

## Kvar från fas 1–2 att pröva eller göra

- Redigeraren interaktivt med mus (dra zoomblock, dela, ångra) — layouten är granskad utanför
  skärmen, rutorna och exporten är provade, men ingen har suttit och klickat i den än.
- Kameraspåret är inte provat med en riktig kamera (koden finns, provet kördes utan).
- Fönsterinspelning där fönstret flyttas under inspelningen (`frame`-händelser) är inte provad.
- Ändringsbara kortkommandon; rörelseoskärpa vid panorering; gifski om ImageIO-GIF:en bandar.

## Byggt efter fas 2

- Dölj känsligt (fas 4, 2026-11-05): `RecorderKit/Privacy/`. Mönster för e-post, telefon,
  personnummer, kort (Luhn) och nycklar/lösenord; Vision läser skärmspåret; masker med
  nyckelrutor i innehållets koordinater (oskärpa, pixlar eller fylld). Egna masker läggs till
  vid spelhuvudet och justeras med reglage. Att dra masker direkt i bilden är inte byggt.
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
- Reel-läge (2026-11-05): `framing: fill` låter inspelningen fylla en bildyta med andra
  proportioner. Kameran följer då markören även utan zoom, med samma säkra zon och
  framförhållning som inom en zoom.
