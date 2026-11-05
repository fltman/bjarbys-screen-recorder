# Testlista inför det stora testet

Det som byggts sedan "bygg vidare, vi får ha ett större test senare" (2026-11-05). Allt är
provat med enhetsprov, provlägen och renderade rutor på **påhittade paket** — men inget av det
har suttit framför en människa med mus och tangentbord. Varje rad: vad du gör, vad som ska hända.
Det som inte gått att mäta utan dig är märkt ⚠️.

Bygg först: `./scripts/build.sh`, öppna `dist/Bjarbys skärminspelare.app`.

## Under inspelningen

- [ ] **Pennan** — spela in skärmen, tryck ⌃⌥⌘D (eller pennan i panelen). Pekaren ska bli ett
  hårkors; dra en ring runt något. Strecket syns direkt och tonas bort efter 3 s. 2 byter till gult.
  Esc slutar rita. ⚠️ Esc i en panel som inte aktiverar appen, och hårkorset, är inte provade.
  I redigeraren: strecket ska ritas där du ritade, följa zoomen och tonas bort (Rörelse › Pennan).
  Medan du ritar ska det inte bli några klickzoomar.
- [ ] **Markeringar** — tryck ⌃⌥⌘M ett par gånger (eller flaggan i panelen; räknaren ökar). I
  redigeraren: orange flaggor i tidslinjen; Lager › Markeringar › Gör till kapitel / Dela vid
  markeringarna.
- [ ] **Zoom där man skriver** — slå på Inspelning › Kortkommandon och skrivande (kräver
  Indataövervakning; Tillgänglighet för *var*). Skriv några meningar i ett textfält. I redigeraren
  ska en zoom föreslås kring det du skrev, med stilla kamera. ⚠️ Skrivmarkörens ram via
  Accessibility är bara provad med påhittade händelser — olika appar svarar olika (Safari, Pages,
  Terminal, VS Code). Inga tecken sparas, bara när och var: titta gärna i `events.jsonl`.

- [ ] **Rensa mikrofonen** — Inspelning › Rensa mikrofonen under inspelningen, spela in med
  högtalare (inte hörlurar) medan något låter: ekot ska vara borta. ⚠️ Kör också
  `./scripts/sync-check.sh` med valet på (röstbehandlingens fördröjning är inte mätt).
- [ ] **Kamera / iPhone** — Spela in kamera eller iPhone. ⚠️ En iPhone via kabel är inte provad.

- [ ] **Alla skärmar** — med en extern skärm: Spela in alla skärmar, flytta markören mellan
  skärmarna. I redigeraren ska bilden följa med (16:9, fyll och följ). ⚠️ Inte provad live.
- [ ] **YouTube / Dropbox** — under Delning …: eget klient-id/appnyckel, Anslut, exportera,
  ladda upp. YouTube ska bli privat. ⚠️ Bara provat mot en lokal provserver.
- [ ] **Insticksprogram** — kopiera `examples/plugins/kontrollsumma` till insticksmappen (Öppna
  mappen), slå på den, exportera och välj Insticksprogram › Visa kontrollsumma.

## Redigeraren

- [ ] **Ansiktet i mitten** — en inspelning med kamera där du sitter lite åt sidan: Stil › Kamera
  › Håll ansiktet i mitten. Första gången räknas ansiktena fram (förlopp vid reglaget), sedan ska
  bubblan hålla ansiktet i mitten utan att darra. ⚠️ Igenkänningen på ett riktigt ansikte är inte
  provad (`Skarminspelare --prov-ansikten <paket>` skriver ut vad Vision hittar).
- [ ] **Markörhalo** — Rörelse › Markör › Markera markören, prova färgerna.
- [ ] **Fönsterram** — Stil › Bild › Fönsterram: macOS-fönster med titel, webbläsare med adress,
  ljus och mörk. Prova med en områdesinspelning och med kameralayouten Sida vid sida.
- [ ] **Undertextstil** — Tal › Placering (nere, mitt i, uppe) och Utseende (platta, kontur).
  Med kortkommandon i bild: de ska inte krocka med undertexterna.
- [ ] **Snabbval** — Stil › Bild › Reel / Shorts: stående, fyller bilden, undertexter mitt i.

## Biblioteket

- [ ] **Byt namn** — högerklicka › Byt namn …; tomt namn ger datumet tillbaka.
- [ ] **Sök** — sök på ett ord du sa i en transkriberad inspelning: kortet ska visa citatet.
- [ ] **Slå ihop** — högerklicka › Slå ihop med andra …, välj två av samma storlek. Den nya
  inspelningen öppnas; klick, markör, transkript och pennstreck ska ligga rätt i båda delarna.
  Olika storlek ska ge en varning och en avstängd knapp.

## Export

- [ ] **Flera format** — ⌘-klicka MP4 1080p, MP4 4K och Ljud M4A, Exportera 3 …, välj en mapp.
  Förloppet visar "… 2 av 3"; Visa i Finder markerar alla tre.
- [ ] **Kvalitet** — Liten fil / Normal / Hög; storleksuppskattningen ska följa med.
- [ ] **Bara ljudet** — Ljud M4A, Ljud WAV, Ljudspår var för sig (en mapp med en WAV per källa).
  Lägg spåren i Logic eller Resolve på noll: de ska summera till mixen.
- [ ] **Kapitel** — en inspelning med kapitel: kapitlen ska synas i QuickTime (Visa › Kapitel)
  och i IINA/VLC; Kopiera kapitel ger YouTube-tidsstämplar.
- [ ] **Dela …** — efter exporten: systemets Dela-meny (AirDrop, Mail).

## Uppmätt utan dig (för jämförelse)

Se `docs/VERIFIERAD-STACK.md`: ihopslagning exakt (7,000 s, 210 rutor, tonerna på rätt ställen),
delspåren summerar exakt till mixen, kapitel med å ä ö i både ffprobe och AVFoundation, −16 LUFS
mätt till −16,0, bitraten 5,8 / 11,5 / 18,2 Mbit/s, pennans punkter på rätt global koordinat.
