import SwiftUI
import AppKit

/// Readable, shareable connection log. This is the screen to open when
/// something won't connect — and the one to share when reporting it.
struct DiagnosticsView: View {
    @ObservedObject private var log = DiagnosticLog.shared
    @State private var filter: String? = nil
    @State private var copied = false

    private var categories: [String] {
        Array(Set(log.entries.map(\.category))).sorted()
    }
    private var shown: [DiagnosticLog.Entry] {
        guard let filter else { return log.entries.reversed() }
        return log.entries.filter { $0.category == filter }.reversed()
    }

    var body: some View {
        List {
            if log.entries.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "text.alignleft",
                    description: Text("Connection activity will appear here."))
            } else {
                Section {
                    Picker("Filter", selection: $filter) {
                        Text("All").tag(String?.none)
                        ForEach(categories, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(shown) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.level.symbol)
                                .foregroundStyle(color(for: entry.level))
                                .font(.footnote)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(entry.level == .error ? Color.red : Color.primary)
                                Text("\(DiagnosticLog.Entry.stamp.string(from: entry.date))  ·  \(entry.category)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                } footer: {
                    Text("Newest first. Kept across restarts, up to 600 entries.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.exportText, forType: .string)
                        copied = true
                    } label: { Label("Copy Log", systemImage: "doc.on.doc") }
                    ShareLink(item: log.exportText) {
                        Label("Share Log", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) { log.clear() } label: { Label("Clear", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Copied", isPresented: $copied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The log is on your clipboard.")
        }
    }

    private func color(for level: DiagnosticLog.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}
