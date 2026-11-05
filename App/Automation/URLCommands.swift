import Foundation
import AppKit
import AppIntents
import RecorderKit

/// Styrning utifrån av den vanliga appen: URL-schemat och Genvägar.
@MainActor
enum URLCommands {
    static func handle(_ url: URL) {
        guard url.scheme == "skarminspelare" else { return }
        let app = AppModel.shared
        let command = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch command {
        case "spela-in", "record", "start": if app.recorder.phase == .idle { app.recorder.recordDisplayUnderMouse() }
        case "stoppa", "stop": Task { await app.recorder.stop() }
        case "vaxla", "toggle": app.recorder.toggleFromHotKey()
        case "paus", "pause": app.recorder.togglePause()
        case "omrade", "area": app.recorder.recordArea()
        case "fonster", "window": app.recorder.recordWindow()
        case "bibliotek", "library": app.showLibrary()
        case "oppna", "open":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let path = items.first(where: { $0.name == "sokvag" || $0.name == "path" })?.value {
                app.openEditor(RecordingBundle(url: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)))
            } else if let latest = RecordingLibrary.scan().first {
                app.openEditor(latest.bundle)
            }
        default: break
        }
    }
}

// MARK: - Genvägar

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Spela in skärmen"
    static let description = IntentDescription("Börjar spela in skärmen där pekaren är.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        if AppModel.shared.recorder.phase == .idle { AppModel.shared.recorder.recordDisplayUnderMouse() }
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stoppa inspelningen"
    static let description = IntentDescription("Stoppar inspelningen och sparar den i biblioteket.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        await AppModel.shared.recorder.stop()
        return .result()
    }
}

struct PauseRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pausa eller fortsätt inspelningen"
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.recorder.togglePause()
        return .result()
    }
}

struct OpenLatestRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Öppna senaste inspelningen"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        if let latest = RecordingLibrary.scan().first { AppModel.shared.openEditor(latest.bundle) }
        return .result()
    }
}

struct SkarminspelareShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: ["Spela in skärmen med \(.applicationName)",
                                                              "Starta \(.applicationName)"],
                    shortTitle: "Spela in", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(), phrases: ["Stoppa \(.applicationName)"],
                    shortTitle: "Stoppa", systemImageName: "stop.circle")
        AppShortcut(intent: OpenLatestRecordingIntent(), phrases: ["Öppna senaste inspelningen i \(.applicationName)"],
                    shortTitle: "Senaste inspelningen", systemImageName: "film")
    }
}
