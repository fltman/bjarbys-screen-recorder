import Foundation
import AVFoundation

/// En inläst inspelning: rådata och spår, redo att byggas till en komposition.
public struct LoadedRecording: @unchecked Sendable {
    public let bundle: RecordingBundle
    public let meta: RecordingMeta
    public let events: [InputEvent]
    public let cursors: CursorCatalog
    public let mapping: ContentMapping
    /// Vad som sades, om inspelningen är transkriberad.
    public var transcript: Transcript?
    /// Mikrofonen efter röstisolering, om den är gjord.
    public var isolatedMicrophone: AVURLAsset?
    let assets: [RecordingMeta.TrackKind: AVURLAsset]
    /// Apparna med eget ljudspår, i inspelningens ordning.
    public let apps: [AppAudio]

    public struct AppAudio: @unchecked Sendable {
        public let id: String
        public let name: String
        public let asset: AVURLAsset
    }

    public static func load(_ bundle: RecordingBundle) throws -> LoadedRecording {
        let meta = try bundle.readMeta()
        let events = bundle.readEvents()
        var assets: [RecordingMeta.TrackKind: AVURLAsset] = [:]
        var apps: [AppAudio] = []
        for track in meta.appTracks where FileManager.default.fileExists(atPath: bundle.url(for: track).path) {
            apps.append(AppAudio(id: track.appID, name: track.deviceName,
                                 asset: AVURLAsset(url: bundle.url(for: track), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])))
        }
        for track in meta.tracks where !track.failed && track.kind != .app {
            let url = bundle.url(for: track)
            if FileManager.default.fileExists(atPath: url.path) {
                assets[track.kind] = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            }
        }
        return LoadedRecording(bundle: bundle, meta: meta, events: events, cursors: bundle.readCursors(),
                               mapping: ContentMapping(meta: meta, events: events),
                               transcript: bundle.readTranscript(),
                               isolatedMicrophone: FileManager.default.fileExists(atPath: bundle.isolatedMicrophoneURL.path)
                                   ? AVURLAsset(url: bundle.isolatedMicrophoneURL) : nil,
                               assets: assets, apps: apps)
    }

    public var hasCamera: Bool { assets[.camera] != nil }
    public var hasMicrophone: Bool { assets[.microphone] != nil }
    public var hasSystemAudio: Bool { assets[.system] != nil }
    /// Datorljud av något slag: allt i ett spår, eller apparna var för sig.
    public var hasComputerAudio: Bool { hasSystemAudio || !apps.isEmpty }
    public func asset(_ kind: RecordingMeta.TrackKind) -> AVURLAsset? { assets[kind] }

    public var sourceSize: CGSize {
        CGSize(width: meta.source.pixelWidth, height: meta.source.pixelHeight)
    }

    /// `hdr`: rita i HDR (HLG). Gäller bara en HDR-inspelning; annars blir det SDR.
    public func makePlan(project: EditProject, canvas: CGSize, transparentBackground: Bool = false,
                         cursorPath: CursorPath? = nil, cameraPath: CameraPath? = nil, hdr: Bool = false) -> RenderPlan {
        RenderPlan(canvas: canvas, project: project, meta: meta, events: events, cursors: cursors,
                   cursorsDir: bundle.cursorsDir, hasCamera: hasCamera, words: transcript?.words ?? [],
                   transparentBackground: transparentBackground, mediaDir: bundle.mediaDir,
                   cursorPath: cursorPath, cameraPath: cameraPath, outputHDR: hdr && meta.hdr)
    }

    public var isHDR: Bool { meta.hdr }
}

/// Gör ett redigeringsläge till något AVFoundation kan spela och exportera: en komposition med
/// klippen och hastigheterna, en videokomposition med `PolishCompositor` och en ljudmix.
public enum CompositionBuilder {
    public struct Result: @unchecked Sendable {
        public let composition: AVMutableComposition
        public let videoComposition: AVVideoComposition
        public let audioMix: AVMutableAudioMix
        public let duration: CMTime
        public let plan: RenderPlan
    }

    public static func build(_ rec: LoadedRecording, plan: RenderPlan, fps: Int) async throws -> Result {
        let composition = AVMutableComposition()
        let timescale: CMTimeScale = 600

        func sourceTrack(_ kind: RecordingMeta.TrackKind, _ type: AVMediaType) async -> AVAssetTrack? {
            // Röstisolerad mikrofon om den är vald och gjord; den har samma tidslinje som originalet.
            let isolated = kind == .microphone && plan.project.audio.voiceIsolation ? rec.isolatedMicrophone : nil
            guard let asset = isolated ?? rec.asset(kind) else { return nil }
            return try? await asset.loadTracks(withMediaType: type).first
        }
        guard let screenSource = await sourceTrack(.screen, .video),
              let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: screenTrackID) else {
            throw NSError(domain: "CompositionBuilder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Skärmspåret saknas eller går inte att läsa"])
        }
        var pairs: [(AVAssetTrack, AVMutableCompositionTrack, CMTimeRange)] = []
        pairs.append((screenSource, screenTrack, try await screenSource.load(.timeRange)))

        var hasCamera = false
        if let cam = await sourceTrack(.camera, .video),
           let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: cameraTrackID) {
            pairs.append((cam, track, try await cam.load(.timeRange)))
            hasCamera = true
        }
        // Ljudet från inspelningen: mikrofon, datorljud och apparnas egna spår, med B-spårens id
        // för övertoningarna.
        var recorded: [(source: AVAssetTrack, main: CMPersistentTrackID, alternate: CMPersistentTrackID)] = []
        for (kind, id, alt) in [(RecordingMeta.TrackKind.microphone, microphoneTrackID, alternateMicTrackID),
                                (.system, systemTrackID, alternateSystemTrackID)] {
            if let src = await sourceTrack(kind, .audio) { recorded.append((src, id, alt)) }
        }
        for (i, app) in rec.apps.enumerated() {
            if let src = try? await app.asset.loadTracks(withMediaType: .audio).first {
                recorded.append((src, appTrackBase + CMPersistentTrackID(i), alternateAppTrackBase + CMPersistentTrackID(i)))
            }
        }
        for r in recorded {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: r.main) else { continue }
            pairs.append((r.source, track, try await r.source.load(.timeRange)))
        }

        // Delarna läggs efter varandra. Ett spår som börjar senare eller slutar tidigare än
        // delen (mikrofonen startar ~0,5 s in) läggs in där det finns, på rätt plats.
        var cursor = CMTime.zero
        for segment in plan.project.segments where segment.duration > 0.001 {
            let start = CMTime(seconds: segment.start, preferredTimescale: timescale)
            let end = CMTime(seconds: segment.end, preferredTimescale: timescale)
            let range = CMTimeRange(start: start, end: end)
            for (source, target, available) in pairs {
                let clipped = range.intersection(available)
                guard clipped.duration > .zero else { continue }
                try target.insertTimeRange(clipped, of: source, at: cursor + (clipped.start - start))
            }
            let length = end - start
            if abs(segment.speed - 1) > 0.001 {
                let scaled = CMTime(seconds: length.seconds / segment.speed, preferredTimescale: timescale)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: length), toDuration: scaled)
                cursor = cursor + scaled
            } else {
                cursor = cursor + length
            }
        }

        // Extra ljud (berättarröst, musik, effekter) på sina utdatatider, i normal hastighet.
        for (i, clip) in plan.project.audioClips.enumerated() {
            guard let at = plan.timeMap.output(at: clip.at), at < cursor.seconds else { continue }
            let asset = AVURLAsset(url: rec.bundle.mediaDir.appendingPathComponent(clip.file))
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange),
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: audioClipTrackBase + CMPersistentTrackID(i)) else { continue }
            let start = CMTime(seconds: at, preferredTimescale: timescale)
            let room = cursor - start
            let length = CMTimeMinimum(range.duration, room)
            try? track.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: source, at: start)
        }

        // Klickljud: samma korta klick vid varje musklick som finns kvar i filmen, på ett eget spår.
        // Tillgången hålls i en egen variabel: släpps den medan spåret läggs in misslyckas
        // insättningen (−11800/−12780, uppmätt).
        let clickAsset = ClickSound.url().map { AVURLAsset(url: $0) }
        if plan.project.cursor.clickSound, plan.project.cursor.clickVolume > 0, let clickAsset,
           let click = try? await clickAsset.loadTracks(withMediaType: .audio).first,
           let clickRange = try? await click.load(.timeRange),
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: clickTrackID) {
            let times = plan.cursorPath.clicks.compactMap { plan.timeMap.output(at: $0.t) }.sorted()
            var free = 0.0
            var trackEnd = CMTime.zero
            for (n, at) in times.enumerated() where at >= free && at < cursor.seconds {
                let next = n + 1 < times.count ? times[n + 1] : cursor.seconds
                let length = min(clickRange.duration.seconds, next - at, cursor.seconds - at)
                guard length > 0.005 else { continue }
                let start = CMTime(seconds: at, preferredTimescale: 48_000)
                // Luckan före klicket uttryckligen (spårets längd är ogiltig så länge det är tomt).
                if start > trackEnd { track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: start)) }
                do {
                    try track.insertTimeRange(CMTimeRange(start: clickRange.start, duration: CMTime(seconds: length, preferredTimescale: 48_000)),
                                              of: click, at: start)
                    trackEnd = start + CMTime(seconds: length, preferredTimescale: 48_000)
                } catch { continue }
                free = at + length
            }
            if track.segments.isEmpty { composition.removeTrack(track) }
        }

        // Övertoningar: skärmspår B med nästa dels förrulle före snittet och förra delens
        // efterrulle efter, i delarnas hastighet. Filmens tidslinje ändras inte.
        var hasAlternate = false
        let fades = plan.cutPlan.cuts.filter { $0.transition.kind == .crossfade }
        if !fades.isEmpty, let alt = composition.addMutableTrack(withMediaType: .video, preferredTrackID: alternateScreenTrackID) {
            let available = try await screenSource.load(.timeRange)
            // Spårets slut hålls här: ett tomt kompositionsspår har en ogiltig tidslängd (NaN),
            // och då blir varje jämförelse falsk och ingenting läggs in.
            var altEnd = CMTime.zero
            func place(source a: Double, _ b: Double, speed: Double, at out: Double) {
                let s0 = max(a, available.start.seconds), s1 = min(b, available.end.seconds)
                guard s1 - s0 > 0.01 else { return }
                let at = CMTimeMaximum(CMTime(seconds: out + (s0 - a) / speed, preferredTimescale: timescale), altEnd)
                if altEnd < at { alt.insertEmptyTimeRange(CMTimeRange(start: altEnd, end: at)) }
                let range = CMTimeRange(start: CMTime(seconds: s0, preferredTimescale: timescale),
                                        end: CMTime(seconds: s1, preferredTimescale: timescale))
                do { try alt.insertTimeRange(range, of: screenSource, at: at) } catch { return }
                var length = range.duration
                if abs(speed - 1) > 0.001 {
                    length = CMTime(seconds: range.duration.seconds / speed, preferredTimescale: timescale)
                    alt.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: length)
                }
                altEnd = at + length
                hasAlternate = true
            }
            for cut in fades.sorted(by: { $0.output < $1.output }) {
                let half = max(0.05, cut.transition.duration / 2)
                place(source: cut.after.sourceStart - half * cut.after.speed, cut.after.sourceStart,
                      speed: cut.after.speed, at: cut.output - half)
                place(source: cut.before.sourceEnd, cut.before.sourceEnd + half * cut.before.speed,
                      speed: cut.before.speed, at: cut.output)
            }
            if !hasAlternate { composition.removeTrack(alt) }

            // Samma förrulle och efterrulle för mikrofonen och datorljudet, så att ljudet tonas
            // över i stället för att klippas.
            for r in recorded {
                let src = r.source
                guard let range = try? await src.load(.timeRange),
                      let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: r.alternate) else { continue }
                var end = CMTime.zero
                var any = false
                func put(_ a: Double, _ b: Double, speed: Double, at out: Double) {
                    let s0 = max(a, range.start.seconds), s1 = min(b, range.end.seconds)
                    guard s1 - s0 > 0.01 else { return }
                    let at = CMTimeMaximum(CMTime(seconds: out + (s0 - a) / speed, preferredTimescale: timescale), end)
                    if end < at { track.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
                    let r = CMTimeRange(start: CMTime(seconds: s0, preferredTimescale: timescale), end: CMTime(seconds: s1, preferredTimescale: timescale))
                    do { try track.insertTimeRange(r, of: src, at: at) } catch { return }
                    var length = r.duration
                    if abs(speed - 1) > 0.001 {
                        length = CMTime(seconds: r.duration.seconds / speed, preferredTimescale: timescale)
                        track.scaleTimeRange(CMTimeRange(start: at, duration: r.duration), toDuration: length)
                    }
                    end = at + length
                    any = true
                }
                for cut in fades.sorted(by: { $0.output < $1.output }) {
                    let half = max(0.05, cut.transition.duration / 2)
                    put(cut.after.sourceStart - half * cut.after.speed, cut.after.sourceStart, speed: cut.after.speed, at: cut.output - half)
                    put(cut.before.sourceEnd, cut.before.sourceEnd + half * cut.before.speed, speed: cut.before.speed, at: cut.output)
                }
                if !any { composition.removeTrack(track) }
            }
        }

        // Videoinslag: eget videospår (och ljud) per lager, i normal hastighet från sin startpunkt.
        let videos = plan.project.overlays.filter { $0.kind == .video }
        for (i, o) in videos.enumerated() {
            guard let at = plan.timeMap.output(at: o.at), at < cursor.seconds else { continue }
            let asset = AVURLAsset(url: rec.bundle.mediaDir.appendingPathComponent(o.file))
            guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                  let available = try? await source.load(.timeRange),
                  let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: videoOverlayTrackBase + CMPersistentTrackID(i)) else { continue }
            let start = CMTime(seconds: at, preferredTimescale: timescale)
            let from = available.start + CMTime(seconds: max(0, o.offset), preferredTimescale: timescale)
            // I filmen `duration` s (högst till filmens slut); ur filen `duration × speed` s.
            let speed = max(0.25, min(4, o.speed))
            let wanted = min(o.duration, (cursor - start).seconds) * speed
            let length = CMTimeMinimum(CMTime(seconds: wanted, preferredTimescale: timescale), available.end - from)
            guard length > .zero else { continue }
            let range = CMTimeRange(start: from, duration: length)
            let shown = CMTime(seconds: length.seconds / speed, preferredTimescale: timescale)
            try? track.insertTimeRange(range, of: source, at: start)
            if abs(speed - 1) > 0.001 { track.scaleTimeRange(CMTimeRange(start: start, duration: length), toDuration: shown) }
            if o.volume > 0, let sound = try? await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: videoAudioTrackBase + CMPersistentTrackID(i)) {
                try? audioTrack.insertTimeRange(range, of: sound, at: start)
                if abs(speed - 1) > 0.001 { audioTrack.scaleTimeRange(CMTimeRange(start: start, duration: length), toDuration: shown) }
            }
        }

        let video = videoComposition(plan: plan, duration: cursor, fps: fps, hasCamera: hasCamera, hasAlternate: hasAlternate)
        let mix = audioMix(for: composition, plan: plan, appIDs: rec.apps.map(\.id))
        return Result(composition: composition, videoComposition: video, audioMix: mix, duration: cursor, plan: plan)
    }

    /// Spår-id:n i kompositionen är fasta, så utseendet kan bytas utan att klippen byggs om.
    static let screenTrackID: CMPersistentTrackID = 1
    static let cameraTrackID: CMPersistentTrackID = 2
    static let microphoneTrackID: CMPersistentTrackID = 3
    static let systemTrackID: CMPersistentTrackID = 4
    /// Skärmspår B för övertoningar, och mikrofonens och datorljudets B-spår.
    static let alternateScreenTrackID: CMPersistentTrackID = 6
    static let alternateMicTrackID: CMPersistentTrackID = 7
    static let alternateSystemTrackID: CMPersistentTrackID = 8
    /// Ljudklipp får id 100, 101 … i projektets ordning, så att mixen hittar dem igen.
    static let audioClipTrackBase: CMPersistentTrackID = 100
    /// Videoinslag: bild 200, 201 …, ljud 300, 301 … i videolagrens ordning.
    static let videoOverlayTrackBase: CMPersistentTrackID = 200
    static let videoAudioTrackBase: CMPersistentTrackID = 300
    /// Apparnas egna ljudspår 400, 401 … och deras B-spår 500, 501 … i inspelningens ordning.
    static let appTrackBase: CMPersistentTrackID = 400
    static let alternateAppTrackBase: CMPersistentTrackID = 500
    /// Klickljuden.
    static let clickTrackID: CMPersistentTrackID = 600

    public static func videoComposition(plan: RenderPlan, duration: CMTime, fps: Int, hasCamera: Bool,
                                        hasAlternate: Bool = false) -> AVVideoComposition {
        let instruction = PolishInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), plan: plan,
                                            screenTrackID: screenTrackID, cameraTrackID: hasCamera ? cameraTrackID : nil,
                                            mediaTrackIDs: plan.videoOverlayIDs.indices.map { videoOverlayTrackBase + CMPersistentTrackID($0) },
                                            alternateTrackID: hasAlternate ? alternateScreenTrackID : nil)
        // HDR-inspelning: kompositören tar emot rutorna oförändrade (10 bit PQ) och ritar HLG eller
        // SDR. ⚠️ Kompositionen får då inga färgegenskaper: med dem gör AVFoundation om varje
        // källruta till den färgrymden först (uppmätt: x420 märkt HLG respektive BT.709 trots
        // `supportsHDRSourceFrames`), med sin egen nivå för SDR-vitt (uppmätt till SDR: vitt 197,
        // grått 109 i stället för 255 och 124). Utdata märks i kompositören.
        // Annars som förr — då gör AVFoundation om HDR-videoinslag till SDR åt oss.
        let compositor: PolishCompositor.Type = plan.outputHDR ? PolishHDRCompositor.self
            : (plan.sourceHDR ? PolishHDRToSDRCompositor.self : PolishCompositor.self)
        let sdr = !plan.sourceHDR
        return AVVideoComposition(configuration: .init(
            colorPrimaries: sdr ? AVVideoColorPrimaries_ITU_R_709_2 : nil,
            colorTransferFunction: sdr ? AVVideoTransferFunction_ITU_R_709_2 : nil,
            colorYCbCrMatrix: sdr ? AVVideoYCbCrMatrix_ITU_R_709_2 : nil,
            customVideoCompositorClass: compositor,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            instructions: [instruction],
            renderSize: plan.canvas))
    }

    /// Ljudmixen: volym och tystning per spår, datorljudet under tal (om valt), mikrofon och
    /// datorljud under berättarröst, musik under tal och berättarröst, och klippens toningar.
    /// `edges`: ett utsnitt som exporteras för sig; ljudet tonas in och ut på 20 ms i dess kanter.
    public static func audioMix(for composition: AVComposition, plan: RenderPlan, appIDs: [String] = [],
                                edges: ClosedRange<Double>? = nil) -> AVMutableAudioMix {
        let mix = plan.project.audio
        let map = plan.timeMap
        // Berättarrösten i utdatatid.
        let narration: [ClosedRange<Double>] = plan.project.audioClips.filter { $0.role == .narration }.compactMap { c in
            map.output(at: c.at).map { $0...($0 + c.duration) }
        }
        var params: [AVMutableAudioMixInputParameters] = []
        func time(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 600) }
        let edgePart = edges.map { r in
            GainEnvelope.Part([(r.lowerBound, 0), (r.lowerBound + 0.02, 1), (r.upperBound - 0.02, 1), (r.upperBound, 0)])
        }
        func apply(_ p: AVMutableAudioMixInputParameters, _ base: GainEnvelope) {
            var envelope = base
            if let edgePart { envelope.parts.append(edgePart) }
            let ramps = envelope.ramps()
            if ramps.first.map({ $0.start > 0.001 }) ?? true { p.setVolume(Float(envelope.value(at: 0)), at: .zero) }
            for r in ramps {
                p.setVolumeRamp(fromStartVolume: Float(r.from), toEndVolume: Float(r.to),
                                timeRange: CMTimeRange(start: time(r.start), end: time(r.end)))
            }
        }
        let cutOutputs = map.pieces.dropFirst().map(\.outputStart)
        let cutPart = GainEnvelope.cuts(plan.cutPlan.cuts, allOutputs: cutOutputs)
        for track in composition.tracks(withMediaType: .audio) {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral
            switch track.trackID {
            case microphoneTrackID, systemTrackID, alternateMicTrackID, alternateSystemTrackID:
                let isMic = track.trackID == microphoneTrackID || track.trackID == alternateMicTrackID
                let volume = isMic ? (mix.microphoneMuted ? 0 : mix.microphoneVolume) : (mix.systemMuted ? 0 : mix.systemVolume)
                var under = narration
                if !isMic && mix.duckSystem { under += plan.speech }
                var parts = [GainEnvelope.duck(under: under, factor: mix.duckLevel)]
                let isAlternate = track.trackID == alternateMicTrackID || track.trackID == alternateSystemTrackID
                parts.append(isAlternate ? GainEnvelope.alternate(plan.cutPlan.cuts) : cutPart)
                apply(p, GainEnvelope(base: volume, parts: parts))
            case clickTrackID:
                apply(p, GainEnvelope(base: plan.project.cursor.clickVolume))
            case appTrackBase..<(alternateAppTrackBase + 100):
                // En app: som datorljudet (sänks under berättarröst, och under tal om valt).
                let isAlternate = track.trackID >= alternateAppTrackBase
                let index = Int(track.trackID - (isAlternate ? alternateAppTrackBase : appTrackBase))
                let id = appIDs.indices.contains(index) ? appIDs[index] : ""
                let volume = mix.isAppMuted(id) ? 0 : mix.appVolume(id)
                var under = narration
                if mix.duckSystem { under += plan.speech }
                apply(p, GainEnvelope(base: volume, parts: [GainEnvelope.duck(under: under, factor: mix.duckLevel),
                                                            isAlternate ? GainEnvelope.alternate(plan.cutPlan.cuts) : cutPart]))
            case videoAudioTrackBase...:
                let index = Int(track.trackID - videoAudioTrackBase)
                let videos = plan.project.overlays.filter { $0.kind == .video }
                apply(p, GainEnvelope(base: videos.indices.contains(index) ? videos[index].volume : 0))
            default:
                let index = Int(track.trackID - audioClipTrackBase)
                guard plan.project.audioClips.indices.contains(index),
                      let at = map.output(at: plan.project.audioClips[index].at) else { apply(p, GainEnvelope(base: 0)); break }
                let clip = plan.project.audioClips[index]
                let end = at + clip.duration
                var parts: [GainEnvelope.Part] = []
                if clip.fadeIn > 0.01 { parts.append(.init([(at, 0), (at + clip.fadeIn, 1)])) }
                if clip.fadeOut > 0.01 { parts.append(.init([(end - clip.fadeOut, 1), (end, 0)])) }
                // Musiken sänks under tal och berättarröst.
                if clip.role == .music { parts.append(GainEnvelope.duck(under: plan.speech + narration, factor: 0.3)) }
                apply(p, GainEnvelope(base: clip.volume, parts: parts))
            }
            params.append(p)
        }
        let m = AVMutableAudioMix()
        m.inputParameters = params
        return m
    }
}

/// Datorljudet sänks mjukt strax före talet och höjs igen en stund efter. Pauser kortare än
/// en sekund behåller sänkningen, så att ljudet inte pumpar mellan meningarna.
public enum Ducking {
    public struct Ramp: Equatable, Sendable {
        public let start: Double, end: Double, from: Double, to: Double
    }
    static let down = 0.25, up = 0.5, hold = 1.0

    public static func ramps(speech: [ClosedRange<Double>], level: Double, normal: Double) -> [Ramp] {
        var merged: [ClosedRange<Double>] = []
        for r in speech.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound - last.upperBound < hold + down + up {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        var out: [Ramp] = []
        for r in merged {
            let a = max(0, r.lowerBound - down)
            out.append(Ramp(start: a, end: max(a + 0.01, r.lowerBound), from: normal, to: level))
            out.append(Ramp(start: r.upperBound, end: r.upperBound + up, from: level, to: normal))
        }
        return out
    }
}

/// En volymkurva: styckvis linjär, ihopmultiplicerad av flera delar (grundvolym, sänkning
/// under tal, toningar i snitten, klippens in- och uttoning). Blir till rampar som ligger
/// kant i kant — AVAudioMix tål inte rampar som överlappar, och att lägga dem ovanpå varandra
/// gick inte när flera saker ska hända samtidigt.
public struct GainEnvelope: Sendable {
    /// En del av kurvan: nycklar (tid, faktor), linjärt emellan, konstant utanför.
    public struct Part: Sendable {
        public var keys: [(t: Double, v: Double)]
        public init(_ keys: [(t: Double, v: Double)]) { self.keys = keys.sorted { $0.t < $1.t } }

        public func value(at t: Double) -> Double {
            guard let first = keys.first else { return 1 }
            if t <= first.t { return first.v }
            for (a, b) in zip(keys, keys.dropFirst()) where t <= b.t {
                return b.t - a.t < 1e-9 ? b.v : a.v + (b.v - a.v) * (t - a.t) / (b.t - a.t)
            }
            return keys.last!.v
        }
    }

    public var base: Double
    public var parts: [Part]

    public init(base: Double, parts: [Part] = []) { self.base = base; self.parts = parts }

    public func value(at t: Double) -> Double { parts.reduce(base) { $0 * $1.value(at: t) } }

    /// Rampar kant i kant mellan alla brytpunkter där kurvan ändras.
    public func ramps() -> [Ducking.Ramp] {
        let times = Set(parts.flatMap { $0.keys.map { max(0, $0.t) } }).sorted()
        var out: [Ducking.Ramp] = []
        for (a, b) in zip(times, times.dropFirst()) where b - a > 1e-6 {
            let va = value(at: a + 1e-7), vb = value(at: b - 1e-7)
            if abs(va - vb) > 1e-4 || abs(va - value(at: a - 1e-7)) > 1e-4 {
                out.append(.init(start: a, end: b, from: va, to: vb))
            }
        }
        return out
    }

    /// Sänkning under tal: ner strax före, upp en stund efter (samma form som `Ducking`).
    public static func duck(under ranges: [ClosedRange<Double>], factor: Double) -> Part {
        let ramps = Ducking.ramps(speech: ranges, level: factor, normal: 1)
        var keys: [(t: Double, v: Double)] = []
        for r in ramps { keys.append((r.start, r.from)); keys.append((r.end, r.to)) }
        return Part(keys.isEmpty ? [(0, 1)] : keys)
    }

    /// Huvudspåret i snitten: 20 ms ner och upp i ett vanligt snitt (inget klick), en halv
    /// övertoning ner till 0,5 och upp igen där delarna blandas.
    public static func cuts(_ cuts: [CutPlan.Cut], allOutputs: [Double]) -> Part {
        var keys: [(t: Double, v: Double)] = []
        let fades = Dictionary(cuts.filter { $0.transition.kind == .crossfade }.map { ($0.output, $0.transition.duration / 2) },
                               uniquingKeysWith: { a, _ in a })
        for c in allOutputs {
            if let half = fades[c] {
                keys += [(c - half, 1), (c, 0.5), (c + half, 1)]
            } else {
                keys += [(c - 0.02, 1), (c, 0), (c + 0.02, 1)]
            }
        }
        return Part(keys.isEmpty ? [(0, 1)] : keys)
    }

    /// Spår B: hörs bara i övertoningarna, upp till 0,5 i snittet och ner igen.
    public static func alternate(_ cuts: [CutPlan.Cut]) -> Part {
        var keys: [(t: Double, v: Double)] = [(0, 0)]
        for c in cuts where c.transition.kind == .crossfade {
            let half = c.transition.duration / 2
            keys += [(c.output - half, 0), (c.output, 0.5), (c.output + half, 0)]
        }
        return Part(keys)
    }
}
