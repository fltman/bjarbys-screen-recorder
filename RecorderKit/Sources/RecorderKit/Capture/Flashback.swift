import Foundation
import AVFoundation
import ScreenCaptureKit

/// Flashback: spela in hela tiden, spara de senaste minuterna i efterhand.
///
/// SDK:t för macOS 26.1 saknar `SCClipBufferingOutput` (kom i 27), så bufferten är byggd av
/// vanliga inspelningssessioner som avlöser varandra: en ny startas innan den gamla stoppas,
/// så att de överlappar. Varje del vet när dess tidslinje började i värdklockan
/// (`startHostTime`). När något sparas sys delarna ihop där nästa del fick sin första ruta —
/// bild, ljud och händelser — till ett vanligt `.bsrec`-paket.

/// Vilken del av vilken session som hamnar var i den sparade inspelningen. Ren beräkning.
public enum FlashbackPlan {
    public struct Segment: Equatable, Sendable {
        /// Tidslinjens nollpunkt i värdklockan och längden (s).
        public let start: Double
        public let duration: Double
        public init(start: Double, duration: Double) { self.start = start; self.duration = duration }
        public var end: Double { start + duration }
    }

    public struct Piece: Equatable, Sendable {
        public let segment: Int
        /// Intervallet i delens egen tid.
        public let localStart: Double
        public let localEnd: Double
        /// Var det börjar i den sparade inspelningen.
        public let output: Double
    }

    /// Bitarna som täcker värdklocktiden [from, to]. En del gäller fram till att nästa del
    /// börjar (de överlappar); efter sista delens slut finns inget.
    public static func pieces(_ segments: [Segment], from: Double, to: Double) -> [Piece] {
        let sorted = segments.enumerated().sorted { $0.element.start < $1.element.start }
        var out: [Piece] = []
        for (k, (index, seg)) in sorted.enumerated() {
            let handOver = k + 1 < sorted.count ? min(sorted[k + 1].element.start, seg.end) : seg.end
            let a = max(seg.start, from), b = min(handOver, to)
            guard b - a > 0.001 else { continue }
            out.append(Piece(segment: index, localStart: a - seg.start, localEnd: b - seg.start, output: a - from))
        }
        return out
    }
}

public enum FlashbackError: LocalizedError {
    case empty
    case exportFailed(String)
    public var errorDescription: String? {
        switch self {
        case .empty: String(localized: "Bufferten är tom ännu.")
        case .exportFailed(let s): String(localized: "Flashback gick inte att spara: \(s)")
        }
    }
}

/// Syr ihop delar till ett nytt paket.
public enum FlashbackAssembler {
    public static func assemble(_ segments: [RecordingBundle], from: Double, to: Double,
                                into directory: URL) async throws -> RecordingBundle {
        let metas = segments.compactMap { b in (try? b.readMeta()).map { (b, $0) } }
            .filter { $0.1.startHostTime > 0 && $0.1.duration > 0 }
        let spans = metas.map { FlashbackPlan.Segment(start: $0.1.startHostTime, duration: $0.1.duration) }
        var plan = FlashbackPlan.pieces(spans, from: from, to: to)
        // Utan omkodning börjar bilden först vid en nyckelruta (uppmätt: 1,4 s svart början).
        // Börjar första biten mitt i en del flyttas starten bakåt till närmaste nyckelruta.
        if let first = plan.first, first.localStart > 0.001 {
            let (segBundle, segMeta) = metas[first.segment]
            if let track = segMeta.track(.screen),
               let key = await keyframe(atOrBefore: first.localStart, in: segBundle.url(for: track)) {
                plan = FlashbackPlan.pieces(spans, from: from - (first.localStart - key), to: to)
            }
        }
        guard let lastPiece = plan.last, let reference = metas.last?.1 else { throw FlashbackError.empty }
        let firstStart = from + (plan.first?.output ?? 0)
        let duration = lastPiece.output + (lastPiece.localEnd - lastPiece.localStart) - (plan.first?.output ?? 0)

        let bundle = try RecordingBundle.create(in: directory)
        try FileManager.default.createDirectory(at: bundle.recordingDir, withIntermediateDirectories: true)
        var meta = RecordingMeta(source: reference.source, fps: reference.fps, appVersion: reference.appVersion)
        meta.startHostTime = firstStart
        meta.keystrokesRecorded = metas.contains { $0.1.keystrokesRecorded }
        meta.droppedFrames = metas.map(\.1.droppedFrames).reduce(0, +)

        // Ett spår i taget: delarnas bitar efter varandra, sedan rakt över till en fil.
        for kind in RecordingMeta.TrackKind.allCases {
            let composition = AVMutableComposition()
            guard let target = composition.addMutableTrack(withMediaType: kind == .screen || kind == .camera ? .video : .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var any = false
            var device = ""
            for piece in plan {
                let (segBundle, segMeta) = metas[piece.segment]
                guard let track = segMeta.track(kind), !track.failed else { continue }
                let asset = AVURLAsset(url: segBundle.url(for: track), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let source = try? await asset.loadTracks(withMediaType: target.mediaType).first,
                      let available = try? await source.load(.timeRange) else { continue }
                let range = CMTimeRange(start: CMTime(seconds: piece.localStart, preferredTimescale: 600),
                                        end: CMTime(seconds: piece.localEnd, preferredTimescale: 600))
                let clipped = range.intersection(available)
                guard clipped.duration > .zero else { continue }
                let at = CMTime(seconds: piece.output - (plan.first?.output ?? 0), preferredTimescale: 600)
                    + (clipped.start - range.start)
                try target.insertTimeRange(clipped, of: source, at: at)
                any = true
                device = track.deviceName
            }
            guard any else { continue }
            let file = "\(kind.rawValue)-0.mov"
            let url = bundle.recordingDir.appendingPathComponent(file)
            try await passthrough(composition, to: url)
            meta.tracks.append(.init(kind: kind, file: file, deviceName: device))
        }
        guard meta.track(.screen) != nil else { throw FlashbackError.exportFailed("ingen bild") }

        // Händelser och markörbilder.
        let log = try EventLogWriter(url: bundle.eventsURL)
        var catalog = CursorCatalog()
        let base = plan.first?.output ?? 0
        for piece in plan {
            let (segBundle, _) = metas[piece.segment]
            for e in segBundle.readEvents() where e.t >= piece.localStart && e.t < piece.localEnd {
                var moved = e
                moved.t = piece.output - base + (e.t - piece.localStart)
                log.append(moved)
            }
            for entry in segBundle.readCursors().entries where catalog.entry(entry.id) == nil {
                catalog.entries.append(entry)
                let src = segBundle.cursorsDir.appendingPathComponent("\(entry.id).png")
                try? FileManager.default.copyItem(at: src, to: bundle.cursorsDir.appendingPathComponent("\(entry.id).png"))
            }
        }
        log.close()
        try BundleJSON.write(catalog, to: bundle.cursorCatalogURL)

        meta.duration = duration
        meta.finished = true
        try bundle.writeMeta(meta)
        await CaptureSession.makeThumbnail(for: bundle, at: min(1, duration / 2))
        return bundle
    }

    /// Tiden för sista nyckelrutan på eller före `t` i en videofil.
    static func keyframe(atOrBefore t: Double, in url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return nil }
        var best: Double?
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if pts > t + 0.0005 { break }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            if !notSync { best = pts }
        }
        reader.cancelReading()
        return best
    }

    /// Kopierar kompositionen till en fil utan att koda om.
    static func passthrough(_ composition: AVComposition, to url: URL) async throws {
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw FlashbackError.exportFailed("ingen exportsession")
        }
        try? FileManager.default.removeItem(at: url)
        try await export.export(to: url, as: .mov)
    }
}

/// Bufferten i drift: delar som avlöser varandra, och sparandet.
@MainActor
public final class FlashbackRecorder {
    public let bufferSeconds: Double
    public let segmentSeconds: Double
    public let directory: URL
    private let makeTarget: () async throws -> CaptureTarget
    private let options: CaptureOptions
    private var current: CaptureSession?
    /// Färdiga delar, äldst först.
    private var finished: [RecordingBundle] = []
    private var rotation: Task<Void, Never>?
    private var busy = false
    public private(set) var isRunning = false
    public var onError: ((Error) -> Void)?

    /// - Parameter makeTarget: vad som spelas in; frågas vid varje ny del (skärmen kan ha bytts).
    public init(bufferSeconds: Double, segmentSeconds: Double = 60, directory: URL, options: CaptureOptions,
                makeTarget: @escaping () async throws -> CaptureTarget) {
        self.bufferSeconds = bufferSeconds
        self.segmentSeconds = segmentSeconds
        self.directory = directory
        self.options = options
        self.makeTarget = makeTarget
    }

    public func start() async throws {
        guard !isRunning else { return }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        current = try await newSession()
        isRunning = true
        rotation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.segmentSeconds ?? 60))
                guard let self, !Task.isCancelled else { return }
                await self.rotate()
            }
        }
    }

    public func stop() async {
        rotation?.cancel()
        rotation = nil
        isRunning = false
        if let c = current { _ = await c.stop() }
        current = nil
        finished = []
        try? FileManager.default.removeItem(at: directory)
    }

    /// Sparar de senaste `seconds` sekunderna som en vanlig inspelning i `library`.
    public func save(last seconds: Double, into library: URL) async throws -> RecordingBundle {
        // Avsluta pågående del (en ny tar vid) så att allt fram till nu finns i färdiga filer.
        await rotate()
        let now = RecordingClock.hostNow().seconds
        return try await FlashbackAssembler.assemble(finished, from: now - min(seconds, bufferSeconds), to: now,
                                                     into: library)
    }

    private func newSession() async throws -> CaptureSession {
        let session = try CaptureSession(target: try await makeTarget(), options: options, directory: directory)
        try await session.start()
        return session
    }

    /// Ny del in, gammal ut. Den nya måste ha fått sin första ruta innan den gamla stoppas,
    /// annars blir det ett hål.
    private func rotate() async {
        guard isRunning, !busy, let old = current else { return }
        busy = true
        defer { busy = false }
        do {
            let next = try await newSession()
            let deadline = Date().addingTimeInterval(2)
            while !next.hasStarted && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            current = next
        } catch {
            onError?(error)
            // Utan ny del fortsätter den gamla; försök igen vid nästa varv.
            return
        }
        _ = await old.stop()
        finished.append(old.bundle)
        prune()
    }

    /// Delar som slutade före buffertens början tas bort.
    private func prune() {
        let horizon = RecordingClock.hostNow().seconds - bufferSeconds - segmentSeconds
        finished.removeAll { b in
            guard let m = try? b.readMeta(), m.startHostTime > 0, m.startHostTime + m.duration < horizon else { return false }
            try? FileManager.default.removeItem(at: b.url)
            return true
        }
    }

    /// Antal färdiga delar (för prov och status).
    public var segmentCount: Int { finished.count }
}
