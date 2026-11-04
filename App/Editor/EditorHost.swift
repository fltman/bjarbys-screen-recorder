import SwiftUI
import RecorderKit

/// Platshållare tills redigeraren (fas 2) finns.
struct EditorHost: View {
    let bundle: RecordingBundle

    var body: some View {
        Text(bundle.name)
            .frame(minWidth: 900, minHeight: 600)
    }
}
