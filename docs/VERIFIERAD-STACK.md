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
