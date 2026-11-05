import Foundation
import AVFoundation
import CoreGraphics

/// Färdiga rutor (med all polish) ur en inspelning, genom samma komposition och kompositör
/// som förhandsvisning och export.
public enum FrameGrabber {
    public static func frames(_ rec: LoadedRecording, project: EditProject, outputTimes: [Double],
                              shortSide: Int = 1080) async throws -> (images: [CGImage], plan: RenderPlan) {
        let canvas = RenderPlan.canvasSize(aspect: project.aspect, source: rec.sourceSize, shortSide: shortSide)
        let plan = rec.makePlan(project: project, canvas: canvas)
        let built = try await CompositionBuilder.build(rec, plan: plan, fps: 30)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [CGImage] = []
        for t in outputTimes {
            let clamped = min(max(0, t), max(0, plan.outputDuration - 0.02))
            images.append(try await generator.image(at: CMTime(seconds: clamped, preferredTimescale: 600)).image)
        }
        return (images, plan)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
