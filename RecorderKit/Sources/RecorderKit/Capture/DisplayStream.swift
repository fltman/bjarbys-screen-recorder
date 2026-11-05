import Foundation
import ScreenCaptureKit
import CoreMedia

/// En extra skärm när alla skärmar spelas in: en egen ström med bara bild, till ett eget
/// skärmspår (`screen-<n>.mov`) på samma klocka som huvudströmmen — så att skärmarna kan läggas
/// ihop till ett virtuellt skrivbord i renderingen.
final class DisplayStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let target: CaptureTarget
    let writer: TrackWriter
    private let clock: RecordingClock
    private let fps: Int
    private let hdr: Bool
    private var stream: SCStream?
    private var streamClock: CMClock?
    private let queue = DispatchQueue(label: "skarminspelare.skarm2", qos: .userInteractive)
    private var last: CMSampleBuffer?
    private var lastTime = CMTime.invalid

    init(target: CaptureTarget, url: URL, clock: RecordingClock, fps: Int, hdr: Bool) throws {
        self.target = target
        self.clock = clock
        self.fps = fps
        self.hdr = hdr
        let size = target.pixelSize
        writer = try TrackWriter(kind: .screen, url: url, settings: .screen(width: size.width, height: size.height, fps: fps, hdr: hdr))
    }

    func start(filter: SCContentFilter) async throws {
        let c = hdr ? SCStreamConfiguration(preset: .captureHDRRecordingPreservedSDRHDR10) : SCStreamConfiguration()
        let size = target.pixelSize
        c.width = size.width
        c.height = size.height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        c.queueDepth = 8
        c.showsCursor = false
        if !hdr {
            c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            c.colorSpaceName = CGColorSpace.sRGB
            c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        }
        c.capturesAudio = false
        c.streamName = "Bjarbys skärminspelare – \(target.title)"
        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        streamClock = s.synchronizationClock
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CaptureSession.isCompleteFrame(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostClock = CMClockGetHostTimeClock()
        let host = streamClock.map { CFEqual($0, hostClock) ? pts : CMSyncConvertTime(pts, from: $0, to: hostClock) } ?? pts
        guard let t = clock.map(host) else { return }
        writer.append(sampleBuffer, at: t)
        last = sampleBuffer
        lastTime = t
    }

    /// Stoppar; sista rutan läggs in vid sluttiden (en stillastående skärm ger inga nya rutor).
    func stop(at end: Double) async -> Bool {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync {
            let t = CMTime(seconds: end, preferredTimescale: 600)
            if let last, lastTime.isValid, t - lastTime > CMTime(value: 1, timescale: 120) { writer.append(last, at: t) }
            last = nil
        }
        let ok = await writer.finish()
        return ok && writer.appended > 0
    }
}
