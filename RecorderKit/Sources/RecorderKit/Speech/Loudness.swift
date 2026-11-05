import Foundation
import AVFoundation

/// Ljudstyrka enligt ITU-R BS.1770-4 / EBU R128: K-viktning, 400 ms-block med 75 % överlapp,
/// absolut grind −70 LUFS och relativ grind −10 LU. Kalibrerad mot ffmpegs `ebur128`.
public enum Loudness {
    /// Målet för talad video på nätet (YouTube m.fl. normaliserar till −14, podd −16).
    public static let target = -16.0
    /// Topparna får inte gå över det här efter förstärkning (ingen limiter i kedjan).
    public static let peakCeiling = -1.0

    public struct Measurement: Equatable, Sendable {
        /// Integrerad ljudstyrka i LUFS för spåret som det är (mono).
        public let integrated: Double
        /// Högsta sampelvärdet, 0–1.
        public let peak: Double
    }

    /// Integrerad ljudstyrka för monosampel i 48 kHz, eller nil om allt är tystnad.
    public static func integrated(_ samples: [Float], sampleRate: Double = 48_000) -> Double? {
        precondition(sampleRate == 48_000, "K-viktningens koefficienter gäller 48 kHz")
        // Steg 1: högsoffilter (huvudets akustik). Steg 2: högpass (RLB).
        var x = samples.map(Double.init)
        biquad(&x, b: [1.53512485958697, -2.69169618940638, 1.19839281085285],
               a: [-1.69065929318241, 0.73248077421585])
        biquad(&x, b: [1.0, -2.0, 1.0], a: [-1.99004745483398, 0.99007225036621])

        let block = Int(0.4 * sampleRate), step = Int(0.1 * sampleRate)
        guard x.count >= block else { return nil }
        // Löpande summa av kvadraterna, så att varje block kostar O(1).
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in x.indices { prefix[i + 1] = prefix[i] + x[i] * x[i] }
        var powers: [Double] = []
        var start = 0
        while start + block <= x.count {
            powers.append((prefix[start + block] - prefix[start]) / Double(block))
            start += step
        }
        func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(max(p, 1e-20)) }
        let absolute = powers.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Direktform I, normaliserad (a0 = 1).
    static func biquad(_ x: inout [Double], b: [Double], a: [Double]) {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let x0 = x[i]
            let y0 = b[0] * x0 + b[1] * x1 + b[2] * x2 - a[0] * y1 - a[1] * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            x[i] = y0
        }
    }

    /// Mäter ett ljudspår (läses som 48 kHz mono).
    public static func measure(_ asset: AVURLAsset) async throws -> Measurement? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? WhisperError.noAudio }
        var samples: [Float] = []
        while let buffer = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
                samples.append(contentsOf: UnsafeBufferPointer(start: p, count: length / 4))
            }
        }
        guard let lufs = integrated(samples) else { return nil }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return Measurement(integrated: lufs, peak: Double(peak))
    }

    /// Förstärkningen (linjär) som tar ett monospår till `target` i den färdiga stereofilmen,
    /// begränsad så att topparna stannar under `peakCeiling`. Exporten lägger monospåret i
    /// båda kanalerna, vilket gör filmen 3 dB starkare än spåret ensamt.
    public static func gain(for m: Measurement, target: Double = target) -> (gain: Double, limitedByPeaks: Bool) {
        let wanted = target - 3.01 - m.integrated
        let headroom = peakCeiling - 20 * log10(max(m.peak, 1e-9))
        let db = min(wanted, headroom)
        return (pow(10, db / 20), headroom < wanted)
    }
}
