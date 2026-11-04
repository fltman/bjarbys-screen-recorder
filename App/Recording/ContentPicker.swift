import Foundation
import ScreenCaptureKit

/// Systemets väljare för fönster och program (`SCContentSharingPicker`). Apple rekommenderar
/// den framför egna listor, och den egna appen hålls utanför urvalet.
@MainActor
final class ContentPicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter?, Never>?

    func pick(_ mode: SCContentSharingPickerMode, style: SCShareableContentStyle) async -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = mode
        if let me = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [me] }
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        defer {
            picker.remove(self)
            picker.isActive = false
        }
        return await withCheckedContinuation { c in
            continuation = c
            picker.present(using: style)
        }
    }

    private func finish(_ filter: SCContentFilter?) {
        continuation?.resume(returning: filter)
        continuation = nil
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        Task { @MainActor in self.finish(filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
