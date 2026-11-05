import Foundation
import AppKit
import SwiftUI
import RecorderKit

/// Appens delade tillstånd och fönstren. Fönstren hanteras med AppKit, så att de kan öppnas
/// från var som helst (kortkommandon, när en inspelning stoppas) och inte bara från vyer.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings()
    let library = LibraryModel()
    let recorder: RecordingController
    private(set) lazy var flashback = FlashbackController(settings: settings)
    private(set) lazy var screenshots = ScreenshotController(settings: settings)

    private var libraryWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    private var editorWindows: [URL: NSWindow] = [:]

    private init() {
        recorder = RecordingController(settings: settings, library: library)
        recorder.onFinished = { [weak self] bundle in
            self?.openEditor(bundle)
            PluginStore.shared.fire(Plugins.recordingFinished, payload: ["recording": bundle.url.path])
        }
        recorder.onNeedsPermissions = { [weak self] in self?.showPermissions() }
    }

    func showLibrary() {
        if libraryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Bjarbys skärminspelare"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: LibraryView().environmentObject(self))
            // Fönstret ska behålla sin storlek; SwiftUI-vyn anger bara minsta storlek.
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            w.setContentSize(NSSize(width: 980, height: 640))
            w.setFrameAutosaveName("Bibliotek")
            w.center()
            libraryWindow = w
        }
        library.reload()
        NSApp.activate()
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    private var scriptWindow: NSWindow?
    private var sharingWindow: NSWindow?
    private var hotKeyWindow: NSWindow?

    func showHotKeySettings() {
        if hotKeyWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = String(localized: "Kortkommandon")
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: HotKeySettingsView())
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            hotKeyWindow = w
        }
        NSApp.activate()
        hotKeyWindow?.makeKeyAndOrderFront(nil)
    }

    private var pluginWindow: NSWindow?

    func showPluginSettings() {
        PluginStore.shared.reload()
        if pluginWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = String(localized: "Insticksprogram")
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: PluginSettingsView())
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            pluginWindow = w
        }
        NSApp.activate()
        pluginWindow?.makeKeyAndOrderFront(nil)
    }

    func showSharingSettings() {
        if sharingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = String(localized: "Delning")
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: SharingSettingsView())
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            sharingWindow = w
        }
        NSApp.activate()
        sharingWindow?.makeKeyAndOrderFront(nil)
    }

    func showScriptEditor() {
        if scriptWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = String(localized: "Manus")
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: ScriptEditorView(settings: settings))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            w.setContentSize(NSSize(width: 560, height: 460))
            w.center()
            scriptWindow = w
        }
        NSApp.activate()
        scriptWindow?.makeKeyAndOrderFront(nil)
    }

    func showPermissions() {
        if permissionsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Behörigheter"
            w.isReleasedWhenClosed = false
            // Fönstret äger storleken. Med standardinställningen försöker SwiftUI styra ett
            // fönster med fast storlek och AppKit kastar ett undantag om oändliga
            // layoutvarv ("more Update Constraints in Window passes than there are views").
            let host = NSHostingController(rootView: PermissionsView())
            host.sizingOptions = []
            w.contentViewController = host
            w.setContentSize(NSSize(width: 600, height: 560))
            w.center()
            permissionsWindow = w
        }
        NSApp.activate()
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }

    func openEditor(_ bundle: RecordingBundle) {
        if let w = editorWindows[bundle.url] {
            NSApp.activate(); w.makeKeyAndOrderFront(nil); return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = bundle.name
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: EditorHost(bundle: bundle).environmentObject(self))
        host.sizingOptions = [.minSize]
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1280, height: 820))
        w.setFrameAutosaveName("Redigerare")
        w.center()
        editorWindows[bundle.url] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.editorWindows[bundle.url] = nil }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
