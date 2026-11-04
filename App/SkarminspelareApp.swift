import SwiftUI
import RecorderKit

@main
struct SkarminspelareApp: App {
    var body: some Scene {
        MenuBarExtra("Bjarbys skärminspelare", systemImage: "record.circle") {
            Button("Öppna biblioteket") {}
            Divider()
            Button("Avsluta") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        Window("Bjarbys skärminspelare", id: "library") {
            Text("Inga inspelningar än")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
