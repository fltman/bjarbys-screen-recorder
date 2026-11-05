import Foundation
import AppKit
import SwiftUI
import ScreenCaptureKit
import RecorderKit

/// Polerade skärmdumpar från menyn: fönster, område eller hela skärmen. Sparas i
/// biblioteket under Skärmdumpar och kopieras till urklipp.
@MainActor
final class ScreenshotController {
    private let settings: AppSettings
    private let picker = ContentPicker()
    private var areaSelector: AreaSelector?
    private var toast: FloatingPanel?

    init(settings: AppSettings) { self.settings = settings }

    func window() {
        Task {
            guard let filter = await picker.pick([.singleWindow], style: .window) else { return }
            await finish(try await Screenshot.capture(filter: filter), isWindow: true, name: String(localized: "Fönster"))
        }
    }

    func area() {
        let selector = AreaSelector()
        areaSelector = selector
        selector.run { [weak self] rect in
            guard let self else { return }
            self.areaSelector = nil
            guard let rect else { return }
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else { return }
                    // Området i skärmens egna punkter.
                    let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                    await self.finish(try await Screenshot.capture(display: display, area: local, excluding: own),
                                      isWindow: false, name: String(localized: "Område"))
                } catch {
                    self.show(error.localizedDescription)
                }
            }
        }
    }

    func fullScreen() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
                let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { return }
                let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                await finish(try await Screenshot.capture(display: display, excluding: own), isWindow: false,
                             name: String(localized: "Skärmen"))
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func finish(_ captured: @autoclosure () async throws -> CGImage, isWindow: Bool, name: String) async {
        do {
            var image = try await captured()
            if settings.screenshotPolish {
                var style = Screenshot.Style()
                if EditProject.Background.presets.indices.contains(settings.screenshotBackground) {
                    style.background = EditProject.Background.presets[settings.screenshotBackground]
                }
                image = Screenshot.polish(image, style: style, isWindow: isWindow) ?? image
            }
            let url = Screenshot.newURL(name: name)
            try Screenshot.writePNG(image, to: url)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([NSImage(contentsOf: url) ?? NSImage(cgImage: image, size: .zero)])
            show(String(localized: "Skärmdumpen är kopierad och sparad"), url: url)
        } catch {
            show(error.localizedDescription)
        }
    }

    /// En kort bekräftelse nere i mitten; klick visar filen i Finder.
    private func show(_ message: String, url: URL? = nil) {
        toast?.close()
        let size = CGSize(width: 380, height: 44)
        let panel = FloatingPanel(size: size, on: CGMainDisplayID()) { visible, size in
            CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
        }
        panel.contentView = NSHostingView(rootView:
            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .onTapGesture { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } })
        panel.orderFrontRegardless()
        toast = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self, weak panel] in
            panel?.close()
            if self?.toast === panel { self?.toast = nil }
        }
    }
}
