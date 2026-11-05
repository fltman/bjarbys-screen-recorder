import Foundation
import AVFoundation
import CoreMediaIO
import os

/// Det en inspelning måste kunna för att styras från menyraden och HUD:en — skärm (ScreenCaptureKit)
/// eller enhet (kamera, iPhone/iPad).
@MainActor
public protocol Recorder: AnyObject {
    var bundle: RecordingBundle { get }
    var clock: RecordingClock { get }
    var hasStarted: Bool { get }
    var onStatus: ((CaptureSession.Status) -> Void)? { get set }
    var onAutoStop: ((CaptureSession.StopReason) -> Void)? { get set }
    func start() async throws
    func pause()
    func resume()
    @discardableResult func stop(reason: CaptureSession.StopReason) async -> RecordingMeta
    func discard() async
    @discardableResult func logMarker() -> Double?
    func logInk(_ points: [(t: Double, p: CGPoint)], color: String)
    func setDrawing(_ on: Bool)
    func setIgnoredRegions(_ rects: [CGRect])
}

extension CaptureSession: Recorder {}
extension DeviceSession: Recorder {}

/// Inspelning från en kamera eller en iPhone/iPad via kabel i stället för skärmen. Bilden blir
/// skärmspåret, så att redigeraren fungerar som vanligt (bakgrund, ram, undertexter, export) —
/// bara utan markör. En iPhone eller iPad syns som en enhet när CoreMediaIO tillåter
/// skärmenheter (samma sak som QuickTime gör); dess ljud blir datorljudsspåret. Mikrofonen spelas
/// in i en egen session, och tiderna räknas om till värdklockan så att spåren hamnar rätt.
public final class DeviceSession: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate {
    public struct Device: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        /// En iPhone eller iPad (skärmen via kabel), inte en kamera.
        public let isScreen: Bool
    }

    /// Slår på iPhone/iPad som enheter (CoreMediaIO). De dyker upp en stund efteråt.
    public static func allowScreenDevices() {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// Kameror och anslutna iPhone/iPad.
    public static func devices() -> [Device] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: nil, position: .unspecified)
        return discovery.devices.compactMap { d in
            guard d.hasMediaType(.video) || d.hasMediaType(.muxed) else { return nil }
            // En iPhone/iPad via kabel är en "muxed" enhet (bild och ljud tillsammans).
            return Device(id: d.uniqueID, name: d.localizedName, isScreen: d.hasMediaType(.muxed))
        }
    }

    public let bundle: RecordingBundle
    public let clock = RecordingClock()
    public private(set) var meta: RecordingMeta
    public var onStatus: ((CaptureSession.Status) -> Void)?
    public var onAutoStop: ((CaptureSession.StopReason) -> Void)?
    /// Sessionen med bilden (för förhandsvisningen).
    public let session = AVCaptureSession()
    private let micSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioDataOutput?
    private let device: AVCaptureDevice
    private let isScreen: Bool
    private let fps: Int
    private let videoQueue = DispatchQueue(label: "skarminspelare.enhet.bild", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "skarminspelare.enhet.ljud", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "skarminspelare.enhet.mik", qos: .userInitiated)
    private var screenWriter: TrackWriter?
    private var soundWriter: TrackWriter?
    private var micWriter: TrackWriter?
    private let log: EventLogWriter
    private let micMeter = LevelMeter(), soundMeter = LevelMeter()
    private var statusTimer: Timer?
    private var stopping = false
    private var started: CheckedContinuation<Void, Error>?
    private let startLock = NSLock()
    private var lastFrame: CMSampleBuffer?
    private var lastFrameTime = CMTime.invalid

    public var hasStarted: Bool { clock.isStarted }

    public init(deviceID: String, microphoneID: String?, fps: Int = 60, directory: URL, appVersion: String = "") throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw NSError(domain: "DeviceSession", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Enheten hittades inte.")])
        }
        self.device = device
        self.fps = fps
        isScreen = device.hasMediaType(.muxed)
        bundle = try RecordingBundle.create(in: directory)
        try FileManager.default.createDirectory(at: bundle.recordingDir, withIntermediateDirectories: true)
        log = try EventLogWriter(url: bundle.eventsURL)
        meta = RecordingMeta(source: .init(kind: .device, title: device.localizedName, displayID: 0, windowID: nil,
                                           contentRect: .zero, pixelScale: 1, pixelWidth: 0, pixelHeight: 0),
                             fps: fps, appVersion: appVersion)
        if let microphoneID, let mic = microphoneID == "standard" ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: microphoneID),
           mic.uniqueID != device.uniqueID {
            let s = AVCaptureSession()
            if let input = try? AVCaptureDeviceInput(device: mic), s.canAddInput(input) { s.addInput(input) }
            micSession = s
        } else {
            micSession = nil
        }
        super.init()

        session.beginConfiguration()
        if !isScreen {
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 } else { session.sessionPreset = .high }
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "DeviceSession", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Enheten gick inte att öppna.")])
        }
        session.addInput(input)
        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(video) { session.addOutput(video) }
        // En iPhone/iPad har sitt eget ljud i samma enhet.
        if device.hasMediaType(.muxed) || device.hasMediaType(.audio) {
            let sound = AVCaptureAudioDataOutput()
            sound.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(sound) { session.addOutput(sound) }
        }
        session.commitConfiguration()
        if let micSession {
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: micQueue)
            if micSession.canAddOutput(out) { micSession.addOutput(out); micOutput = out }
        }
        try bundle.writeMeta(meta)
    }

    // MARK: - Start, paus, stopp

    @MainActor
    public func start() async throws {
        micSession?.startRunning()
        session.startRunning()
        // Vänta på första rutan (den sätter tidslinjens nollpunkt), högst 8 s.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await withCheckedThrowingContinuation { c in self.startLock.withLock { self.started = c } } }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw NSError(domain: "DeviceSession", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "Ingen bild från enheten (är den upplåst och ansluten?).")])
            }
            try await group.next()
            group.cancelAll()
        }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

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

    @MainActor
    @discardableResult
    public func stop(reason: CaptureSession.StopReason = .user) async -> RecordingMeta {
        guard !stopping else { return meta }
        stopping = true
        statusTimer?.invalidate()
        statusTimer = nil
        let end = clock.elapsed
        if let origin = clock.origin { meta.startHostTime = origin.seconds }
        session.stopRunning()
        micSession?.stopRunning()
        videoQueue.sync {
            // Sista rutan vid sluttiden (en stillastående bild ger inga nya rutor).
            let t = CMTime(seconds: end, preferredTimescale: 600)
            if let last = lastFrame, lastFrameTime.isValid, t - lastFrameTime > CMTime(value: 1, timescale: 120) {
                screenWriter?.append(last, at: t)
            }
            lastFrame = nil
        }
        audioQueue.sync {}
        micQueue.sync {}
        for (kind, writer) in [(RecordingMeta.TrackKind.screen, screenWriter), (.system, soundWriter), (.microphone, micWriter)] {
            guard let writer else { continue }
            let ok = await writer.finish()
            var track = RecordingMeta.Track(kind: kind, file: RecordingBundle.fileName(for: kind),
                                            deviceName: kind == .microphone ? (micSession?.inputs.first as? AVCaptureDeviceInput)?.device.localizedName ?? ""
                                                                            : device.localizedName)
            track.failed = !ok || writer.appended == 0
            if writer.firstPTS.isNumeric { track.start = writer.firstPTS.seconds }
            meta.tracks.append(track)
        }
        log.close()
        try? BundleJSON.write(CursorCatalog(), to: bundle.cursorCatalogURL)
        meta.duration = end
        meta.finished = true
        meta.droppedFrames = screenWriter?.dropped ?? 0
        try? bundle.writeMeta(meta)
        await CaptureSession.makeThumbnail(for: bundle, at: min(1.0, end / 2))
        return meta
    }

    @MainActor
    public func discard() async {
        await stop()
        try? FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
    }

    @discardableResult
    public func logMarker() -> Double? {
        guard clock.isStarted, !clock.isPaused else { return nil }
        let t = clock.elapsed
        log.append(InputEvent(t: t, k: .marker))
        return t
    }

    /// Pennan ritar på skärmen, inte i enhetens bild — strecken hör inte till den här inspelningen.
    public func logInk(_ points: [(t: Double, p: CGPoint)], color: String) {}
    public func setDrawing(_ on: Bool) {}
    public func setIgnoredRegions(_ rects: [CGRect]) {}

    // MARK: - Buffertarna

    private func hostTime(_ buffer: CMSampleBuffer, in s: AVCaptureSession) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let host = CMClockGetHostTimeClock()
        let clock = s.synchronizationClock ?? host
        return CFEqual(clock, host) ? pts : CMSyncConvertTime(pts, from: clock, to: host)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            let host = hostTime(buffer, in: session)
            if clock.startIfNeeded(at: host), let px = CMSampleBufferGetImageBuffer(buffer) {
                // Första rutan: skärmspårets storlek och tidslinjens nollpunkt.
                let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
                meta.source.pixelWidth = w; meta.source.pixelHeight = h
                meta.source.contentRect = Rect(x: 0, y: 0, width: Double(w), height: Double(h))
                try? bundle.writeMeta(meta)
                screenWriter = try? TrackWriter(kind: .screen, url: bundle.trackURL(.screen),
                                                settings: .screen(width: w, height: h, fps: fps))
                startLock.withLock { started?.resume(); started = nil }
            }
            guard let t = clock.map(host) else { return }
            screenWriter?.append(buffer, at: t)
            lastFrame = buffer
            lastFrameTime = t
        } else if let micSession, output === micOutput {
            appendAudio(buffer, host: hostTime(buffer, in: micSession), kind: .microphone)
        } else {
            appendAudio(buffer, host: hostTime(buffer, in: session), kind: .system)
        }
    }

    private func appendAudio(_ buffer: CMSampleBuffer, host: CMTime, kind: RecordingMeta.TrackKind) {
        (kind == .microphone ? micMeter : soundMeter).process(buffer, host: host)
        guard let t = clock.map(host) else { return }
        if kind == .microphone {
            if micWriter == nil { micWriter = try? TrackWriter(kind: .microphone, url: bundle.trackURL(.microphone), settings: .audio) }
            micWriter?.append(buffer, at: t)
        } else {
            if soundWriter == nil { soundWriter = try? TrackWriter(kind: .system, url: bundle.trackURL(.system), settings: .audio) }
            soundWriter?.append(buffer, at: t)
        }
    }

    // MARK: - Status

    private var lastDiskCheck = Date.distantPast
    private var freeBytes: Int64?

    @MainActor
    private func tick() {
        if Date().timeIntervalSince(lastDiskCheck) >= 5 {
            lastDiskCheck = Date()
            freeBytes = DiskSpace.freeBytes(at: bundle.url)
            if let free = freeBytes, free < DiskSpace.stopBelow { onAutoStop?(.diskFull) }
        }
        var s = CaptureSession.Status()
        s.elapsed = clock.elapsed
        s.isPaused = clock.isPaused
        s.micLevel = micMeter.read().peak
        s.systemLevel = soundMeter.read().peak
        s.micSilent = micSession != nil && s.elapsed > 3 && !s.isPaused && micMeter.isSilent(for: 3)
        s.droppedFrames = screenWriter?.dropped ?? 0
        s.freeBytes = freeBytes
        s.diskLow = (freeBytes ?? .max) < DiskSpace.warnBelow
        onStatus?(s)
    }
}
