import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Skriver ett spår till en egen fil. Varje spår har en egen AVAssetWriter, så att ett
/// spår som fallerar (t.ex. en mikrofon som kopplas ur) inte drar med sig de andra.
///
/// Filerna är QuickTime-filer med `movieFragmentInterval` = 2 s: en ny självständig bit
/// skrivs varannan sekund, så att en krasch lämnar en fil som går att spela upp till den
/// senaste biten.
public final class TrackWriter: @unchecked Sendable {
    public enum Settings {
        case screen(width: Int, height: Int, fps: Int, hdr: Bool = false)
        case camera
        case audio
    }

    public let kind: RecordingMeta.TrackKind
    public let url: URL
    private let settings: Settings
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let lock = NSLock()
    private var lastPTS = CMTime.invalid
    private var lastEnd = CMTime.invalid
    private var finished = false

    public private(set) var appended = 0
    /// Första buffertens tid på inspelningens tidslinje (kameran kommer igång ~0,5 s efter skärmen).
    public private(set) var firstPTS = CMTime.invalid
    public private(set) var dropped = 0
    public private(set) var failure: Error?

    public init(kind: RecordingMeta.TrackKind, url: URL, settings: Settings) throws {
        self.kind = kind
        self.url = url
        self.settings = settings
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false
    }

    /// Skrivaren tar emot mer just nu (för provlägen som skriver snabbare än realtid).
    public var isReady: Bool { lock.withLock { input?.isReadyForMoreMediaData ?? true } }

    public var hasFailed: Bool {
        lock.withLock { failure != nil || writer.status == .failed }
    }

    /// Lägger till en buffert med ny presentationstid på inspelningens tidslinje.
    public func append(_ buffer: CMSampleBuffer, at pts: CMTime) {
        lock.withLock {
            guard !finished, failure == nil else { return }
            if input == nil {
                guard let format = CMSampleBufferGetFormatDescription(buffer) else { return }
                do { try begin(format: format) } catch {
                    failure = error
                    return
                }
            }
            guard let input else { return }
            if writer.status == .failed {
                failure = writer.error
                return
            }

            let isAudio = input.mediaType == .audio
            let duration = CMSampleBufferGetDuration(buffer)
            // Tiderna måste öka strikt. Video: kasta dubbletter. Ljud: kasta en buffert som
            // överlappar den förra mer än en millisekund (kan hända precis efter en paus).
            if lastPTS.isValid {
                if !isAudio && pts <= lastPTS { dropped += 1; return }
                if isAudio && lastEnd.isValid && pts < lastEnd - CMTime(value: 1, timescale: 1000) {
                    dropped += 1; return
                }
            }
            guard let retimed = Self.retime(buffer, to: pts) else { dropped += 1; return }
            if input.isReadyForMoreMediaData {
                if input.append(retimed) {
                    if appended == 0 { firstPTS = pts }
                    appended += 1
                    lastPTS = pts
                    lastEnd = duration.isNumeric ? pts + duration : pts
                } else {
                    failure = writer.error
                }
            } else {
                dropped += 1
            }
        }
    }

    /// Avslutar filen. Returnerar sant om den skrevs klart.
    public func finish() async -> Bool {
        let w: AVAssetWriter? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            guard let input, writer.status == .writing else { return nil }
            input.markAsFinished()
            return writer
        }
        guard let w else { return false }
        await w.finishWriting()
        if w.status != .completed {
            lock.withLock { failure = w.error }
            return false
        }
        return true
    }

    /// Kastar filen (användaren valde att slänga tagningen).
    public func cancel() {
        lock.withLock {
            finished = true
            if writer.status == .writing { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Uppsättning

    private func begin(format: CMFormatDescription) throws {
        let mediaType: AVMediaType
        let output: [String: Any]
        switch settings {
        case let .screen(width, height, fps, hdr):
            mediaType = .video
            output = Self.screenSettings(width: width, height: height, fps: fps, hdr: hdr)
        case .camera:
            mediaType = .video
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            output = Self.cameraSettings(width: Int(dims.width), height: Int(dims.height))
        case .audio:
            mediaType = .audio
            output = Self.pcmSettings(format: format)
        }
        let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: output, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "TrackWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Kunde inte lägga till spåret \(kind.rawValue)"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "TrackWriter", code: 2)
        }
        writer.startSession(atSourceTime: .zero)
        self.input = input
    }

    /// Bitrate efter pixelmängd. Skärminnehåll komprimeras bra; 0,035 bit per pixel och
    /// ruta ger skarp text i HEVC. Begränsat till 4–40 Mbit/s.
    public static func screenBitrate(width: Int, height: Int, fps: Int) -> Int {
        let bps = Double(width * height * fps) * 0.035
        return Int(min(max(bps, 4_000_000), 40_000_000))
    }

    /// HDR: HEVC Main10 med samma färgegenskaper som ScreenCaptureKits HDR10-rutor (BT.2020 PQ),
    /// och en fjärdedel mer data för de två extra bitarna.
    static func screenSettings(width: Int, height: Int, fps: Int, hdr: Bool = false) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: hdr ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ] : [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: screenBitrate(width: width, height: height, fps: fps) * (hdr ? 5 : 4) / 4,
                AVVideoExpectedSourceFrameRateKey: fps,
                // Nyckelbild varannan sekund: snabb sökning i redigeraren och samma gräns
                // som fragmenten.
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                kVTCompressionPropertyKey_RealTime as String: true,
                AVVideoProfileLevelKey: (hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String,
            ],
        ]
    }

    static func cameraSettings(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 3),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                kVTCompressionPropertyKey_RealTime as String: true,
            ],
        ]
    }

    /// Okomprimerat 24-bitars PCM med källans kanalantal och samplingsfrekvens. Rå röst
    /// utan förluster, så att brusreducering i efterhand har allt att arbeta med.
    static func pcmSettings(format: CMFormatDescription) -> [String: Any] {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let rate = asbd.map { $0.mSampleRate } ?? 48_000
        let channels = Int(asbd?.mChannelsPerFrame ?? 2)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: min(channels, 2),
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Kopierar bufferten med alla tider flyttade så att den första hamnar på `pts`.
    static func retime(_ buffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(buffer)
        let delta = pts - original
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        if count > 0 {
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        } else {
            timing[0] = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(buffer),
                                           presentationTimeStamp: original, decodeTimeStamp: .invalid)
        }
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid {
                timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + delta
            }
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + delta
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: timing.count, sampleTimingArray: &timing, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
}

/// Ledigt utrymme på volymen där inspelningen skrivs.
public enum DiskSpace {
    /// Faktiskt ledigt utrymme just nu (inte "important usage", som räknar in sådant
    /// systemet kanske kan rensa senare — vi skriver nu).
    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Varna under 5 GB, stoppa rent under 1,5 GB.
    public static let warnBelow: Int64 = 5_000_000_000
    public static let stopBelow: Int64 = 1_500_000_000
}
