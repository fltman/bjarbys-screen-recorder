import Foundation
import AVFoundation

/// Slår ihop inspelningar (tagningar) till en ny, efter varandra: varje spår kopieras rakt över
/// (ingen omkodning), händelser och markörbilder följer med flyttade i tid, och transkripten
/// slås ihop när alla har ett. Originalen rörs inte.
public enum RecordingMerger {
    public enum MergeError: LocalizedError {
        case tooFew
        case unreadable(String)
        case sizeMismatch(String)
        case mixedHDR
        case exportFailed(String)
        public var errorDescription: String? {
            switch self {
            case .tooFew: String(localized: "Välj minst två inspelningar.")
            case .unreadable(let n): String(localized: "\(n) går inte att läsa.")
            case .sizeMismatch(let s): String(localized: "Inspelningarna har olika upplösning (\(s)) och kan inte slås ihop utan omkodning.")
            case .mixedHDR: String(localized: "Inspelningar i HDR och SDR kan inte slås ihop.")
            case .exportFailed(let s): String(localized: "Ihopslagningen misslyckades: \(s)")
            }
        }
    }

    /// Slår ihop `bundles` i den givna ordningen till ett nytt paket i `directory`.
    public static func merge(_ bundles: [RecordingBundle], into directory: URL) async throws -> RecordingBundle {
        guard bundles.count >= 2 else { throw MergeError.tooFew }
        var metas: [(RecordingBundle, RecordingMeta)] = []
        for b in bundles {
            guard let m = try? b.readMeta(), m.duration > 0 else { throw MergeError.unreadable(b.name) }
            metas.append((b, m))
        }
        let first = metas[0].1
        let sizes = Set(metas.map { "\($0.1.source.pixelWidth)×\($0.1.source.pixelHeight)" })
        guard sizes.count == 1 else { throw MergeError.sizeMismatch(sizes.sorted().joined(separator: ", ")) }
        guard Set(metas.map(\.1.hdr)).count == 1 else { throw MergeError.mixedHDR }

        // Var varje tagning börjar i den nya inspelningen.
        var offsets: [Double] = []
        var total = 0.0
        for (_, m) in metas { offsets.append(total); total += m.duration }

        let bundle = try RecordingBundle.create(in: directory)
        try FileManager.default.createDirectory(at: bundle.recordingDir, withIntermediateDirectories: true)
        var meta = RecordingMeta(source: first.source, fps: metas.map(\.1.fps).max() ?? first.fps, appVersion: first.appVersion)
        meta.hdr = first.hdr
        meta.keystrokesRecorded = metas.contains { $0.1.keystrokesRecorded }

        // Spåren: skärm, kamera, mikrofon, datorljud — och apparnas, per app.
        var kinds: [(kind: RecordingMeta.TrackKind, appID: String, name: String)] =
            [(.screen, "", ""), (.camera, "", ""), (.microphone, "", ""), (.system, "", "")]
        var seenApps: [String] = []
        for (_, m) in metas { for t in m.appTracks where !seenApps.contains(t.appID) { seenApps.append(t.appID); kinds.append((.app, t.appID, t.deviceName)) } }
        var appIndex = 0
        for k in kinds {
            let composition = AVMutableComposition()
            let media: AVMediaType = k.kind == .screen || k.kind == .camera ? .video : .audio
            guard let target = composition.addMutableTrack(withMediaType: media, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var end = CMTime.zero
            var any = false
            var device = ""
            var startOfTrack: Double?
            for (i, (b, m)) in metas.enumerated() {
                let track = k.kind == .app ? m.appTracks.first { $0.appID == k.appID } : m.track(k.kind)
                guard let track else { continue }
                let asset = AVURLAsset(url: b.url(for: track), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let source = try? await asset.loadTracks(withMediaType: media).first,
                      let range = try? await source.load(.timeRange), range.duration > .zero else { continue }
                let at = CMTime(seconds: offsets[i], preferredTimescale: 600) + range.start
                // Luckan före (ett spår som saknas i en tagning, eller börjar senare) uttryckligen.
                if at > end { target.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
                let length = CMTimeMinimum(range.duration, CMTime(seconds: offsets[i] + m.duration, preferredTimescale: 600) - at)
                guard length > .zero else { continue }
                do { try target.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: source, at: CMTimeMaximum(at, end)) }
                catch { throw MergeError.exportFailed(error.localizedDescription) }
                end = CMTimeMaximum(at, end) + length
                if startOfTrack == nil { startOfTrack = at.seconds }
                any = true
                device = track.deviceName
            }
            guard any else { continue }
            let file: String
            if k.kind == .app { file = RecordingBundle.appFileName(appIndex); appIndex += 1 }
            else { file = RecordingBundle.fileName(for: k.kind) }
            try await passthrough(composition, to: bundle.recordingDir.appendingPathComponent(file))
            var t = RecordingMeta.Track(kind: k.kind, file: file, deviceName: k.kind == .app ? k.name : device, appID: k.appID)
            t.start = startOfTrack ?? 0
            meta.tracks.append(t)
        }
        guard meta.track(.screen) != nil else { throw MergeError.exportFailed(String(localized: "inget skärmspår")) }

        // Händelserna flyttade i tid; punkterna flyttade om en tagning låg på ett annat ställe.
        let log = try EventLogWriter(url: bundle.eventsURL)
        var catalog = CursorCatalog()
        for (i, (b, m)) in metas.enumerated() {
            let dx = first.source.contentRect.x - m.source.contentRect.x
            let dy = first.source.contentRect.y - m.source.contentRect.y
            // Varje tagning börjar med sin egen ram, annars gäller förra tagningens sista
            // fönsterflytt in i nästa (fönsterinspelning: markören räknas mot ramen).
            if i > 0 {
                let r = m.source.contentRect
                log.append(InputEvent(t: offsets[i], k: .frame, rect: Rect(x: r.x + dx, y: r.y + dy, width: r.width, height: r.height)))
            }
            for e in b.readEvents() where e.t < m.duration {
                var moved = e
                moved.t = offsets[i] + e.t
                if let x = e.x { moved.x = x + dx }
                if let y = e.y { moved.y = y + dy }
                if var r = e.rect { r.x += dx; r.y += dy; moved.rect = r }
                if var pts = e.pts {
                    for j in stride(from: 0, to: pts.count - 2, by: 3) { pts[j + 1] += dx; pts[j + 2] += dy }
                    moved.pts = pts
                }
                log.append(moved)
            }
            for entry in b.readCursors().entries where catalog.entry(entry.id) == nil {
                catalog.entries.append(entry)
                try? FileManager.default.copyItem(at: b.cursorsDir.appendingPathComponent("\(entry.id).png"),
                                                  to: bundle.cursorsDir.appendingPathComponent("\(entry.id).png"))
            }
        }
        log.close()
        try BundleJSON.write(catalog, to: bundle.cursorCatalogURL)

        // Transkripten, om alla har ett.
        let transcripts = metas.map { $0.0.readTranscript() }
        if transcripts.allSatisfy({ $0 != nil }), let t0 = transcripts.first ?? nil {
            var words: [Transcript.Word] = []
            for (i, t) in transcripts.enumerated() {
                for (j, w) in (t?.words ?? []).enumerated() {
                    var moved = w
                    moved.start += offsets[i]; moved.end += offsets[i]
                    // En ny tagning börjar en ny rad i undertexterna.
                    if j == 0 { moved.startsSegment = true }
                    words.append(moved)
                }
            }
            try? bundle.saveTranscript(Transcript(model: t0.model, language: t0.language, track: t0.track, words: words))
        }

        meta.duration = total
        meta.finished = true
        try bundle.writeMeta(meta)
        await CaptureSession.makeThumbnail(for: bundle, at: min(1, total / 2))
        return bundle
    }

    static func passthrough(_ composition: AVComposition, to url: URL) async throws {
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MergeError.exportFailed(String(localized: "ingen exportsession"))
        }
        try? FileManager.default.removeItem(at: url)
        do { try await export.export(to: url, as: .mov) }
        catch { throw MergeError.exportFailed(error.localizedDescription) }
    }
}
