import Foundation
import Security
import SwiftUI
import AppKit
import RecorderKit

/// Delningens inställningar: adress, hink och nyckel-id i inställningarna, den hemliga nyckeln
/// i nyckelringen (aldrig i en fil).
enum SharingStore {
    private static let defaultsKey = "shareConfig"
    private static let service = "com.brattoo.skarminspelare.s3"

    static var config: S3Config {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let c = try? JSONDecoder().decode(S3Config.self, from: data) else { return S3Config() }
            return c
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }

    static var secret: String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        query[kSecAttrAccount as String] = config.accessKeyID
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setSecret(_ secret: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !secret.isEmpty else { return }
        var add = base
        add[kSecAttrAccount as String] = account
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrLabel as String] = "Bjarbys skärminspelare – delning"
        SecItemAdd(add as CFDictionary, nil)
    }

    static var isReady: Bool { config.isComplete && !(secret ?? "").isEmpty }

    /// Laddar upp och lägger länken i urklipp.
    static func share(_ file: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let url = try await S3Uploader.upload(file, config: config, secret: secret ?? "", progress: progress)
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        return url
    }
}

struct SharingSettingsView: View {
    @State private var config = SharingStore.config
    @State private var secret = SharingStore.secret ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("Egen lagring (S3, R2)") {
            Text("Ladda upp exporterade filmer till din egen S3-kompatibla lagring (Cloudflare R2, AWS S3, MinIO, Backblaze B2) och få en länk i urklipp.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Adress", text: $config.endpoint, prompt: Text(verbatim: "https://<konto>.r2.cloudflarestorage.com"))
            TextField("Hink", text: $config.bucket)
            TextField("Region", text: $config.region, prompt: Text(verbatim: "auto"))
            TextField("Nyckel-id", text: $config.accessKeyID)
            SecureField("Hemlig nyckel", text: $secret)
            TextField("Publik adress", text: $config.publicBaseURL, prompt: Text(verbatim: "https://media.exempel.se"))
            TextField("Mapp i hinken", text: $config.prefix)
            HStack {
                Spacer()
                if saved { Text("Sparat").foregroundStyle(.secondary) }
                Button("Spara") {
                    SharingStore.config = config
                    SharingStore.setSecret(secret, account: config.accessKeyID)
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("Den hemliga nyckeln sparas i nyckelringen. Ge nyckeln rätt att skriva i hinken och inget annat.")
                .font(.caption).foregroundStyle(.secondary)
            }
            CloudSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
        .onChange(of: config) { saved = false }
    }
}
