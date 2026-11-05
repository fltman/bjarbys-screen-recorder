import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation

/// Mikrofoner och kameror som går att välja.
public enum Devices {
    public struct Device: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
    }

    public static func microphones() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    public static func cameras() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    public static var defaultMicrophone: Device? {
        AVCaptureDevice.default(for: .audio).map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Vad som ska spelas in: ett innehållsfilter plus geometrin som behövs för att räkna om
/// markörens globala koordinater till skärmspåret.
public struct CaptureTarget: @unchecked Sendable {
    public let filter: SCContentFilter
    public let kind: RecordingMeta.SourceKind
    public let title: String
    public let displayID: CGDirectDisplayID
    public let windowID: CGWindowID?
    /// Innehållets ram i globala punkter (origo uppe till vänster på huvudskärmen).
    public let contentRect: CGRect
    /// Bara för område: utsnittet i skärmens egna punkter.
    public let sourceRect: CGRect?
    public let pixelScale: CGFloat
    /// Alla skärmar: de övriga skärmarna (den här är den första). Tom = en skärm.
    public var otherDisplays: [CaptureTarget] = []

    /// Skärmspårets storlek i pixlar, avrundad till jämna tal (krävs av kodaren).
    public var pixelSize: (width: Int, height: Int) {
        func even(_ v: CGFloat) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(contentRect.width * pixelScale), even(contentRect.height * pixelScale))
    }

    /// Den egna appen ska aldrig synas: HUD, nedräkning och kameraförhandsvisning hålls ute
    /// här. `NSWindow.sharingType = .none` duger inte — SCK ignorerar den sedan macOS 15.4.
    static func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        let me = Bundle.main.bundleIdentifier ?? ""
        return content.applications.filter { $0.bundleIdentifier == me }
    }

    /// Alla skärmar: huvudskärmen, med de övriga i `otherDisplays` (från vänster till höger).
    public static func allDisplays(in content: SCShareableContent) -> CaptureTarget? {
        let main = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
        guard let main else { return nil }
        var t = display(main, in: content)
        t.otherDisplays = content.displays.filter { $0.displayID != main.displayID }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { display($0, in: content) }
        return t
    }

    /// Hela skärmen. `includingOwnApp` bara för provlägen som visar något eget som ska spelas in.
    public static func display(_ display: SCDisplay, in content: SCShareableContent,
                               includingOwnApp: Bool = false) -> CaptureTarget {
        let filter = SCContentFilter(display: display, excludingApplications: includingOwnApp ? [] : ownApplications(in: content),
                                     exceptingWindows: [])
        return CaptureTarget(filter: filter, kind: .display, title: displayName(display.displayID),
                             displayID: display.displayID, windowID: nil, contentRect: display.frame,
                             sourceRect: nil, pixelScale: CGFloat(filter.pointPixelScale))
    }

    /// Ett område på en skärm, angivet i globala punkter.
    public static func area(_ rect: CGRect, on display: SCDisplay, in content: SCShareableContent) -> CaptureTarget {
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications(in: content),
                                     exceptingWindows: [])
        let clipped = rect.intersection(display.frame).integral
        let local = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return CaptureTarget(filter: filter, kind: .area,
                             title: "Område \(Int(clipped.width))×\(Int(clipped.height))",
                             displayID: display.displayID, windowID: nil, contentRect: clipped,
                             sourceRect: local, pixelScale: CGFloat(filter.pointPixelScale))
    }

    /// Det som valdes i systemets väljare (`SCContentSharingPicker`).
    public static func fromPicker(_ filter: SCContentFilter) -> CaptureTarget {
        let scale = CGFloat(filter.pointPixelScale)
        switch filter.style {
        case .window:
            let window = filter.includedWindows.first
            let frame = window.flatMap { WindowTracker.frame(of: $0.windowID) } ?? window?.frame ?? filter.contentRect
            let app = window?.owningApplication?.applicationName ?? ""
            let title = [app, window?.title ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
            let display = displayContaining(frame)
            return CaptureTarget(filter: filter, kind: .window, title: title.isEmpty ? "Fönster" : title,
                                 displayID: display, windowID: window?.windowID, contentRect: frame,
                                 sourceRect: nil, pixelScale: scale)
        case .application:
            let display = filter.includedDisplays.first
            let app = filter.includedApplications.first?.applicationName ?? "Program"
            return CaptureTarget(filter: filter, kind: .application, title: app,
                                 displayID: display?.displayID ?? CGMainDisplayID(),
                                 windowID: nil, contentRect: display?.frame ?? filter.contentRect,
                                 sourceRect: nil, pixelScale: scale)
        default:
            let display = filter.includedDisplays.first
            let id = display?.displayID ?? CGMainDisplayID()
            return CaptureTarget(filter: filter, kind: .display, title: displayName(id), displayID: id,
                                 windowID: nil, contentRect: display?.frame ?? CGDisplayBounds(id),
                                 sourceRect: nil, pixelScale: scale)
        }
    }

    static func displayContaining(_ rect: CGRect) -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetDisplaysWithRect(rect, UInt32(ids.count), &ids, &count)
        return count > 0 ? ids[0] : CGMainDisplayID()
    }

    public static func displayName(_ id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? "Skärm"
    }

    var metaSource: RecordingMeta.Source {
        let size = pixelSize
        return RecordingMeta.Source(kind: kind, title: title, displayID: displayID, windowID: windowID,
                                    contentRect: Rect(contentRect), pixelScale: Double(pixelScale),
                                    pixelWidth: size.width, pixelHeight: size.height)
    }
}

/// Vilka spår som ska med.
public struct CaptureOptions: Sendable {
    public var fps: Int = 60
    public var systemAudio: Bool = true
    public var microphone: Devices.Device?
    public var camera: Devices.Device?
    public var keystrokes: Bool = false
    /// Appar med eget ljudspår (Core Audio-tappar). När listan inte är tom blir `systemAudio`
    /// "övrigt datorljud": allt utom de valda apparna, också det via en tapp.
    public var apps: [AudioSourceChoice] = []
    /// HDR: 10 bit BT.2020 PQ i stället för 8 bit sRGB. Bara meningsfullt på en HDR-skärm.
    public var hdr: Bool = false
    /// Städad inspelning (skärm och område): skrivbordssymbolerna, respektive notiser och
    /// skrivbordswidgets, hålls utanför inspelningen. Skärmen och systemet ändras inte.
    public var hideDesktopIcons: Bool = false
    public var hideNotifications: Bool = false
    /// Eko- och brusreducering under inspelningen (Apples röstbehandling): den behandlade
    /// signalen blir mikrofonspåret, rådatan sparas inte (se `LiveVoiceProcessing`).
    public var liveVoiceProcessing: Bool = false
    /// Mikrofonen tas från ScreenCaptureKit (inte från röstbehandlingen).
    var microphoneFromStream: Bool { microphone != nil && !liveVoiceProcessing }

    public init(fps: Int = 60, systemAudio: Bool = true, microphone: Devices.Device? = nil,
                camera: Devices.Device? = nil, keystrokes: Bool = false, apps: [AudioSourceChoice] = []) {
        self.fps = fps; self.systemAudio = systemAudio; self.microphone = microphone
        self.camera = camera; self.keystrokes = keystrokes; self.apps = apps
    }

    /// Datorljudet tas från ScreenCaptureKit (beprövat, uppmätt synk) när inga appar är valda.
    var systemAudioFromStream: Bool { systemAudio && apps.isEmpty }
}
