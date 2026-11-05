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
    /// Skärmspår B: förrulle och efterrulle för övertoningar.
    public let alternateTrackID: CMPersistentTrackID?
    /// Flera skärmar: skärm 2, 3 … (skärm 1 är skärmspåret).
    public let displayTrackIDs: [CMPersistentTrackID]

    public init(timeRange: CMTimeRange, plan: RenderPlan, screenTrackID: CMPersistentTrackID,
                cameraTrackID: CMPersistentTrackID?, mediaTrackIDs: [CMPersistentTrackID] = [],
                alternateTrackID: CMPersistentTrackID? = nil, displayTrackIDs: [CMPersistentTrackID] = []) {
        self.alternateTrackID = alternateTrackID
        self.displayTrackIDs = displayTrackIDs
        self.timeRange = timeRange
        self.plan = plan
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.mediaTrackIDs = mediaTrackIDs
        var ids = [NSNumber(value: screenTrackID)]
        if let cameraTrackID { ids.append(NSNumber(value: cameraTrackID)) }
        ids += mediaTrackIDs.map { NSNumber(value: $0) }
        if let alternateTrackID { ids.append(NSNumber(value: alternateTrackID)) }
        ids += displayTrackIDs.map { NSNumber(value: $0) }
        requiredSourceTrackIDs = ids
    }
}

/// En kompositör för både förhandsvisning (`AVPlayer`) och export (`AVAssetReader`), så att
/// det man ser är exakt det som exporteras. Allt ritas med Core Image på GPU:n.
public class PolishCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Tar emot HDR-rutor oförändrade (annars gör AVFoundation om dem till SDR först).
    class var acceptsHDR: Bool { false }
    /// Ritar HLG i halvflyttal i stället för sRGB i 8 bit.
    class var rendersHDR: Bool { false }

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        let formats: [OSType] = Self.acceptsHDR
            ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_64RGBAHalf,
               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
            : [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
        return [kCVPixelBufferPixelFormatTypeKey as String: formats, kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.rendersHDR ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public var supportsHDRSourceFrames: Bool { Self.acceptsHDR }
    public var supportsWideColorSourceFrames: Bool { Self.acceptsHDR }

    // Parallell kö: AVFoundation har flera rutor i luften samtidigt och CIContext är
    // trådsäker. En seriell kö gav ~1× realtid i 1080p60 på M5.
    private let queue = DispatchQueue(label: "skarminspelare.compositor", qos: .userInitiated, attributes: .concurrent)
    private static let sdrSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let hlgSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    private var colorSpace: CGColorSpace { Self.rendersHDR ? PolishCompositor.hlgSpace : PolishCompositor.sdrSpace }

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
            let alternate = instruction.alternateTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            let displays = instruction.displayTrackIDs.map { request.sourceFrame(byTrackID: $0).map { CIImage(cvPixelBuffer: $0) } }
            let image = instruction.plan.render(outputTime: t, screen: screen, camera: camera, media: media, alternate: alternate,
                                                displays: displays)
            let bounds = CGRect(origin: .zero, size: instruction.plan.canvas)
            if Self.acceptsHDR && !Self.rendersHDR, let flat = flatten(image, bounds: bounds) {
                RenderContext.shared.render(flat, to: output, bounds: bounds, colorSpace: colorSpace)
            } else {
                RenderContext.shared.render(image, to: output, bounds: bounds, colorSpace: colorSpace)
            }
            // HDR-inspelningar: kompositionen har inga färgegenskaper (se `videoComposition`), så
            // utdata märks här — HLG i BT.2020, eller BT.709 som SDR-kompositionerna.
            if Self.rendersHDR {
                CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
                CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            } else if Self.acceptsHDR {
                CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            }
            request.finish(withComposedVideoFrame: output)
        }
    }

    /// HDR till SDR: rutan ritas först linjärt i halvflyttal och tas sedan in som en ny bild.
    /// Med en PQ-källa i grafen lägger Core Image annars en egen knä-kurva vid utritningen till
    /// 8-bitars sRGB: linjärt 1,0 blev 229 i stället för 255, oavsett `toneMapHDRtoSDR`,
    /// innehållshuvudrum eller klämning (uppmätt). Ett extra pass i bildytans storlek.
    private var flatPool: (size: CGSize, pool: CVPixelBufferPool)?
    private let poolLock = NSLock()

    private func flatten(_ image: CIImage, bounds: CGRect) -> CIImage? {
        let pool: CVPixelBufferPool? = poolLock.withLock {
            if let p = flatPool, p.size == bounds.size { return p.pool }
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferWidthKey as String: Int(bounds.width), kCVPixelBufferHeightKey as String: Int(bounds.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ] as CFDictionary, &made)
            if let made { flatPool = (bounds.size, made) }
            return made
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        RenderContext.shared.render(image, to: buffer, bounds: bounds, colorSpace: PolishCompositor.linearSpace)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: PolishCompositor.linearSpace])
    }
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    public func cancelAllPendingVideoCompositionRequests() {
        queue.sync(flags: .barrier) {}
    }
}

/// HDR-inspelning till HDR (BT.2100 HLG): förhandsvisningen och exporten "MP4 4K HDR".
public final class PolishHDRCompositor: PolishCompositor, @unchecked Sendable {
    override class var acceptsHDR: Bool { true }
    override class var rendersHDR: Bool { true }
}

/// HDR-inspelning till SDR: alla andra exporter.
public final class PolishHDRToSDRCompositor: PolishCompositor, @unchecked Sendable {
    override class var acceptsHDR: Bool { true }
}
