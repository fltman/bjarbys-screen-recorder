import Foundation
import AVFoundation
import CoreImage

/// Instruktionen som bär renderplanen till kompositören.
public final class PolishInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID = kCMPersistentTrackID_Invalid
    public let plan: RenderPlan
    public let screenTrackID: CMPersistentTrackID
    public let cameraTrackID: CMPersistentTrackID?
    /// Videolagrens spår, i planens ordning (`plan.videoOverlayIDs`).
    public let mediaTrackIDs: [CMPersistentTrackID]

    public init(timeRange: CMTimeRange, plan: RenderPlan, screenTrackID: CMPersistentTrackID,
                cameraTrackID: CMPersistentTrackID?, mediaTrackIDs: [CMPersistentTrackID] = []) {
        self.timeRange = timeRange
        self.plan = plan
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.mediaTrackIDs = mediaTrackIDs
        var ids = [NSNumber(value: screenTrackID)]
        if let cameraTrackID { ids.append(NSNumber(value: cameraTrackID)) }
        ids += mediaTrackIDs.map { NSNumber(value: $0) }
        requiredSourceTrackIDs = ids
    }
}

/// En kompositör för både förhandsvisning (`AVPlayer`) och export (`AVAssetReader`), så att
/// det man ser är exakt det som exporteras. Allt ritas med Core Image på GPU:n.
public final class PolishCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    // Parallell kö: AVFoundation har flera rutor i luften samtidigt och CIContext är
    // trådsäker. En seriell kö gav ~1× realtid i 1080p60 på M5.
    private let queue = DispatchQueue(label: "skarminspelare.compositor", qos: .userInitiated, attributes: .concurrent)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? PolishInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "PolishCompositor", code: 1))
                return
            }
            let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
            let camera = instruction.cameraTrackID
                .flatMap { request.sourceFrame(byTrackID: $0) }
                .map { CIImage(cvPixelBuffer: $0) }
            var media: [UUID: CIImage] = [:]
            for (i, trackID) in instruction.mediaTrackIDs.enumerated() where i < instruction.plan.videoOverlayIDs.count {
                if let frame = request.sourceFrame(byTrackID: trackID) {
                    media[instruction.plan.videoOverlayIDs[i]] = CIImage(cvPixelBuffer: frame)
                }
            }
            let t = request.compositionTime.seconds
            let image = instruction.plan.render(outputTime: t, screen: screen, camera: camera, media: media)
            RenderContext.shared.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.plan.canvas),
                                        colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        queue.sync(flags: .barrier) {}
    }
}
