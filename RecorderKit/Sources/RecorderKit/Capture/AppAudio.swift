import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import CoreMedia
import Darwin
import os

/// En app vars ljud spelas in på ett eget spår. Väljs med bundle-id; `pids` används bara av
/// provlägena (en `afplay` har inget bundle-id).
public struct AudioSourceChoice: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String
    public var pids: [Int32]
    public var id: String { bundleID.isEmpty ? pids.map(String.init).joined(separator: ",") : bundleID }

    public init(bundleID: String, name: String, pids: [Int32] = []) {
        self.bundleID = bundleID; self.name = name; self.pids = pids
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = c.value(.bundleID, ""); name = c.value(.name, ""); pids = c.value(.pids, [])
    }
}

/// Processerna som är anslutna till ljudsystemet, grupperade per app.
///
/// Appar spelar ofta ljud i en hjälpprocess: Chrome i `com.google.Chrome.helper`, Safari och
/// Mail i en delad `com.apple.WebKit.GPU`, Teams i `com.microsoft.teams2.modulehost`. Den
/// ansvariga processen (den som startade hjälparen) knyter dem till rätt app.
public enum AudioProcesses {
    public struct Process: Sendable, Hashable {
        public let objectID: AudioObjectID
        public let pid: pid_t
        public let bundleID: String
        /// Bundle-id för appen som ansvarar för processen (samma som `bundleID` för appen själv).
        public let appBundleID: String
        public let appName: String
        public let isPlaying: Bool
    }

    public struct App: Sendable, Hashable, Identifiable {
        public let bundleID: String
        public let name: String
        public let isPlaying: Bool
        public var id: String { bundleID }

        public init(bundleID: String, name: String, isPlaying: Bool) {
            self.bundleID = bundleID; self.name = name; self.isPlaying = isPlaying
        }
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// `responsibility_get_pid_responsible_for_pid` i libSystem: inte dokumenterad, men stabil
    /// sedan macOS 10.14 och det enda sättet att hitta appen bakom en WebKit-process.
    private static let responsible: ResponsibleFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// Appen bakom en pid. `NSRunningApplication` är långsam utanför huvudtråden, så svaren
    /// sparas (pid:ar återanvänds inte under en inspelning i praktiken).
    private static let appCache = OSAllocatedUnfairLock(initialState: [pid_t: (bundleID: String, name: String)]())

    private static func owningApp(_ pid: pid_t) -> (bundleID: String, name: String)? {
        if let hit = appCache.withLock({ $0[pid] }) { return hit }
        guard let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier else { return nil }
        let entry = (bundleID: id, name: app.localizedName ?? id)
        appCache.withLock { $0[pid] = entry }
        return entry
    }

    public static func list() -> [Process] {
        let ids: [AudioObjectID] = CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return ids.compactMap { id in
            guard let pid: pid_t = CoreAudioProperty.value(id, kAudioProcessPropertyPID) else { return nil }
            let bundle = CoreAudioProperty.string(id, kAudioProcessPropertyBundleID) ?? ""
            let playing: UInt32 = CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            var owner = pid
            if let r = responsible?(pid), r > 0 { owner = r }
            let app = owningApp(owner)
            return Process(objectID: id, pid: pid, bundleID: bundle,
                           appBundleID: app?.bundleID ?? bundle,
                           appName: app?.name ?? bundle,
                           isPlaying: playing != 0)
        }
    }

    /// Apparna med ljud, utan systemtjänster och utan den egna appen. De som spelar just nu först.
    public static func apps() -> [App] {
        let own = Bundle.main.bundleIdentifier ?? ""
        var byID: [String: App] = [:]
        for p in list() where !p.appBundleID.isEmpty && p.appBundleID != own {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: p.appBundleID).first,
                  running.activationPolicy == .regular else { continue }
            let playing = (byID[p.appBundleID]?.isPlaying ?? false) || p.isPlaying
            byID[p.appBundleID] = App(bundleID: p.appBundleID, name: p.appName, isPlaying: playing)
        }
        return byID.values.sorted { a, b in
            a.isPlaying != b.isPlaying ? a.isPlaying : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Anropar `handler` på huvudtråden när en process ansluter till eller lämnar ljudsystemet.
    /// Lyssnaren lever så länge det returnerade objektet gör.
    public static func observe(_ handler: @escaping @MainActor () -> Void) -> AnyObject {
        Observer(handler)
    }

    private final class Observer {
        private let block: AudioObjectPropertyListenerBlock
        init(_ handler: @escaping @MainActor () -> Void) {
            block = { _, _ in Task { @MainActor in handler() } }
            var addr = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
        deinit {
            var addr = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }

    /// Ljudsystemets processobjekt som hör till valet just nu.
    public static func objectIDs(for choice: AudioSourceChoice, in processes: [Process]) -> [AudioObjectID] {
        processes.filter { p in
            if !choice.pids.isEmpty { return choice.pids.contains(p.pid) }
            return p.appBundleID == choice.bundleID || p.bundleID == choice.bundleID
                || p.bundleID.hasPrefix(choice.bundleID + ".")
        }.map(\.objectID)
    }

    /// Den egna processens objekt (hålls utanför "övrigt datorljud").
    public static var ownObjectID: AudioObjectID? {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let id: AudioObjectID = CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject),
                                                              kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                              qualifier: pid),
              id != kAudioObjectUnknown else { return nil }
        return id
    }
}

/// En Core Audio-tapp: ljudet från några processer (eller allt utom några) läses som från en
/// mikrofon, genom en privat aggregatenhet. Kräver `NSAudioCaptureUsageDescription` i den fysiska
/// Info.plist och användarens tillstånd (Ljudinspelning); utan det kommer bara nollor.
///
/// Processlistan följs: en ny hjälpprocess till en vald app (en ny flik som börjar spela) läggs
/// till i tappen, och i "övrigt datorljud" hålls den utanför.
public final class ProcessTap: @unchecked Sendable {
    public enum Mode: Sendable {
        /// Bara de här apparna.
        case only([AudioSourceChoice])
        /// Allt utom de här apparna och den egna appen.
        case allExcept([AudioSourceChoice])
    }

    public enum TapError: LocalizedError {
        case status(String, OSStatus)
        public var errorDescription: String? {
            switch self {
            case let .status(what, code): String(localized: "Ljudtappen gick inte att starta (\(what): \(code))")
            }
        }
    }

    public let mode: Mode
    public let name: String
    /// Buffertar med värdklocktid, på tappens egen kö.
    public var onBuffer: ((CMSampleBuffer, CMTime) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: CMAudioFormatDescription?
    private var asbd = AudioStreamBasicDescription()
    private var currentObjects: [AudioObjectID] = []
    private var listener: AudioObjectPropertyListenerBlock?
    /// Ljudet: bara IOProc körs här, så att inget annat kan försena den (då tappas ljud).
    private let queue: DispatchQueue
    /// Processlistan: att räkna om den tar 80–190 ms (uppmätt) — på ljudkön gav det 0,2 s
    /// glapp varje gång en app började eller slutade spela.
    private let control: DispatchQueue

    public init(mode: Mode, name: String) {
        self.mode = mode
        self.name = name
        queue = DispatchQueue(label: "skarminspelare.tap.\(name)", qos: .userInteractive)
        control = DispatchQueue(label: "skarminspelare.tap.\(name).lista", qos: .utility)
    }

    deinit { stop() }

    private func objects() -> [AudioObjectID] {
        let processes = AudioProcesses.list()
        switch mode {
        case .only(let choices):
            return Array(Set(choices.flatMap { AudioProcesses.objectIDs(for: $0, in: processes) })).sorted()
        case .allExcept(let choices):
            var ids = Set(choices.flatMap { AudioProcesses.objectIDs(for: $0, in: processes) })
            if let own = AudioProcesses.ownObjectID { ids.insert(own) }
            return ids.sorted()
        }
    }

    private func description(for objects: [AudioObjectID], uuid: UUID) -> CATapDescription {
        let d: CATapDescription
        switch mode {
        case .only: d = CATapDescription(stereoMixdownOfProcesses: objects)
        case .allExcept: d = CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
        }
        d.uuid = uuid
        d.name = "Bjarbys skärminspelare – \(name)"
        d.isPrivate = true
        d.muteBehavior = .unmuted
        return d
    }

    public func start() throws {
        currentObjects = objects()
        let uuid = UUID()
        let desc = description(for: currentObjects, uuid: uuid)
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw TapError.status("tapp", status) }

        guard let format: AudioStreamBasicDescription = CoreAudioProperty.value(tapID, kAudioTapPropertyFormat) else {
            stop(); throw TapError.status("format", -1)
        }
        asbd = format
        var fmt: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard status == noErr, let fmt else { stop(); throw TapError.status("formatbeskrivning", status) }
        self.format = fmt

        // Bara tappen i aggregatenheten, inga högtalare: vi blir ingen utklient till ljudkortet
        // och följer inte med om utgången byts. Uppmätt: samma ansats som ScreenCaptureKits
        // datorljud på samplingen (med högtalarna som underenhet 1,7 ms, en gång −147 ms).
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bjarbys skärminspelare – \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else { stop(); throw TapError.status("aggregatenhet", status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, inputTime, _, _ in
            self?.deliver(input, time: inputTime)
        }
        guard status == noErr else { stop(); throw TapError.status("ioproc", status) }
        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else { stop(); throw TapError.status("start", status) }
        watchProcesses(uuid: uuid)
    }

    public func stop() {
        if let listener {
            var addr = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, listener)
            self.listener = nil
            control.sync {}
        }
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Följer processlistan och uppdaterar tappen när en process till en vald app kommer eller går.
    private func watchProcesses(uuid: UUID) {
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.tapID != kAudioObjectUnknown else { return }
            let now = self.objects()
            guard now != self.currentObjects else { return }
            self.currentObjects = now
            let desc = self.description(for: now, uuid: uuid)
            var ref = Unmanaged.passUnretained(desc)
            var a = CoreAudioProperty.address(kAudioTapPropertyDescription)
            AudioObjectSetPropertyData(self.tapID, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &ref)
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block) == noErr {
            listener = block
        }
    }

    private func deliver(_ list: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        guard let format, let onBuffer, time.pointee.mFlags.contains(.hostTimeValid) else { return }
        let first = list.pointee.mBuffers
        let bytesPerFrame = max(1, asbd.mBytesPerFrame)
        let frames = Int(first.mDataByteSize / bytesPerFrame)
        guard frames > 0 else { return }
        let host = CMClockMakeHostTimeFromSystemUnits(time.pointee.mHostTime)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
                                        presentationTimeStamp: host, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr,
              let buffer,
              CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: list) == noErr else { return }
        onBuffer(buffer, host)
    }
}

/// Små hjälpare runt `AudioObjectGetPropertyData`.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func value<T, Q>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, qualifier: Q) -> T? {
        var addr = address(selector)
        var q = qualifier
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        let status = withUnsafeMutablePointer(to: &q) {
            AudioObjectGetPropertyData(object, &addr, UInt32(MemoryLayout<Q>.size), $0, &size, pointer)
        }
        guard status == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return [] }
        let typed = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}
