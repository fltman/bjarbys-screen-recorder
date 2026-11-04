import Foundation
import AVFoundation
import CoreGraphics

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
                                  height: CGFloat) async -> [(t: Double, image: CGImage)] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: height * 4, height: height)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var result: [(Double, CGImage)] = []
        for i in 0..<max(count, 1) {
            let t = duration * (Double(i) + 0.5) / Double(max(count, 1))
            if let (image, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                result.append((t, image))
            }
        }
        return result
    }
}
