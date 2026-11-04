import Foundation
import AVFoundation
import CoreMedia

/// Kameran på ett eget spår. Den bakas aldrig in i skärmbilden; bubblan läggs på i
/// efterhand och kan flyttas, ändras och döljas.
public final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    public let deviceName: String
    private let queue = DispatchQueue(label: "skarminspelare.camera", qos: .userInitiated)
    /// Anropas för varje ruta med tiden omräknad till värdklockan.
    public var onFrame: ((CMSampleBuffer, CMTime) -> Void)?

    public init(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw NSError(domain: "CameraCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Kameran hittades inte"])
        }
        deviceName = device.localizedName
        super.init()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "CameraCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Kameran gick inte att öppna"])
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    public func start() {
        queue.async { [session] in session.startRunning() }
    }

    public func stop() {
        queue.sync { session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = CMClockGetHostTimeClock()
        let clock = session.synchronizationClock ?? host
        let hostPTS = CFEqual(clock, host) ? pts : CMSyncConvertTime(pts, from: clock, to: host)
        onFrame?(sampleBuffer, hostPTS)
    }
}
