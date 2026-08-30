import SwiftUI
import AppKit

/// Per-channel peek at the opt-in message logger: every deleted or edited
/// message recorded here, newest first. Data never leaves the device.
struct RecentActivityView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: Channel

    private let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var entries: [MessageLogEntry] { model.messageLog(in: channel.id) }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    List(entries) { entry in
                        entryRow(entry)
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .themedBackground()
            .navigationTitle("Message log · \(model.displayName(for: channel))")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 42)).foregroundStyle(.tertiary)
            Text("Nothing recorded yet")
                .font(.headline)
            Text("Deleted or edited messages in this channel will appear here while the message log is enabled.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding()
    }

    private func entryRow(_ entry: MessageLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(entry.kind == .deleted ? Color.red : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.authorName ?? "Unknown")
                        .font(.subheadline.weight(.semibold))
                    Text(entry.kind.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(entry.kind == .deleted ? Color.red : Color.orange)
                    Spacer()
                    Text(time.string(from: entry.timestamp))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if entry.kind == .edited, let old = entry.editedFrom, !old.isEmpty {
                    Text(old)
                        .font(.callout).foregroundStyle(.secondary)
                        .strikethrough(true, color: .secondary)
                        .lineLimit(3)
                }
                if let content = entry.content, !content.isEmpty {
                    Text(content)
                        .font(.callout)
                        .lineLimit(3)
                }
            }
            Button {
                let parts = entry.content.map { "\($0)" } ??
                    entry.editedFrom.map { "from: \($0)" } ?? "deleted message"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(parts, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.vertical, 4)
        .glassCard(cornerRadius: 12, vertical: 8, horizontal: 10)
    }
}