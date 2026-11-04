import Foundation
import CoreMedia
import AVFoundation
import os

/// Nivåmätare för ett ljudspår: topp och RMS för HUD:en, plus vakten som märker en
/// mikrofon som inte ger någon signal alls.
///
/// Vakten avgör bara *signal eller ingen signal* — ingen taltröskel. En riktig mikrofon har
/// alltid ett brusgolv (MacBook-mikrofonen ger RMS 0,004–0,016 i tystnad, uppmätt i
/// Kundkoll), så en topp under 0,0003 (≈ −70 dBFS) i tre sekunder betyder en död ingång,
/// inte en tyst talare.
public final class LevelMeter: @unchecked Sendable {
    private struct State {
        var peak: Float = 0
        var rms: Float = 0
        var lastSignal: CMTime = .invalid
        var firstBuffer: CMTime = .invalid
    }

    public static let silenceFloor: Float = 0.0003
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func process(_ buffer: CMSampleBuffer, host: CMTime) {
        guard let (peak, rms) = Self.measure(buffer) else { return }
        state.withLock { s in
            s.peak = max(s.peak, peak)
            s.rms = max(s.rms, rms)
            if !s.firstBuffer.isValid { s.firstBuffer = host }
            if peak > Self.silenceFloor { s.lastSignal = host }
        }
    }

    /// Topp och RMS sedan förra avläsningen (0–1), och nollställ.
    public func read() -> (peak: Float, rms: Float) {
        state.withLock { s in
            let r = (s.peak, s.rms)
            s.peak = 0; s.rms = 0
            return r
        }
    }

    /// Sant om bufferar har kommit men ingen av dem haft signal på `seconds` sekunder.
    public func isSilent(for seconds: Double, now: CMTime = RecordingClock.hostNow()) -> Bool {
        state.withLock { s in
            guard s.firstBuffer.isValid else { return false }
            let since = s.lastSignal.isValid ? s.lastSignal : s.firstBuffer
            return (now - since).seconds >= seconds
        }
    }

    /// Topp och RMS över hela bufferten, för flyttal och 16/32-bitars heltal.
    static func measure(_ buffer: CMSampleBuffer) -> (Float, Float)? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        var blockBuffer: CMBlockBuffer?
        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        var peak: Float = 0
        var sumSquares: Double = 0
        var count = 0
        for ab in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = ab.mData else { continue }
            let bytes = Int(ab.mDataByteSize)
            if isFloat && bits == 32 {
                let p = data.bindMemory(to: Float.self, capacity: bytes / 4)
                for i in 0..<(bytes / 4) {
                    let v = abs(p[i]); peak = max(peak, v); sumSquares += Double(v * v)
                }
                count += bytes / 4
            } else if bits == 16 {
                let p = data.bindMemory(to: Int16.self, capacity: bytes / 2)
                for i in 0..<(bytes / 2) {
                    let v = abs(Float(p[i]) / 32768); peak = max(peak, v); sumSquares += Double(v * v)
                }
                count += bytes / 2
            } else if bits == 32 {
                let p = data.bindMemory(to: Int32.self, capacity: bytes / 4)
                for i in 0..<(bytes / 4) {
                    let v = abs(Float(p[i]) / 2_147_483_648); peak = max(peak, v); sumSquares += Double(v * v)
                }
                count += bytes / 4
            }
        }
        guard count > 0 else { return nil }
        return (peak, Float((sumSquares / Double(count)).squareRoot()))
    }
}
