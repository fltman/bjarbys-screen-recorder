import Foundation
import AppKit

/// Felrapport ur en inspelning: en mapp (och en zip) med `rapport.md` — vad som sades,
/// miljön, stegen för att återskapa — plus filmen, guiden med en bild per steg och, om appen
/// är känd, dess systemlogg från inspelningens tid. För att skicka till en utvecklare, eller
/// lämna till en agent.
public enum BugReport {
    public struct Output: Sendable {
        public let folder: URL
        public let zip: URL?
        public let report: URL
    }

    public struct Environment: Sendable, Equatable {
        public var macOS: String
        public var model: String
        public var app: String?
        public var appVersion: String?

        public static func current(app: String?) -> Environment {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            var env = Environment(macOS: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                                  model: hardwareModel(), app: app, appVersion: nil)
            if let app, let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveCompare(app) == .orderedSame || $0.bundleIdentifier == app
            }), let url = running.bundleURL, let bundle = Bundle(url: url) {
                let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                env.appVersion = [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
                env.app = running.localizedName ?? app
            }
            return env
        }

        static func hardwareModel() -> String {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var buffer = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.model", &buffer, &size, nil, 0)
            let model = String(cString: buffer)
            return model.isEmpty ? "Mac" : model
        }
    }

    /// Texten i rapporten (ren funktion, provbar).
    public static func markdown(title: String, guide: StepGuide, environment env: Environment,
                                recordedAt: Date, duration: Double, video: String?, hasLog: Bool) -> String {
        let sv = !guide.language.hasPrefix("en")
        let f = DateFormatter()
        f.locale = Locale(identifier: sv ? "sv_SE" : "en_US")
        f.dateStyle = .long
        f.timeStyle = .short
        var md = "# \(title)\n\n"
        let said = ([guide.intro] + guide.steps.map(\.spoken)).filter { !$0.isEmpty }.joined(separator: " ")
        if !said.isEmpty { md += (sv ? "## Vad som händer\n\n" : "## What happens\n\n") + said + "\n\n" }
        md += sv ? "## Miljö\n\n" : "## Environment\n\n"
        if let app = env.app { md += "- \(sv ? "Program" : "App"): \(app)\(env.appVersion.map { " \($0)" } ?? "")\n" }
        md += "- \(env.macOS), \(env.model)\n"
        md += "- \(sv ? "Inspelad" : "Recorded"): \(f.string(from: recordedAt)) (\(String(format: "%.0f", duration)) s)\n\n"
        md += sv ? "## Steg för att återskapa\n\n" : "## Steps to reproduce\n\n"
        if guide.steps.isEmpty {
            md += sv ? "_Inga klick eller kortkommandon i inspelningen; se filmen._\n\n" : "_No clicks or shortcuts in the recording; see the video._\n\n"
        }
        for (i, step) in guide.steps.enumerated() {
            md += "\(i + 1). \(step.instruction(guide.language))"
            md += String(format: " _(%.1f s)_", step.outputTime)
            if !step.spoken.isEmpty { md += " — \(step.spoken)" }
            md += "\n"
        }
        md += sv ? "\n## Bilagor\n\n" : "\n## Attachments\n\n"
        if let video { md += "- [\(sv ? "Filmen" : "Video")](\(video))\n" }
        if !guide.steps.isEmpty { md += "- [\(sv ? "Steg för steg med bilder" : "Step by step with images")](guide/guide.html)\n" }
        if hasLog { md += "- [\(sv ? "Systemlogg" : "System log")](logg.txt)\n" }
        return md
    }

    /// Gör rapporten. `app`: programmet felet gäller (för version och logg), om det är känt.
    public static func make(_ rec: LoadedRecording, project: EditProject, title: String, app: String?,
                            in folder: URL) async throws -> Output {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let spoken = rec.transcript?.language
        let guide = StepGuide(events: rec.events, words: rec.transcript?.words ?? [],
                              timeMap: TimeMap(segments: project.segments),
                              language: spoken.flatMap { $0 == "auto" || $0.isEmpty ? nil : $0 })
        let appName = app ?? (rec.meta.source.kind == .window || rec.meta.source.kind == .application ? rec.meta.source.title : nil)
        let env = Environment.current(app: appName)

        // Filmen (MP4 1080p) och guiden.
        let preset = ExportPreset.all.first { $0.id == "mp4-1080" }!
        let video = folder.appendingPathComponent("film.mp4")
        try await Exporter(recording: rec, project: project, preset: preset).run(to: video) { _ in }
        if !guide.steps.isEmpty {
            _ = try await GuideMaker.make(rec, project: project, title: title, in: folder.appendingPathComponent("guide"))
        }

        // Systemloggen för programmet under inspelningen (med en minuts marginal).
        var hasLog = false
        if let name = env.app ?? appName {
            let started = rec.meta.createdAt
            let end = started.addingTimeInterval(rec.meta.duration + 60)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let log = folder.appendingPathComponent("logg.txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--style", "compact", "--info",
                                 "--start", f.string(from: started.addingTimeInterval(-60)), "--end", f.string(from: end),
                                 "--predicate", "process == \"\(name.replacingOccurrences(of: "\"", with: ""))\""]
            FileManager.default.createFile(atPath: log.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: log) {
                process.standardOutput = handle
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
                try? handle.close()
                let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
                // Bara rubriken = inget loggat; ta bort hellre än att bifoga en tom fil.
                if size > 200 { hasLog = true } else { try? FileManager.default.removeItem(at: log) }
            }
        }

        let report = folder.appendingPathComponent("rapport.md")
        try markdown(title: title, guide: guide, environment: env, recordedAt: rec.meta.createdAt,
                     duration: TimeMap(segments: project.segments).outputDuration,
                     video: "film.mp4", hasLog: hasLog).write(to: report, atomically: true, encoding: .utf8)

        // Zip bredvid mappen (ditto, som Finder: behåller å/ä/ö och metadata).
        let zip = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
        try? FileManager.default.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
        try? ditto.run()
        ditto.waitUntilExit()
        let zipped = ditto.terminationStatus == 0 && FileManager.default.fileExists(atPath: zip.path)
        return Output(folder: folder, zip: zipped ? zip : nil, report: report)
    }
}
