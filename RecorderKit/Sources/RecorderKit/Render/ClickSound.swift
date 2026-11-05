import Foundation
import AVFoundation

/// Ett kort, mjukt musklick (60 ms) för filmens klickljud, syntetiserat en gång och sparat i
/// appens cache: en kort brusstöt och två dämpade toner (1,9 och 0,9 kHz). Samma ljud varje gång.
public enum ClickSound {
    public static let length = 0.06

    public static func url() -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.brattoo.skarminspelare", isDirectory: true)
        let url = dir.appendingPathComponent("klick-v2.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length * rate)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let p = buffer.floatChannelData![0]
        var seed: UInt32 = 0x2545F491
        for i in 0..<Int(buffer.frameLength) {
            let t = Double(i) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let attack = min(1, t / 0.0004)
            let v = attack * (0.5 * exp(-t / 0.0035) * noise
                              + 0.4 * exp(-t / 0.011) * sin(2 * .pi * 1900 * t)
                              + 0.25 * exp(-t / 0.02) * sin(2 * .pi * 900 * t))
            p[i] = Float(v * 0.8)
        }
        do {
            // 16 bit heltal räcker för ett klick och blir en fjärdedel så stor fil.
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch { return nil }
        return url
    }
}
