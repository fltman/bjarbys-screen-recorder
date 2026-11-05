# Projektpaketet `.bsrec`

En inspelning är en vanlig mapp (ett macOS-paket, UTType `com.brattoo.skarminspelare.project`)
i `~/Movies/Bjarbys skärminspelare/`. Allt är öppna format; inget är krypterat eller
proprietärt. Formatversion: `schemaVersion` = 1.

```
Inspelning 2026-11-04 kl. 22.27.41.bsrec/
  recording/                 rådata från inspelningen — skrivs bara under inspelning
    meta.json
    screen-0.mov             HEVC, utan markör
    system-0.mov             datorljud, LPCM 24 bit
    mic-0.mov                mikrofon, LPCM 24 bit, källans kanaler och frekvens
    camera-0.mov             HEVC (valfri)
    events.jsonl             mus, tangenter, markörbyten, fönsterramar, pauser
    cursors.json
    cursors/<hash>.png
  project.json               redigeringsläget (fas 2) — det enda redigeraren skriver
  thumbnail.jpg
```

## Tidslinjen

Alla spår och alla händelser delar tidslinje: sekunder från **första hela skärmrutan**, med
pauser borträknade. Ett spår som börjar senare (mikrofonen när AirPods byter till HFP, ~0,5 s)
har en tom redigering först — `start_time` i filen är dess verkliga start, inte noll.

Spåren är fragmenterade QuickTime-filer (`movieFragmentInterval` = 2 s). Efter en krasch går
de att spela upp till sista fragmentet; `meta.json` har då `finished: false` tills appen
återställt paketet (`recovered: true`).

## meta.json

| Fält | Betydelse |
|---|---|
| `source.kind` | `display`, `window`, `area` eller `application` |
| `source.contentRect` | `[x, y, b, h]` i globala punkter, origo uppe till vänster på huvudskärmen |
| `source.pixelScale`, `pixelWidth`, `pixelHeight` | skärmspårets pixlar |
| `tracks[]` | `kind`, `file`, `deviceName`, `failed` |
| `duration` | sekunder, pauser borträknade |
| `gaps[]` | avbrott där vakthunden startade om strömmen |
| `keystrokesRecorded` | om kortkommandon spelades in |

## events.jsonl

En JSON-rad per händelse. `t` = sekunder på tidslinjen. Koordinater i globala punkter.

| `k` | Fält |
|---|---|
| `move`, `drag` | `x`, `y` (drag även `b`) |
| `down`, `up` | `x`, `y`, `b` (0 vänster, 1 höger, 2 övriga), `n` antal klick i följd |
| `scroll` | `x`, `y`, `dx`, `dy` (punkter) |
| `key` | `code`, `label` ("⌘⇧S"). Bara kortkommandon, aldrig vanlig text |
| `cursor` | `cursor` = id i `cursors.json` |
| `frame` | `rect` = fönstrets nya ram (bara fönsterinspelning) |
| `element` | `rect` = ramen för gränssnittselementet under ett klick (Accessibility) |
| `pause`, `resume` | — |

Okända `k` läses som `unknown`; en avbruten sista rad hoppas över.

För att räkna om en global punkt till skärmspårets pixlar: dra av `contentRect`-origo (för
fönster: senaste `frame`-ramen), multiplicera med `pixelScale`. Fönster som ändrat storlek
skalas in med bibehållna proportioner, centrerat.

## project.json

Redigeringen. Alla tider i **källtid**, så att zoomar och kortkommandon sitter kvar på
innehållet när annat klipps bort. Varje fält har ett standardvärde; `{}` är ett giltigt projekt.

| Fält | Betydelse |
|---|---|
| `segments[]` | delarna som är med, i ordning: `start`, `end`, `speed` |
| `zooms[]` | `start`, `end`, `scale`, `centerX`/`centerY` (0–1), `followsCursor`, `isAuto` |
| `autoZoom`, `zoomScale` | föreslå zoomar ur klicken, och hur mycket |
| `background` | `kind` (`gradient`, `solid`, `blur`), `colorA`, `colorB`, `angle` |
| `padding`, `cornerRadius`, `shadow` | ram runt skärmen, andelar |
| `aspect` | `source`, `wide`, `vertical`, `square`, `classic` |
| `framing` | `fit` (hela inspelningen med bakgrund) eller `fill` (fyller bilden, följer markören) |
| `cursor` | `visible`, `scale`, `smoothing`, `hideWhenIdle`, `clickEffect` |
| `shortcuts` | `visible`, `position` (`bottom`, `top`), `size` |
| `captions` | `visible`, `size` — undertexter ur `transcript.json` |
| `masks[]` | `start`, `end`, `keyframes[]` (`t`, `rect` normaliserat), `style` (`blur`, `pixelate`, `solid`), `kind`, `hint` (aldrig själva texten), `enabled` |
| `camera` | `visible`, `shape`, `size`, `corner`, `mirror` |
| `audio` | volym och tystning per spår; `duckSystem`, `duckLevel` sänker datorljudet under tal; `voiceIsolation` använder `derived/mic-isolated.caf` |

## derived/

Filer som räknas fram ur inspelningen och alltid går att göra om.

| Fil | Innehåll |
|---|---|
| `mic-isolated.caf` | mikrofonen efter Apples röstisolering, 48 kHz mono, börjar vid tidslinjens nollpunkt |

## transcript.json

Härlett ur inspelningen och går alltid att göra om (`Transkribera om`). Bortklippta ord är inte
borttagna här; de ligger i luckor mellan `segments` i `project.json`.

| Fält | Betydelse |
|---|---|
| `model`, `language` | modellfilen och språket, t.ex. `kb_whisper_ggml_medium.bin`, `sv` |
| `track` | spåret som transkriberades: `microphone`, annars `system` |
| `words[]` | `start`, `end` (källtid, ±0,1 s), `text` med skiljetecken, `startsSegment` |
