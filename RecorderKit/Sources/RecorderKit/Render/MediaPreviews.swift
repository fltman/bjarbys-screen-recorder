import Foundation
import AVFoundation
import CoreGraphics
import CoreImage

/// Underlag för tidslinjen: vågformer och miniatyrer, i källtid.
public enum MediaPreviews {
    /// Toppvärden (0–1) i `buckets` lika långa fack över `duration` sekunder källtid.
    /// Spårets förskjutning (en mikrofon som börjar 0,5 s in) räknas med.
    public static func waveform(_ asset: AVURLAsset, duration: Double, buckets: Int) async -> [Float] {
        guard buckets > 0, duration > 0,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000,
        ])
        reader.add(out)
        guard reader.startReading() else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        while let buffer = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            let count = length / 2
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                for i in 0..<count {
                    let t = start + Double(i) / 8000
                    let b = Int(t / duration * Double(buckets))
                    guard b >= 0 && b < buckets else { continue }
                    let v = Float(abs(Int32(samples[i]))) / 32768
                    if v > peaks[b] { peaks[b] = v }
                }
            }
        }
        return peaks
    }

    /// Miniatyrer av skärmspåret vid jämnt fördelade källtider.
    public static func thumbnails(_ asset: AVURLAsset, duration: Double, count: Int,
                                  height: CGFloat, hdr: Bool = false) async -> [(t: Double, image: CGImage)] {
        let generator = stillGenerator(asset, hdr: hdr)
        generator.maximumSize = CGSize(width: height * 4, height: height)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var result: [(Double, CGImage)] = []
        for i in 0..<max(count, 1) {
            let t = duration * (Double(i) + 0.5) / Double(max(count, 1))
            if let (image, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                result.append((t, hdr ? sdrStill(image) : image))
            }
        }
        return result
    }

    /// En bildgenerator för stillbilder. HDR: bilden hämtas som HDR och görs om med `sdrStill` —
    /// generatorns egen omvandling till SDR lägger skärmens vitt på grått (som AVFoundations).
    public static func stillGenerator(_ asset: AVURLAsset, hdr: Bool) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        if hdr { generator.dynamicRangePolicy = .matchSource }
        return generator
    }

    /// En HDR-stillbild ur skärmspåret (PQ, SDR-vitt på 100 nits) som SDR: vitt blir vitt,
    /// högdagrarna klipps — samma som en SDR-export av en HDR-inspelning.
    public static func sdrStill(_ image: CGImage) -> CGImage {
        let lifted = CIImage(cgImage: image)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(RenderPlan.hdrScreenGain)])
        let extent = lifted.extent
        // Via en linjär mellanbild: annars lägger Core Image en egen knä-kurva (se PolishCompositor).
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let flat = RenderContext.shared.createCGImage(lifted, from: extent, format: .RGBAh, colorSpace: linear),
              let out = RenderContext.shared.createCGImage(CIImage(cgImage: flat), from: CGRect(origin: .zero, size: extent.size),
                                                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        else { return image }
        return out
    }
}
