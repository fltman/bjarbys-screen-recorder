import SwiftUI
import AppKit
import RecorderKit

/// Texten: redigera filmen genom att stryka ord. Ett klick hoppar dit, ⇧-klick markerar fram
/// till ordet, ⌫ klipper bort det markerade. Bortklippta ord står kvar överstrukna och går att
/// ta tillbaka.
struct TranscriptView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            if model.words.isEmpty {
                empty
            } else {
                text
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Text", systemImage: "text.quote").font(.headline)
            if !model.words.isEmpty {
                Text("\(model.words.count) ord").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let sel = model.wordSelection {
                let anyCut = sel.contains { !model.isWordKept($0) }
                let anyKept = sel.contains { model.isWordKept($0) }
                if anyCut {
                    Button("Ta tillbaka") { model.restoreWords(sel) }
                }
                if anyKept {
                    Button("Klipp bort") { model.cutWords(sel) }
                        .help("Klipp bort de markerade orden ur filmen (⌫)")
                }
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = model.transcribing {
                ProgressView(value: p) { Text("Transkriberar …") }
                Button("Avbryt") { model.cancelTranscription() }.controlSize(.small)
            } else if model.recording.hasMicrophone || model.recording.hasComputerAudio {
                Text("Transkribera inspelningen för att redigera den som text, få undertexter och klippa bort pauser.")
                    .foregroundStyle(.secondary)
                Button("Transkribera") { model.transcribe() }
                    .buttonStyle(.borderedProminent)
                if model.recording.transcript != nil {
                    Text("Inget tal hittades.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Inspelningen har inget ljud.").foregroundStyle(.secondary)
            }
            if let e = model.transcriptionError {
                Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                WhisperFolderButton()
            }
            Spacer()
        }
        .padding(14)
    }

    private var text: some View {
        let paragraphs = Self.paragraphs(model.words)
        let current = model.wordAtPlayhead
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(paragraphs, id: \.lowerBound) { range in
                        VStack(alignment: .leading, spacing: 4) {
                            // Var stycket börjar i filmen; klick hoppar dit.
                            if let t = model.timeMap.output(at: model.words[range.lowerBound].start) {
                                Button { model.seek(toWord: range.lowerBound) } label: {
                                    Text(TransportTime.format(t))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            FlowLayout(spacing: 0, lineSpacing: 3) {
                                ForEach(range, id: \.self) { i in
                                    word(i, current: current == i)
                                }
                            }
                        }
                        .id(range.lowerBound)
                    }
                }
                .padding(14)
            }
            .onChange(of: current) { _, new in
                guard model.isPlaying, let new, let p = paragraphs.first(where: { $0.contains(new) }) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(p.lowerBound, anchor: .center) }
            }
        }
    }

    private func word(_ i: Int, current: Bool) -> some View {
        let w = model.words[i]
        let kept = model.isWordKept(i)
        let selected = model.wordSelection?.contains(i) ?? false
        return Text(w.text + " ")
            .font(.system(size: 14))
            .strikethrough(!kept, color: .secondary)
            .foregroundStyle(kept ? Color.primary : Color.secondary.opacity(0.7))
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(selected ? Color.accentColor.opacity(0.32) : (current ? Color.accentColor.opacity(0.16) : .clear))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.shift), let sel = model.wordSelection {
                    model.wordSelection = min(sel.lowerBound, i)...max(sel.upperBound, i)
                } else {
                    model.wordSelection = i...i
                    model.selectedZoomID = nil
                    model.selectedSegmentID = nil
                    model.seek(toWord: i)
                }
            }
    }

    /// Stycken: ny mening efter en paus på mer än 1,2 s, eller var tionde mening.
    static func paragraphs(_ words: [Transcript.Word]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start = 0, sentences = 0
        for i in words.indices where i > 0 {
            if words[i].startsSegment { sentences += 1 }
            let pause = words[i].start - words[i - 1].end
            if words[i].startsSegment && (pause > 1.2 || sentences >= 10) {
                out.append(start...(i - 1))
                start = i
                sentences = 0
            }
        }
        if !words.isEmpty { out.append(start...(words.count - 1)) }
        return out
    }
}

/// Väljer whisper.cpp-mappen när den inte hittas av sig själv.
struct WhisperFolderButton: View {
    @ObservedObject private var settings = AppModel.shared.settings

    var body: some View {
        Button("Välj whisper.cpp-mappen …") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = String(localized: "Mappen med build/bin/whisper-cli och models/")
            if panel.runModal() == .OK, let url = panel.url { settings.whisperRoot = url.path }
        }
        .controlSize(.small)
    }
}

/// Lägger barnen i rader och bryter när raden är full, som ord i en text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(items: [], y: last.y + last.height + lineSpacing, height: 0))
                x = 0
            }
            rows[rows.count - 1].items.append((i, x))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }
}

/// Tid som "1:05", för stycken och listor.
enum TransportTime {
    static func format(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
