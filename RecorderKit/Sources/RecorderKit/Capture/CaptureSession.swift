import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// En inspelning från start till stopp.
///
/// En `SCStream` ger skärm (utan markör), datorljud och mikrofon som tre skilda strömmar;
/// kameran kommer från en egen `AVCaptureSession`. Varje spår skrivs av en egen
/// `TrackWriter` till en egen fil. Alla tider går genom samma `RecordingClock`, så spåren
/// och markördatan delar tidslinje.
public final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Status: Sendable {
        public var elapsed: Double = 0
        public var isPaused = false
        public var micLevel: Float = 0
        public var systemLevel: Float = 0
        /// Nivån per app med eget spår, i `options.apps` ordning.
        public var appLevels: [Float] = []
        public var micSilent = false
        public var droppedFrames = 0
        public var freeBytes: Int64?
        public var diskLow = false
        public var keystrokesActive = false
        public var failedTracks: [RecordingMeta.TrackKind] = []
        public var notice: String?

        public init() {}
    }

    public enum StopReason: Sendable, Equatable {
        case user
        case diskFull
        case sharingStopped
        case streamFailed(String)
    }

    public let bundle: RecordingBundle
    public let target: CaptureTarget
    public let options: CaptureOptions
    public private(set) var meta: RecordingMeta
    public let clock = RecordingClock()
    public private(set) var camera: CameraCapture?

    /// Anropas ungefär tio gånger per sekund på huvudtråden.
    public var onStatus: ((Status) -> Void)?
    /// Appens egna paneler, där klick inte ska loggas (globala punkter, origo uppe till vänster).
    public func setIgnoredRegions(_ rects: [CGRect]) { input?.setIgnoredRegions(rects) }
    /// Pennan på eller av (musens nedtryck blir då inte klick).
    public func setDrawing(_ on: Bool) { input?.setDrawing(on) }

    /// Ett streck som ritades på skärmen: punkterna med tid på tidslinjen och global punkt
    /// (origo uppe till vänster). Loggas som en `ink`-händelse.
    public func logInk(_ points: [(t: Double, p: CGPoint)], color: String) {
        guard let start = points.first?.t else { return }
        var flat: [Double] = []
        flat.reserveCapacity(points.count * 3)
        for q in points {
            flat += [((q.t - start) * 1000).rounded() / 1000, (Double(q.p.x) * 10).rounded() / 10, (Double(q.p.y) * 10).rounded() / 10]
        }
        log.append(InputEvent(t: start, k: .ink, pts: flat, color: color))
    }

    /// Första hela rutan har kommit (tidslinjen har en nollpunkt).
    public var hasStarted: Bool { clock.isStarted }
    /// Nollpunkten i värdklockan (s), när den finns.
    public var startHostTime: Double? { clock.origin?.seconds }
    /// Inspelningen behöver stoppas av ett skäl som inte är användarens (full disk, strömmen
    /// dog). Appen anropar då `stop(reason:)`.
    public var onAutoStop: ((StopReason) -> Void)?

    private var stream: SCStream?
    /// Filtret strömmen använder: målets, eller ett städat (utan skrivbordssymboler/notiser).
    private var filter: SCContentFilter?
    private var cleanTimer: Timer?
    private var exceptedFinderWindows: Set<CGWindowID> = []
    private var streamClock: CMClock?
    private var writers: [RecordingMeta.TrackKind: TrackWriter] = [:]
    private let log: EventLogWriter
    private var input: InputRecorder?
    private var cursorSampler: CursorSampler?
    private var windowTracker: WindowTracker?
    private let micMeter = LevelMeter()
    private let systemMeter = LevelMeter()
    /// Apparnas spår (Core Audio-tappar) och "övrigt datorljud" när appar är valda.
    private var appWriters: [TrackWriter] = []
    private var appMeters: [LevelMeter] = []
    private var taps: [ProcessTap] = []
    private let videoQueue = DispatchQueue(label: "skarminspelare.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "skarminspelare.audio", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "skarminspelare.mic", qos: .userInteractive)
    private var statusTimer: Timer?
    private var lastDiskCheck = Date.distantPast
    private var freeBytes: Int64?
    private var restartAttempts = 0
    private var stopping = false
    private var autoStopSent = false
    private var notice: String?
    // Senaste skärmrutan (bara på videoQueue). SCK skickar inga rutor när skärmen står
    // still; vid stopp läggs den sista rutan in igen vid sluttiden så att skärmspåret blir
    // lika långt som ljudet.
    private var lastScreen: CMSampleBuffer?
    private var lastScreenTime = CMTime.invalid

    public init(target: CaptureTarget, options: CaptureOptions,
                directory: URL = RecordingLibrary.defaultDirectory) throws {
        self.target = target
        self.options = options
        bundle = try RecordingBundle.create(in: directory)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        meta = RecordingMeta(source: target.metaSource, fps: options.fps, appVersion: version)
        meta.hdr = options.hdr
        log = try EventLogWriter(url: bundle.eventsURL)
        super.init()
        // meta.json skrivs direkt, så att en krasch lämnar ett identifierbart paket.
        try bundle.writeMeta(meta)
    }

    // MARK: - Start

    @MainActor
    public func start() async throws {
        let size = target.pixelSize
        writers[.screen] = try TrackWriter(kind: .screen, url: bundle.trackURL(.screen),
                                           settings: .screen(width: size.width, height: size.height, fps: options.fps,
                                                             hdr: options.hdr))
        meta.tracks = [.init(kind: .screen, file: RecordingBundle.fileName(for: .screen), deviceName: target.title)]
        if options.systemAudio {
            writers[.system] = try TrackWriter(kind: .system, url: bundle.trackURL(.system), settings: .audio)
            meta.tracks.append(.init(kind: .system, file: RecordingBundle.fileName(for: .system),
                                     deviceName: options.apps.isEmpty ? "Datorljud" : "Övrigt datorljud"))
        }
        for (i, app) in options.apps.enumerated() {
            let file = RecordingBundle.appFileName(i)
            appWriters.append(try TrackWriter(kind: .app, url: bundle.recordingDir.appendingPathComponent(file), settings: .audio))
            appMeters.append(LevelMeter())
            meta.tracks.append(.init(kind: .app, file: file, deviceName: app.name, appID: app.id))
        }
        if let mic = options.microphone {
            writers[.microphone] = try TrackWriter(kind: .microphone, url: bundle.trackURL(.microphone), settings: .audio)
            meta.tracks.append(.init(kind: .microphone, file: RecordingBundle.fileName(for: .microphone), deviceName: mic.name))
        }
        if let cam = options.camera {
            do {
                let capture = try CameraCapture(deviceID: cam.id)
                camera = capture
                writers[.camera] = try TrackWriter(kind: .camera, url: bundle.trackURL(.camera), settings: .camera)
                meta.tracks.append(.init(kind: .camera, file: RecordingBundle.fileName(for: .camera), deviceName: capture.deviceName))
            } catch {
                notice = "Kameran gick inte att starta: \(error.localizedDescription)"
            }
        }

        filter = await cleanFilter() ?? target.filter
        let stream = try makeStream()
        try await stream.startCapture()
        self.stream = stream
        startCleanWatch()
        streamClock = stream.synchronizationClock

        camera?.onFrame = { [weak self] buffer, host in self?.handleCamera(buffer, host: host) }
        camera?.start()
        startTaps()

        let input = InputRecorder(clock: clock, log: log, keystrokes: options.keystrokes)
        let probe = ElementProbe(log: log)
        input.onMouseDown = { point, t in probe.probe(at: point, t: t) }
        input.onTyping = { t in probe.typing(t: t) }
        input.start()
        self.input = input
        meta.keystrokesRecorded = input.keystrokesActive

        let sampler = CursorSampler(clock: clock, log: log, bundle: bundle)
        sampler.start()
        cursorSampler = sampler
        if let windowID = target.windowID {
            let tracker = WindowTracker(windowID: windowID, clock: clock, log: log)
            tracker.start()
            windowTracker = tracker
        }

        try? bundle.writeMeta(meta)
        startStatusTimer()
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        // HDR: förvalet sätter dynamikomfång, pixelformat (x420), färgrymd (BT.2100 PQ) och
        // matris. ⚠️ Sätt aldrig en egen färgrymd ovanpå — då tonmappas allt tyst till SDR.
        let c = options.hdr ? SCStreamConfiguration(preset: .captureHDRRecordingPreservedSDRHDR10) : SCStreamConfiguration()
        let size = target.pixelSize
        c.width = size.width
        c.height = size.height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        c.queueDepth = 8
        // Markören ritas tillbaka i efterhand ur markördatan.
        c.showsCursor = false
        if !options.hdr {
            c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            c.colorSpaceName = CGColorSpace.sRGB
            c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        }
        if let source = target.sourceRect { c.sourceRect = source }
        c.scalesToFit = true
        c.preservesAspectRatio = true
        c.ignoreShadowsSingleWindow = true
        c.capturesAudio = options.systemAudioFromStream
        c.sampleRate = 48_000
        c.channelCount = 2
        c.excludesCurrentProcessAudio = true
        if let mic = options.microphone {
            c.captureMicrophone = true
            c.microphoneCaptureDeviceID = mic.id
        }
        c.streamName = "Bjarbys skärminspelare"
        return c
    }

    private func makeStream() throws -> SCStream {
        let stream = SCStream(filter: filter ?? target.filter, configuration: makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if options.systemAudioFromStream {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if options.microphone != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        return stream
    }

    // MARK: - Städad inspelning

    /// Ett filter utan skrivbordssymboler och/eller notiser, för skärm och område. Skrivbords-
    /// symbolerna ligger i ett eget helskärmsfönster från Finder (på skrivbordsnivå, uppmätt) och
    /// skrivbordsbilden ritas av Dock, så Finder utesluts men dess vanliga fönster tas med.
    /// Notiser och skrivbordswidgets kommer från notisappen (och t.ex. Teams egen).
    private func cleanFilter() async -> SCContentFilter? {
        guard options.hideDesktopIcons || options.hideNotifications,
              target.kind == .display || target.kind == .area,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first(where: { $0.displayID == target.displayID }) else { return nil }
        let own = Bundle.main.bundleIdentifier ?? ""
        var apps = content.applications.filter { $0.bundleIdentifier == own }
        if options.hideNotifications {
            apps += content.applications.filter { $0.bundleIdentifier.lowercased().contains("notificationcenter") }
        }
        var excepted: [SCWindow] = []
        if options.hideDesktopIcons {
            apps += content.applications.filter { $0.bundleIdentifier == "com.apple.finder" }
            excepted = Self.finderWindows(content)
        }
        exceptedFinderWindows = Set(excepted.map(\.windowID))
        return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: excepted)
    }

    /// Finders vanliga fönster (allt utom skrivbordet).
    static func finderWindows(_ content: SCShareableContent) -> [SCWindow] {
        content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer > Int(CGWindowLevelForKey(.desktopIconWindow))
        }
    }

    /// Nya Finderfönster under inspelningen tas med: listan kontrolleras varannan sekund och
    /// filtret byts när den ändrats.
    @MainActor
    private func startCleanWatch() {
        guard options.hideDesktopIcons, filter !== target.filter else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshCleanFilter() }
        }
        RunLoop.main.add(t, forMode: .common)
        cleanTimer = t
    }

    @MainActor
    private func refreshCleanFilter() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        let now = Set(Self.finderWindows(content).map(\.windowID))
        guard now != exceptedFinderWindows, let fresh = await cleanFilter() else { return }
        filter = fresh
        try? await stream?.updateContentFilter(fresh)
    }

    // MARK: - Paus

    public func pause() {
        guard !clock.isPaused else { return }
        log.append(InputEvent(t: clock.elapsed, k: .pause))
        clock.pause()
    }

    public func resume() {
        guard clock.isPaused else { return }
        clock.resume()
        log.append(InputEvent(t: clock.elapsed, k: .resume))
    }

    // MARK: - Stopp

    @MainActor
    @discardableResult
    public func stop(reason: StopReason = .user) async -> RecordingMeta {
        guard !stopping else { return meta }
        stopping = true
        statusTimer?.invalidate()
        statusTimer = nil
        let end = clock.elapsed
        if let origin = clock.origin { meta.startHostTime = origin.seconds }

        cleanTimer?.invalidate()
        cleanTimer = nil
        input?.stop()
        cursorSampler?.stop()
        windowTracker?.stop()
        try? await stream?.stopCapture()
        stream = nil
        camera?.stop()
        for tap in taps { tap.stop() }
        taps = []

        // Sista rutan vid sluttiden, och töm köerna innan filerna stängs.
        videoQueue.sync {
            let t = CMTime(seconds: end, preferredTimescale: 600)
            if let last = lastScreen, lastScreenTime.isValid, t - lastScreenTime > CMTime(value: 1, timescale: 120) {
                writers[.screen]?.append(last, at: t)
            }
            lastScreen = nil
        }
        audioQueue.sync {}
        micQueue.sync {}

        for (kind, writer) in writers {
            let ok = await writer.finish()
            guard let i = meta.tracks.firstIndex(where: { $0.kind == kind }) else { continue }
            if !ok || writer.appended == 0 { meta.tracks[i].failed = true }
            if writer.firstPTS.isNumeric { meta.tracks[i].start = writer.firstPTS.seconds }
        }
        for (n, writer) in appWriters.enumerated() {
            let ok = await writer.finish()
            let file = RecordingBundle.appFileName(n)
            if !ok || writer.appended == 0, let i = meta.tracks.firstIndex(where: { $0.file == file }) {
                meta.tracks[i].failed = true
            }
        }
        log.close()

        meta.duration = end
        meta.finished = true
        meta.droppedFrames = writers[.screen]?.dropped ?? 0
        try? bundle.writeMeta(meta)
        await Self.makeThumbnail(for: bundle, at: min(1.0, end / 2))
        return meta
    }

    /// Stoppar och flyttar paketet till papperskorgen.
    @MainActor
    public func discard() async {
        await stop()
        try? FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
    }

    public static func makeThumbnail(for bundle: RecordingBundle, at seconds: Double) async {
        let asset = AVURLAsset(url: bundle.trackURL(.screen))
        let hdr = (try? bundle.readMeta())?.hdr ?? false
        let generator = MediaPreviews.stillGenerator(asset, hdr: hdr)
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.appliesPreferredTrackTransform = true
        guard let (still, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)),
              let dest = CGImageDestinationCreateWithURL(bundle.thumbnailURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        let image = hdr ? MediaPreviews.sdrStill(still) : still
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Strömmen

    private func hostTime(_ pts: CMTime) -> CMTime {
        let host = CMClockGetHostTimeClock()
        guard let streamClock, !CFEqual(streamClock, host) else { return pts }
        return CMSyncConvertTime(pts, from: streamClock, to: host)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let host = hostTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer), CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            // Första hela skärmrutan sätter nollpunkten för alla spår.
            clock.startIfNeeded(at: host)
            guard let t = clock.map(host) else { return }
            writers[.screen]?.append(sampleBuffer, at: t)
            lastScreen = sampleBuffer
            lastScreenTime = t
        case .audio:
            systemMeter.process(sampleBuffer, host: host)
            guard let t = clock.map(host) else { return }
            writers[.system]?.append(sampleBuffer, at: t)
        case .microphone:
            micMeter.process(sampleBuffer, host: host)
            guard let t = clock.map(host) else { return }
            writers[.microphone]?.append(sampleBuffer, at: t)
        @unknown default:
            break
        }
    }

    /// Core Audio-tapparna: en per app, och "övrigt datorljud" (allt utom apparna och oss själva)
    /// när appar är valda. Tiderna är värdklocka och går genom samma `RecordingClock` som allt annat.
    @MainActor
    private func startTaps() {
        guard !options.apps.isEmpty else { return }
        for (i, app) in options.apps.enumerated() {
            let tap = ProcessTap(mode: .only([app]), name: app.name)
            let writer = appWriters[i], meter = appMeters[i]
            tap.onBuffer = { [weak self] buffer, host in
                meter.process(buffer, host: host)
                guard let t = self?.clock.map(host) else { return }
                writer.append(buffer, at: t)
            }
            do { try tap.start(); taps.append(tap) } catch {
                notice = String(localized: "Ljudet från \(app.name) gick inte att spela in: \(error.localizedDescription)")
            }
        }
        if options.systemAudio, let writer = writers[.system] {
            let tap = ProcessTap(mode: .allExcept(options.apps), name: "Övrigt datorljud")
            let meter = systemMeter
            tap.onBuffer = { [weak self] buffer, host in
                meter.process(buffer, host: host)
                guard let t = self?.clock.map(host) else { return }
                writer.append(buffer, at: t)
            }
            do { try tap.start(); taps.append(tap) } catch {
                notice = String(localized: "Datorljudet gick inte att spela in: \(error.localizedDescription)")
            }
        }
    }

    /// Kameran ger några nästan svarta rutor innan exponeringen ställt in sig (~0,4 s på MacBook
    /// Pro-kameran, uppmätt). De hoppas över, högst 1,5 s, så att spåret — och bubblans intoning —
    /// börjar med en riktig bild. Bara på kamerans kö.
    private var cameraWarmedUp = false
    private var cameraFirstHost: CMTime?

    private func handleCamera(_ buffer: CMSampleBuffer, host: CMTime) {
        guard let t = clock.map(host) else { return }
        if !cameraWarmedUp {
            let first = cameraFirstHost ?? host
            cameraFirstHost = first
            if (host - first).seconds < 1.5, Self.meanLuma(buffer) < 24 { return }
            cameraWarmedUp = true
        }
        writers[.camera]?.append(buffer, at: t)
    }

    /// Medelluma (0–255) i ett glest rutnät av en 4:2:0-ruta.
    static func meanLuma(_ buffer: CMSampleBuffer) -> Double {
        guard let px = CMSampleBufferGetImageBuffer(buffer), CVPixelBufferIsPlanar(px) else { return 255 }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(px, 0) else { return 255 }
        let w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let y = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, n = 0
        for gy in 1..<10 { for gx in 1..<16 { sum += Int(y[(h * gy / 10) * row + w * gx / 16]); n += 1 } }
        return Double(sum) / Double(max(n, 1))
    }

    static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete || status == .started
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in await self.handleStreamStop(error) }
    }

    /// Vakthunden. Användaren som stoppar delningen i menyraden stoppar inspelningen;
    /// annars startas strömmen om (högst tre gånger) och luckan loggas. Skrivarna fortsätter
    /// på samma filer, så inget som redan skrivits går förlorat.
    @MainActor
    private func handleStreamStop(_ error: Error) async {
        guard !stopping else { return }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userStopped.rawValue {
            sendAutoStop(.sharingStopped)
            return
        }
        guard restartAttempts < 3 else {
            sendAutoStop(.streamFailed(ns.localizedDescription))
            return
        }
        restartAttempts += 1
        let gapStart = clock.elapsed
        try? await Task.sleep(for: .milliseconds(300))
        do {
            let stream = try makeStream()
            try await stream.startCapture()
            self.stream = stream
            streamClock = stream.synchronizationClock
            meta.gaps.append(.init(start: gapStart, end: clock.elapsed, reason: ns.localizedDescription))
            try? bundle.writeMeta(meta)
            notice = "Strömmen avbröts och startades om"
        } catch {
            sendAutoStop(.streamFailed(error.localizedDescription))
        }
    }

    @MainActor
    private func sendAutoStop(_ reason: StopReason) {
        guard !autoStopSent else { return }
        autoStopSent = true
        onAutoStop?(reason)
    }

    // MARK: - Status

    @MainActor
    private func startStatusTimer() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickStatus() }
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    @MainActor
    private func tickStatus() {
        if Date().timeIntervalSince(lastDiskCheck) >= 5 {
            lastDiskCheck = Date()
            freeBytes = DiskSpace.freeBytes(at: bundle.url)
            if let free = freeBytes, free < DiskSpace.stopBelow {
                sendAutoStop(.diskFull)
            }
        }
        var s = Status()
        s.elapsed = clock.elapsed
        s.isPaused = clock.isPaused
        s.micLevel = micMeter.read().peak
        s.systemLevel = systemMeter.read().peak
        s.appLevels = appMeters.map { $0.read().peak }
        s.micSilent = options.microphone != nil && s.elapsed > 3 && !s.isPaused && micMeter.isSilent(for: 3)
        s.droppedFrames = writers[.screen]?.dropped ?? 0
        s.freeBytes = freeBytes
        s.diskLow = (freeBytes ?? .max) < DiskSpace.warnBelow
        s.keystrokesActive = input?.keystrokesActive ?? false
        s.failedTracks = writers.filter { $0.value.hasFailed }.map(\.key) + (appWriters.contains { $0.hasFailed } ? [.app] : [])
        s.notice = notice
        onStatus?(s)
    }
}
