import Foundation
import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Ett kortkommando: tangentkod och Carbon-modifierare, plus tangentens namn som det visas.
struct HotKeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbons modifierare (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32
    /// Tangenten som den står på tangentbordet ("R", "F5", "Mellanslag").
    var key: String

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = (try? c.decode(UInt32.self, forKey: .keyCode)) ?? 0
        modifiers = (try? c.decode(UInt32.self, forKey: .modifiers)) ?? 0
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
    }

    static let standardModifiers = UInt32(cmdKey | optionKey | controlKey)

    /// "⌃⌥⌘R" — i Apples ordning.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// För menyerna (visas bredvid menyvalet).
    var keyboardShortcut: KeyboardShortcut? {
        guard key.count == 1, let ch = key.lowercased().first else { return nil }
        var m: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(ch), modifiers: m)
    }

    /// Ett tryck i kortkommandofältet, eller nil om det inte duger som globalt kortkommando
    /// (det behövs ⌘, ⌃ eller ⌥ — utom för F-tangenterna).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let name = Self.name(for: code, characters: event.charactersIgnoringModifiers)
        let isFunctionKey = Self.functionKeys[code] != nil
        guard !name.isEmpty, isFunctionKey || mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: code, modifiers: mods, key: name)
    }

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
    ]

    private static func name(for code: UInt32, characters: String?) -> String {
        if let f = functionKeys[code] { return f }
        switch Int(code) {
        case kVK_Space: return String(localized: "Mellanslag")
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return ""
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }
}

/// Det som har ett globalt kortkommando.
enum HotKeyAction: UInt32, CaseIterable, Identifiable {
    case toggleRecording = 1, pause = 2, area = 3, flashback = 4, draw = 5, marker = 6
    var id: UInt32 { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .toggleRecording: "Starta och stoppa inspelningen"
        case .pause: "Pausa och fortsätt"
        case .area: "Spela in område"
        case .flashback: "Spara flashback"
        case .draw: "Rita på skärmen"
        case .marker: "Sätt en markering"
        }
    }

    var standard: HotKeyBinding {
        switch self {
        case .toggleRecording: HotKeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: HotKeyBinding.standardModifiers, key: "R")
        case .pause: HotKeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: HotKeyBinding.standardModifiers, key: "P")
        case .area: HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: HotKeyBinding.standardModifiers, key: "A")
        case .flashback: HotKeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: HotKeyBinding.standardModifiers, key: "S")
        case .draw: HotKeyBinding(keyCode: UInt32(kVK_ANSI_D), modifiers: HotKeyBinding.standardModifiers, key: "D")
        case .marker: HotKeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: HotKeyBinding.standardModifiers, key: "M")
        }
    }
}

/// Globala kortkommandon via Carbons `RegisterEventHotKey` — fungerar utan någon behörighet
/// och utan beroenden. Valen sparas i inställningarna och kan ändras under Kortkommandon.
@MainActor
final class HotKeys: ObservableObject {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false
    private static let defaultsKey = "hotKeys"

    /// Valen per åtgärd (standard där inget är valt).
    @Published private(set) var bindings: [HotKeyAction: HotKeyBinding] = [:]
    /// Åtgärder vars kortkommando inte gick att registrera (upptaget av ett annat program).
    @Published private(set) var failed: Set<HotKeyAction> = []

    private init() {
        let saved = (UserDefaults.standard.data(forKey: Self.defaultsKey))
            .flatMap { try? JSONDecoder().decode([String: HotKeyBinding].self, from: $0) } ?? [:]
        for action in HotKeyAction.allCases {
            bindings[action] = saved[String(action.rawValue)] ?? action.standard
        }
    }

    func binding(_ action: HotKeyAction) -> HotKeyBinding { bindings[action] ?? action.standard }

    /// Sätter åtgärdens hanterare och registrerar dess kortkommando.
    func register(_ action: HotKeyAction, _ handler: @escaping () -> Void) {
        installIfNeeded()
        handlers[action.rawValue] = handler
        activate(action)
    }

    /// Byter kortkommando (nil = standard) och sparar.
    func set(_ action: HotKeyAction, to binding: HotKeyBinding?) {
        bindings[action] = binding ?? action.standard
        let dict = Dictionary(uniqueKeysWithValues: bindings.map { (String($0.key.rawValue), $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(dict), forKey: Self.defaultsKey)
        activate(action)
    }

    /// Den andra åtgärden som redan har samma kortkommando, om någon.
    func conflict(for action: HotKeyAction, with binding: HotKeyBinding) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != action && self.binding($0).keyCode == binding.keyCode
            && self.binding($0).modifiers == binding.modifiers }
    }

    /// Medan ett nytt kortkommando spelas in är de globala avstängda, så att trycket hamnar i fältet.
    func suspend() { for (_, ref) in refs { UnregisterEventHotKey(ref) }; refs = [:] }
    func resume() { for action in HotKeyAction.allCases where handlers[action.rawValue] != nil { activate(action) } }

    private func activate(_ action: HotKeyAction) {
        if let old = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(old) }
        guard handlers[action.rawValue] != nil else { return }
        let b = binding(action)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4253_5245), id: action.rawValue) // "BSRE"
        if RegisterEventHotKey(b.keyCode, b.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[action.rawValue] = ref
            failed.remove(action)
        } else {
            failed.insert(action)
        }
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Inställningarna: ett fält per åtgärd. Klicka, tryck den nya kombinationen; Esc avbryter.
struct HotKeySettingsView: View {
    @ObservedObject private var hotKeys = HotKeys.shared
    @State private var recording: HotKeyAction?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kortkommandon").font(.title2.weight(.semibold))
            Text("Gäller överallt, också när appen inte är framme. Klicka på ett kortkommando och tryck det nya (med ⌘, ⌃ eller ⌥). Esc avbryter.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                ForEach(HotKeyAction.allCases) { action in
                    GridRow {
                        Text(action.title)
                        Button {
                            recording == action ? stopRecording() : startRecording(action)
                        } label: {
                            Text(recording == action ? String(localized: "Tryck kombinationen …") : hotKeys.binding(action).display)
                                .font(.body.monospaced())
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(.bordered)
                        .tint(recording == action ? .accentColor : nil)
                        Button("Standard") { hotKeys.set(action, to: nil) }
                            .controlSize(.small)
                            .disabled(hotKeys.binding(action) == action.standard)
                        if hotKeys.failed.contains(action) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Upptaget av ett annat program — välj ett annat.")
                        }
                    }
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(22)
        .frame(width: 520, alignment: .leading)
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: HotKeyAction) {
        stopRecording()
        recording = action
        message = nil
        hotKeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }
            guard let binding = HotKeyBinding(event: event) else {
                message = String(localized: "Ta med ⌘, ⌃ eller ⌥ (eller välj en F-tangent).")
                return nil
            }
            if let other = hotKeys.conflict(for: action, with: binding) {
                hotKeys.set(other, to: hotKeys.binding(action))
            }
            hotKeys.set(action, to: binding)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil { hotKeys.resume() }
        recording = nil
    }
}
