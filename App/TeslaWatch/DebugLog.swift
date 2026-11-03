import Foundation
import SwiftUI
import TeslaKit
#if os(iOS)
import UIKit
#endif

/// In-app diagnostic log, kept in a file so it survives relaunches. Lines come from `TeslaLog` and the model.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    @Published private(set) var text = ""

    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("debug.log")
    private let maxBytes = 60_000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        TeslaLog.sink = { line in
            Task { @MainActor in DebugLog.shared.add(line) }
        }
    }

    func add(_ line: String) {
        text += "\(formatter.string(from: Date())) \(line)\n"
        if text.utf8.count > maxBytes { text = String(text.suffix(maxBytes / 2)) }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func clear() {
        text = ""
        try? FileManager.default.removeItem(at: url)
    }
}

struct LogView: View {
    @ObservedObject private var log = DebugLog.shared
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(log.text.isEmpty ? "No log yet." : log.text)
                    .font(.system(size: 10, design: .monospaced))
                    #if os(iOS)
                    .textSelection(.enabled)
                    #endif
                #if os(iOS)
                Button {
                    UIPasteboard.general.string = log.text
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy log", systemImage: "doc.on.doc")
                }
                .disabled(log.text.isEmpty)
                #endif
                ShareLink(item: log.text) { Label("Share log", systemImage: "square.and.arrow.up") }
                    .disabled(log.text.isEmpty)
                Button("Clear log", role: .destructive) { log.clear() }
            }
        }
        .navigationTitle("Log")
    }
}
