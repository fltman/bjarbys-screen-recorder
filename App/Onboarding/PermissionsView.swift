import SwiftUI
import AVFoundation
import ApplicationServices

/// Behörigheterna appen använder, med status och vägen till Systeminställningar.
struct PermissionsView: View {
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 16) {
            Text("Behörigheter")
                .font(.title2.weight(.semibold))
            Text("Bara skärminspelning krävs. Resten lägger till spår och gör efterbearbetningen bättre.")
                .foregroundStyle(.secondary)

            row("Skärminspelning", "Krävs för att spela in skärmen och datorljudet.",
                granted: CGPreflightScreenCaptureAccess(), anchor: "Privacy_ScreenCapture") {
                CGRequestScreenCaptureAccess()
            }
            row("Mikrofon", "Din röst på ett eget spår.",
                granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                anchor: "Privacy_Microphone") {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            row("Kamera", "Kamerabubblan, som ett eget spår.",
                granted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                anchor: "Privacy_Camera") {
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            }
            row("Indataövervakning", "Visa kortkommandon i videon. Bara tangenter med ⌘ ⌃ ⌥ sparas, aldrig text.",
                granted: CGPreflightListenEventAccess(), anchor: "Privacy_ListenEvent") {
                CGRequestListenEventAccess()
            }
            row("Tillgänglighet", "Låter auto-zoomen rama in knappen du klickar på i stället för en ruta runt pekaren.",
                granted: AXIsProcessTrusted(), anchor: "Privacy_Accessibility") {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            Text("Ändringar av skärminspelning kan kräva att appen startas om.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(timer) { _ in tick += 1 }
    }

    private func row(_ title: String, _ detail: String, granted: Bool, anchor: String,
                     request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Be om") { request() }
                Button("Öppna inställningar") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
            }
        }
    }
}
