import Foundation
import AVFoundation

/// Dubbning: undertextraderna på ett annat språk inlästa — en ljudfil per rad, gjorda med
/// elevenlabs-dialogue-skillen i Claude Code (appen har inga nycklar och betalar inget) — och
/// lagda på radernas tider som ljudklipp med rollen `dub`. När filmen har dubbningens röst
/// (`AudioMix.voice`) tystas mikrofonen och raderna hörs i stället; exporten lägger originalet
/// och dubbningen som var sitt ljudspår med språkkod.
public enum Dubbing {
    /// Hur långt en rad får gå in i nästa rads tid innan den spelas fortare (s).
    public static let maxLag = 0.6
    /// Högst så här mycket fortare (tonhöjden behålls).
    public static let maxSpeed = 1.15
    /// Paus mellan två rader som annars skulle gå i varandra (s).
    public static let breath = 0.1
    /// Hur mycket tidigare än originalraden en rad som inte ryms får börja, i tystnaden före (s).
    public static let maxLead = 0.8

    public struct Placement: Equatable, Sendable {
        /// Utdatatid där raden börjar.
        public var at: Double
        public var speed: Double
        /// Hur mycket senare än originalraden den börjar (s).
        public var lag: Double
        /// Hur mycket raden ändå är för lång (s), efter fördröjning och högsta fart.
        public var overrun: Double
        /// Utdatatid där raden slutar.
        public var end: Double
    }

    /// Placerar raderna (utdatatid). Varje rad börjar där originalraden börjar, eller strax efter
    /// föregående rad om den inte hunnit klart. En rad får gå `maxLag` in i nästa rads tid; en
    /// rad som ändå inte ryms börjar upp till `maxLead` tidigare om det är tyst före den, och
    /// räcker inte det spelas den fortare, högst `maxSpeed`. Det som ändå inte ryms rapporteras
    /// som `overrun` — producenten kortar texten och läser in raden igen.
    public static func place(starts: [Double], durations: [Double], end: Double) -> [Placement] {
        var out: [Placement] = []
        var previousEnd = -Double.infinity
        for i in starts.indices {
            let limit = i + 1 < starts.count ? starts[i + 1] + maxLag : end
            let d = durations[i]
            var at = max(starts[i], previousEnd + breath)
            if d > limit - at {
                at = max(at - min(maxLead, d - (limit - at)), previousEnd + breath, 0)
            }
            let room = max(limit - at, 0.01)
            let speed = d > room ? min(maxSpeed, d / room) : 1
            let length = d / speed
            out.append(Placement(at: at, speed: speed, lag: at - starts[i], overrun: max(0, at + length - limit), end: at + length))
            previousEnd = at + length
        }
        return out
    }

    /// Språken det finns dubbning på.
    public static func languages(_ project: EditProject) -> [String] {
        Array(Set(project.audioClips.filter { $0.role == .dub }.map(\.language))).filter { !$0.isEmpty }.sorted()
    }

    /// Dubbningsradernas tid i filmen.
    public static func ranges(_ project: EditProject, language: String, timeMap: TimeMap) -> [ClosedRange<Double>] {
        project.audioClips.filter { $0.role == .dub && $0.language == language }.compactMap { c in
            timeMap.output(at: c.at).map { $0...($0 + c.outputDuration) }
        }
    }

    public struct Line: Sendable, Equatable {
        public var cue: CaptionTranslation.Cue
        /// Det inlästa (kan skilja sig från undertextraden, t.ex. en AI-röstupplysning först).
        public var text: String
        public var file: String
        public var duration: Double
        public var placement: Placement
    }

    public enum DubError: LocalizedError {
        case noTranslation(String)
        case count(got: Int, lines: Int)
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .noTranslation(let l): String(localized: "Det finns inga undertexter på \(l) att dubba.")
            case .count(let got, let lines): String(localized: "Fick \(got) ljudfiler till \(lines) rader.")
            case .unreadable(let f): String(localized: "Ljudfilen går inte att läsa: \(f)")
            }
        }
    }

    /// Lägger in en dubbning: en fil per rad i översättningen `language` (tom sökväg = raden
    /// läses inte in). Filerna kopieras till `media/`, mäts, placeras och ersätter tidigare
    /// dubbning på samma språk. `show` = filmen får den rösten.
    public static func apply(to bundle: RecordingBundle, project: inout EditProject, duration: Double,
                             language: String, files: [String], texts: [String], show: Bool) async throws -> [Line] {
        guard let translation = bundle.readTranslation(language), !translation.cues.isEmpty else {
            throw DubError.noTranslation(language)
        }
        let cues = translation.cues
        guard files.count == cues.count else { throw DubError.count(got: files.count, lines: cues.count) }
        let map = TimeMap(segments: project.segments)
        try FileManager.default.createDirectory(at: bundle.mediaDir, withIntermediateDirectories: true)

        // Raderna som läses in och finns kvar i filmen.
        struct Item { var cue: CaptionTranslation.Cue; var start: Double; var text: String; var file: String; var duration: Double }
        var items: [Item] = []
        for (i, path) in files.enumerated() where !path.isEmpty {
            guard let start = map.output(at: cues[i].start) else { continue }
            let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let asset = AVURLAsset(url: source)
            guard let length = try? await asset.load(.duration).seconds, length > 0.05,
                  !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty else {
                throw DubError.unreadable(source.lastPathComponent)
            }
            let ext = source.pathExtension.isEmpty ? "mp3" : source.pathExtension.lowercased()
            let name = String(format: "dub-%@-%02d.%@", language, i + 1, ext)
            let target = bundle.mediaDir.appendingPathComponent(name)
            if source.standardizedFileURL != target.standardizedFileURL {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
            let text = i < texts.count && !texts[i].isEmpty ? texts[i] : cues[i].text
            items.append(Item(cue: cues[i], start: start, text: text, file: name, duration: length))
        }
        let placements = place(starts: items.map(\.start), durations: items.map(\.duration), end: map.outputDuration)
        project.audioClips.removeAll { $0.role == .dub && $0.language == language }
        var lines: [Line] = []
        for (item, p) in zip(items, placements) {
            project.audioClips.append(AudioClip(role: .dub, at: map.source(at: p.at), file: item.file, text: item.text,
                                                duration: item.duration, language: language, speed: p.speed))
            lines.append(Line(cue: item.cue, text: item.text, file: item.file, duration: item.duration, placement: p))
        }
        if show { project.audio.voice = language }
        return lines
    }
}
