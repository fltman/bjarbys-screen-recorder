import Foundation
import AVFoundation
import AudioToolbox

/// Brusreducering med Apples röstisolering (`AUSoundIsolation`, samma som "Röstisolering" i
/// Kontrollcenter), körd offline på mikrofonspåret. Resultatet sparas som en härledd fil i
/// paketet; inspelningen rörs aldrig och reduceringen går att slå av.
///
/// Den isolerade filen börjar vid inspelningens nollpunkt (mikrofonens senare start fylls med
/// tystnad) och ljudenhetens fördröjning är bortdragen, så att den kan ersätta originalet rakt av.
public enum VoiceIsolation {
    public static let sampleRate = 48_000.0

    public struct Result: Sendable {
        public let url: URL
        /// Ljudenhetens fördröjning som drogs bort (s).
        public let latency: Double
    }

    /// Kör röstisoleringen på `asset` och skriver en 48 kHz mono-fil till `url`.
    public static func process(_ asset: AVURLAsset, to url: URL,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let (samples, offset) = try await readMono(asset)
        guard !samples.isEmpty else { throw WhisperError.noAudio }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        AudioUnitSetParameter(effect.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                              kAudioUnitScope_Global, 0, 100, 0)
        AudioUnitSetParameter(effect.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
                              kAudioUnitScope_Global, 0, AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
        try engine.start()

        let latency = effect.auAudioUnit.latency + engine.mainMixerNode.auAudioUnit.latency
        let latencyFrames = Int((latency * sampleRate).rounded())
        // Tystnad efter slutet så att det fördröjda slutet också kommer ut.
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count + latencyFrames))!
        input.frameLength = input.frameCapacity
        let ch = input.floatChannelData![0]
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        for i in samples.count..<Int(input.frameLength) { ch[i] = 0 }
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        let lead = Int((offset * sampleRate).rounded())
        var output = [Float](repeating: 0, count: lead)
        output.reserveCapacity(lead + samples.count)
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var rendered = 0
        let total = Int(input.frameLength)
        while rendered < total {
            try Task.checkCancellation()
            let n = AVAudioFrameCount(min(4096, total - rendered))
            let status = try engine.renderOffline(n, to: chunk)
            guard status == .success else { break }
            let p = chunk.floatChannelData![0]
            output.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(chunk.frameLength)))
            rendered += Int(chunk.frameLength)
            if rendered % (4096 * 64) == 0 { progress(Double(rendered) / Double(total)) }
        }
        engine.stop()
        // Dra bort fördröjningen: det som kom ut efter `latencyFrames` hör till början.
        if latencyFrames > 0 && output.count > lead + latencyFrames {
            output.removeSubrange(lead..<(lead + latencyFrames))
        }
        output = Array(output.prefix(lead + samples.count))

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(output.count))!
        out.frameLength = out.frameCapacity
        output.withUnsafeBufferPointer { out.floatChannelData![0].update(from: $0.baseAddress!, count: output.count) }
        try file.write(from: out)
        progress(1)
        return Result(url: url, latency: latency)
    }

    /// Spåret som 48 kHz mono och tiden för första samplet på inspelningens tidslinje.
    static func readMono(_ asset: AVURLAsset) async throws -> ([Float], Double) {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw WhisperError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: sampleRate,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? WhisperError.noAudio }
        var samples: [Float] = []
        var first: Double?
        while let buffer = out.copyNextSampleBuffer() {
            if first == nil { first = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
                samples.append(contentsOf: UnsafeBufferPointer(start: p, count: length / 4))
            }
        }
        return (samples, max(0, first ?? 0))
    }
}

extension RecordingBundle {
    /// Härledda filer (går alltid att göra om ur inspelningen).
    public var derivedDir: URL { url.appendingPathComponent("derived", isDirectory: true) }
    public var isolatedMicrophoneURL: URL { derivedDir.appendingPathComponent("mic-isolated.caf") }
}
