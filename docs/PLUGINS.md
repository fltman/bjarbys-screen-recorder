# Insticksprogram

Ett insticksprogram är en mapp i
`~/Library/Application Support/Bjarbys skärminspelare/Plugins/` med en `plugin.json` och ett
körbart program, skrivet i vilket språk som helst. Appen kör programmet:

- vid **händelser** som det lyssnar på (`hooks`): `recording.finished` (en inspelning är klar)
  och `export.finished` (en export är klar), i bakgrunden;
- som en **åtgärd** (`actions`) som användaren väljer: efter en export finns menyn
  Insticksprogram i exportfönstret.

Nya insticksprogram är **avslagna**. Användaren slår på dem under Insticksprogram … i menyn —
de är program som körs på datorn, med användarens rättigheter.

## plugin.json

```json
{
  "name": "Kontrollsumma",
  "version": "1",
  "description": "Visar storleken och SHA-256 för den exporterade filen.",
  "run": "run.sh",
  "hooks": ["export.finished"],
  "actions": [{ "id": "sha256", "title": "Visa kontrollsumma", "on": "export" }]
}
```

`run` måste ligga i insticksprogrammets mapp och vara körbart (`chmod +x`).

## In och ut

Programmet får händelsen som JSON på **stdin** och miljövariabeln `SKARMINSPELARE_EVENT`:

| Fält | |
|---|---|
| `event` | `recording.finished`, `export.finished` eller `action` |
| `action` | åtgärdens `id` (vid `action`) |
| `file`, `files` | den exporterade filen (och alla, vid flera format) |
| `recording` | inspelningens paket (`.bsrec`, se `FORMAT.md`) |
| `presets` | exportens förval (vid `export.finished`) |
| `plugin`, `appVersion` | |

Det kan svara med JSON på **stdout**: `message` (visas), `url` (läggs i urklipp och visas) och
`file`. Annan text på stdout visas som meddelande. En kod skild från 0 är ett fel; stderr visas.
Programmet avbryts efter 10 minuter.

## Exempel

`examples/plugins/kontrollsumma/` i repot: kopiera mappen till insticksmappen och slå på den.
MCP-verktygen `list_plugins` och `run_plugin_action` når samma insticksprogram (bara påslagna).
