import Foundation
import AVFoundation
import CoreAudio

/// Eko- och brusreducering under inspelningen med Apples röstbehandling (Voice Processing, som i
/// FaceTime): ekot från högtalarna dras bort mot det som spelas, och brus dämpas. Den finns bara i
/// realtid, och medan den är igång får andra inspelningar av samma mikrofon inte den obehandlade
/// signalen (uppmätt: ScreenCaptureKits mikrofon sjönk från −51,6 till −78,4 dBFS). Därför är den
/// behandlade signalen då *själva* mikrofonspåret — rådatan sparas inte, det är valets pris.
///
/// Automatisk nivåreglering är av (den lyfte brusgolvet till −45 dBFS); ljudnivån jämnas ut i
/// redigeraren som vanligt.
public final class LiveVoiceProcessing: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let deviceUID: String?
    /// Varje buffert som en mono-buffert med värdklocktid.
    public var onBuffer: ((CMSampleBuffer, CMTime) -> Void)?

    /// `deviceUID` = mikrofonens Core Audio-UID (AVCaptureDevice.uniqueID), nil = standard.
    public init(deviceUID: String?) {
        self.deviceUID = deviceUID
    }

    public func start() throws {
        let input = engine.inputNode
        if let deviceUID, let id = Self.deviceID(uid: deviceUID), let unit = input.audioUnit {
            var device = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = false
        // Andra appars ljud ska inte tonas ned (det spelas in som datorljud).
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        let format = input.outputFormat(forBus: 0)
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self, time.isHostTimeValid, let sb = Self.monoSampleBuffer(buffer, format: mono) else { return }
            self.onBuffer?(sb, CMClockMakeHostTimeFromSystemUnits(time.hostTime))
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Första kanalen som en CMSampleBuffer (tiden sätts av skrivaren).
    static func monoSampleBuffer(_ buffer: AVAudioPCMBuffer, format mono: AVAudioFormat) -> CMSampleBuffer? {
        guard let source = buffer.floatChannelData?[0], buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        copy.floatChannelData![0].update(from: source, count: Int(buffer.frameLength))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(mono.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: mono.formatDescription, sampleCount: CMItemCount(copy.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: copy.audioBufferList) == noErr else { return nil }
        return sample
    }

    /// Core Audio-enheten för en UID.
    static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }
}
