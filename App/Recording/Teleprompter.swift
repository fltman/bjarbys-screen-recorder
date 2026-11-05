import Foundation
import AppKit
import SwiftUI
import RecorderKit

/// Teleprompter: manuset rullar i läshastighet i en ruta högt upp på skärmen, nära kameran,
/// så att blicken hamnar rätt. Appens egna fönster utesluts ur inspelningen, så rutan syns
/// bara för den som spelar in; klick i den loggas inte (de blir inga zoomar).
@MainActor
final class TeleprompterModel: ObservableObject {
    @Published var wpm: Double
    @Published private(set) var isRunning = false
    let text: String
    let fontSize: Double
    /// Rullad tid i sekunder (räknas bara när den rullar).
    private var accumulated: Double = 0
    private var runningSince: Date?
    /// Sekunder innan rullningen börjar, så att första raden hinner läsas.
    static let leadIn = 2.0

    init(text: String, wpm: Double, fontSize: Double) {
        self.text = text; self.wpm = wpm; self.fontSize = fontSize
    }

    func elapsed(at date: Date) -> Double {
        accumulated + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    func start() { guard !isRunning else { return }; runningSince = Date(); isRunning = true }
    func pause() {
        guard isRunning, let since = runningSince else { return }
        accumulated += Date().timeIntervalSince(since)
        runningSince = nil
        isRunning = false
    }
    func toggle() { isRunning ? pause() : start() }
    func restart() { accumulated = 0; runningSince = isRunning ? Date() : nil }
    /// Ändrar hastigheten utan att hoppa: den rullade sträckan behålls.
    func setSpeed(_ new: Double) {
        let now = Date()
        let words = max(0, elapsed(at: now) - Self.leadIn) * wpm / 60
        let clamped = min(260, max(60, new))
        accumulated = Self.leadIn + words / clamped * 60
        if isRunning { runningSince = now }
        wpm = clamped
    }

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

final class TeleprompterPanel: FloatingPanel {
    let model: TeleprompterModel

    init(model: TeleprompterModel, on displayID: CGDirectDisplayID) {
        self.model = model
        let size = CGSize(width: 760, height: 210)
        super.init(size: size, on: displayID) { visible, size in
            // Högt upp i mitten: kameran sitter ovanför skärmen.
            CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 6)
        }
        contentView = NSHostingView(rootView: TeleprompterView(model: model))
    }
}

struct TeleprompterView: View {
    @ObservedObject var model: TeleprompterModel
    private let width: CGFloat = 760 - 48

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                SwiftUI.TimelineView(.animation) { context in
                    let height = textHeight
                    let words = max(1, Double(model.wordCount))
                    let t = max(0, model.elapsed(at: context.date) - TeleprompterModel.leadIn)
                    // Rullar så att ordet som ska läsas nu ligger på läslinjen (en tredjedel ned).
                    let offset = min(height, t * model.wpm / 60 * Double(height) / words)
                    // Hela texten i sin fulla höjd (annars kapar SwiftUI den med "…"), flyttad uppåt.
                    Text(model.text)
                        .font(.system(size: model.fontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .lineSpacing(model.fontSize * 0.25)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: width, alignment: .topLeading)
                        .offset(y: geo.size.height / 3 - offset)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
                .clipped()
                .overlay(alignment: .top) {
                    // Läslinjen.
                    Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                        .offset(y: geo.size.height / 3 + model.fontSize * 1.1)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
            HStack(spacing: 14) {
                Button { model.toggle() } label: { Image(systemName: model.isRunning ? "pause.fill" : "play.fill") }
                Button { model.restart() } label: { Image(systemName: "backward.end.fill") }
                Button { model.setSpeed(model.wpm - 10) } label: { Image(systemName: "tortoise.fill") }
                Text("\(Int(model.wpm)) ord/min").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                Button { model.setSpeed(model.wpm + 10) } label: { Image(systemName: "hare.fill") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(width: 760, height: 210)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.78)))
    }

    /// Hela textens höjd i rutans bredd.
    private var textHeight: CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = model.fontSize * 0.25
        let attributed = NSAttributedString(string: model.text, attributes: [
            .font: NSFont.systemFont(ofSize: model.fontSize, weight: .medium), .paragraphStyle: style])
        return attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    }
}

/// Fönstret där manuset skrivs.
struct ScriptEditorView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Visa manuset under inspelningen", isOn: $settings.teleprompterEnabled)
            TextEditor(text: $settings.teleprompterText)
                .font(.system(size: 15))
                .frame(minHeight: 260)
                .overlay(alignment: .topLeading) {
                    if settings.teleprompterText.isEmpty {
                        Text("Skriv eller klistra in det du ska säga.")
                            .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
            HStack {
                Text("Hastighet")
                Slider(value: $settings.teleprompterWPM, in: 60...260, step: 10)
                Text("\(Int(settings.teleprompterWPM)) ord/min").monospacedDigit().frame(width: 90, alignment: .trailing)
            }
            HStack {
                Text("Textstorlek")
                Slider(value: $settings.teleprompterFontSize, in: 18...44, step: 2)
                Text("\(Int(settings.teleprompterFontSize)) pt").monospacedDigit().frame(width: 90, alignment: .trailing)
            }
            let words = settings.teleprompterText.split(whereSeparator: \.isWhitespace).count
            Text("\(words) ord, ungefär \(Self.duration(Double(words) / settings.teleprompterWPM * 60)). Rutan syns bara för dig: appens egna fönster kommer aldrig med i inspelningen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    static func duration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
