import Foundation
import Security
import SwiftUI
import AppKit
import RecorderKit

/// YouTube och Dropbox: klient-id i inställningarna (användarens egen app hos tjänsten), nycklarna
/// från inloggningen i nyckelringen. Uppladdningen är alltid något användaren gör med en knapp;
/// YouTube-filmer blir privata.
enum CloudStore {
    enum Service: String, CaseIterable { case youtube, dropbox }

    private static let keychainService = "com.brattoo.skarminspelare.oauth"

    static var youtubeClientID: String {
        get { UserDefaults.standard.string(forKey: "youtubeClientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "youtubeClientID") }
    }
    static var youtubeClientSecret: String {
        get { UserDefaults.standard.string(forKey: "youtubeClientSecret") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "youtubeClientSecret") }
    }
    static var dropboxAppKey: String {
        get { UserDefaults.standard.string(forKey: "dropboxAppKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "dropboxAppKey") }
    }
    static var dropboxFolder: String {
        get { UserDefaults.standard.string(forKey: "dropboxFolder") ?? "/Bjarbys skärminspelare" }
        set { UserDefaults.standard.set(newValue, forKey: "dropboxFolder") }
    }

    static func provider(_ s: Service) -> OAuthProvider {
        switch s {
        case .youtube: .youtube(clientID: youtubeClientID, clientSecret: youtubeClientSecret)
        case .dropbox: .dropbox(appKey: dropboxAppKey)
        }
    }

    // MARK: - Nycklarna i nyckelringen

    static func tokens(_ s: Service) -> OAuthTokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: s.rawValue, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    static func save(_ t: OAuthTokens?, for s: Service) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                   kSecAttrAccount as String: s.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let t, let data = try? JSONEncoder().encode(t) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Bjarbys skärminspelare – \(s == .youtube ? "YouTube" : "Dropbox")"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func isConnected(_ s: Service) -> Bool { tokens(s)?.refreshToken != nil || !(tokens(s)?.isExpired ?? true) }

    /// En giltig åtkomstnyckel (förnyad vid behov).
    static func accessToken(_ s: Service) async throws -> String {
        guard var t = tokens(s) else {
            throw OAuthError.denied(String(localized: "inte ansluten — anslut under Delning …"))
        }
        if t.isExpired, let refresh = t.refreshToken {
            t = try await OAuth.refresh(provider(s), refreshToken: refresh)
            save(t, for: s)
        }
        return t.accessToken
    }

    // MARK: - Uppladdning

    /// Laddar upp till YouTube (privat) och lägger länken i urklipp.
    static func uploadYouTube(_ file: URL, title: String, description: String,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let url = try await YouTubeUploader.upload(file, title: title, description: description,
                                                   accessToken: try await accessToken(.youtube), progress: progress)
        await copy(url)
        return url
    }

    /// Laddar upp till Dropbox och lägger delningslänken i urklipp.
    static func uploadDropbox(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let url = try await DropboxUploader.upload(file, folder: dropboxFolder, accessToken: try await accessToken(.dropbox),
                                                   progress: progress)
        await copy(url)
        return url
    }

    @MainActor private static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// YouTube och Dropbox i Delning …: klient-id, anslut och koppla från.
struct CloudSettingsSection: View {
    @State private var youtubeID = CloudStore.youtubeClientID
    @State private var youtubeSecret = CloudStore.youtubeClientSecret
    @State private var dropboxKey = CloudStore.dropboxAppKey
    @State private var dropboxFolder = CloudStore.dropboxFolder
    @State private var youtubeConnected = CloudStore.isConnected(.youtube)
    @State private var dropboxConnected = CloudStore.isConnected(.dropbox)
    @State private var dropboxVerifier: String?
    @State private var dropboxCode = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section("YouTube") {
            Text("Skapa ett OAuth-klient-id av typen Skrivbordsapp i Google Cloud Console (YouTube Data API v3 påslaget) och klistra in det här. Filmer laddas upp som privata.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Klient-id", text: $youtubeID)
            SecureField("Klienthemlighet", text: $youtubeSecret)
            HStack {
                Text(youtubeConnected ? "Ansluten" : "Inte ansluten").foregroundStyle(youtubeConnected ? .green : .secondary)
                Spacer()
                if youtubeConnected {
                    Button("Koppla från") { CloudStore.save(nil, for: .youtube); youtubeConnected = false }
                }
                Button(youtubeConnected ? "Anslut igen" : "Anslut …") { connectYouTube() }
                    .disabled(youtubeID.isEmpty || working)
            }
        }
        Section("Dropbox") {
            Text("Skapa en app i Dropbox App Console (rättigheterna files.content.write och sharing.write) och klistra in appnyckeln.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Appnyckel", text: $dropboxKey)
            TextField("Mapp", text: $dropboxFolder)
            if dropboxVerifier != nil {
                HStack {
                    TextField("Koden från Dropbox", text: $dropboxCode)
                    Button("Klar") { finishDropbox() }.disabled(dropboxCode.isEmpty || working)
                }
            }
            HStack {
                Text(dropboxConnected ? "Ansluten" : "Inte ansluten").foregroundStyle(dropboxConnected ? .green : .secondary)
                Spacer()
                if dropboxConnected {
                    Button("Koppla från") { CloudStore.save(nil, for: .dropbox); dropboxConnected = false }
                }
                Button(dropboxConnected ? "Anslut igen" : "Anslut …") { startDropbox() }
                    .disabled(dropboxKey.isEmpty || working)
            }
        }
        if let message {
            Text(message).font(.caption).foregroundStyle(.orange)
        }
    }

    private func store() {
        CloudStore.youtubeClientID = youtubeID.trimmingCharacters(in: .whitespacesAndNewlines)
        CloudStore.youtubeClientSecret = youtubeSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        CloudStore.dropboxAppKey = dropboxKey.trimmingCharacters(in: .whitespacesAndNewlines)
        CloudStore.dropboxFolder = dropboxFolder
    }

    private func connectYouTube() {
        store()
        working = true
        message = nil
        Task {
            do {
                let t = try await OAuth.authorizeWithLoopback(CloudStore.provider(.youtube)) { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                CloudStore.save(t, for: .youtube)
                youtubeConnected = true
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }

    private func startDropbox() {
        store()
        let (verifier, challenge) = OAuth.pkce()
        dropboxVerifier = verifier
        dropboxCode = ""
        NSWorkspace.shared.open(OAuth.authorizeURL(CloudStore.provider(.dropbox), challenge: challenge,
                                                   state: UUID().uuidString, redirect: nil))
    }

    private func finishDropbox() {
        guard let verifier = dropboxVerifier else { return }
        working = true
        message = nil
        Task {
            do {
                let t = try await OAuth.exchange(CloudStore.provider(.dropbox), code: dropboxCode.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 verifier: verifier, redirect: nil)
                CloudStore.save(t, for: .dropbox)
                dropboxConnected = true
                dropboxVerifier = nil
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }
}
