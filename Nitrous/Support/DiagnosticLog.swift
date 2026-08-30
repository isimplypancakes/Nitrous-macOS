import Foundation
import Combine

/// An on-device log the user can read and send back.
///
/// Connection problems are invisible from the outside — this exists so a
/// failure explains itself instead of showing a spinner forever. Entries
/// persist across launches so a failure can be captured, the app reopened,
/// and the log still be there.
final class DiagnosticLog: ObservableObject {
    static let shared = DiagnosticLog()

    enum Level: String, Codable {
        case info = "INFO", warn = "WARN", error = "ERROR", success = "OK"
        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            case .success: return "checkmark.circle"
            }
        }
    }

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var level: Level
        var category: String
        var message: String

        var line: String {
            "\(Entry.stamp.string(from: date))  [\(level.rawValue)] \(category): \(message)"
        }
        static let stamp: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    @Published private(set) var entries: [Entry] = []

    private let maxEntries = 600
    private let queue = DispatchQueue(label: "diagnostic.log")
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nitrous-diagnostics.json")
    }()

    private init() { load() }

    func log(_ category: String, _ level: Level, _ message: String) {
        let entry = Entry(date: Date(), level: level, category: category, message: message)
        #if DEBUG
        print(entry.line)
        #endif
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            self.persist()
        }
    }

    func clear() {
        entries = []
        persist()
    }

    /// The whole log as text, with a device/app header, ready to paste or share.
    var exportText: String {
        let header = """
        Nitrous diagnostics
        App \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") \
        (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
        iOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Exported \(ISO8601DateFormatter().string(from: Date()))
        ─────────────────────────────
        """
        return ([header] + entries.map(\.line)).joined(separator: "\n")
    }

    private func persist() {
        let snapshot = entries
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = saved
    }
}

/// Terse call sites: `Diag.gateway("connected")`.
enum Diag {
    static func gateway(_ m: String, _ l: DiagnosticLog.Level = .info) {
        DiagnosticLog.shared.log("gateway", l, m)
    }
    static func rest(_ m: String, _ l: DiagnosticLog.Level = .info) {
        DiagnosticLog.shared.log("rest", l, m)
    }
    static func auth(_ m: String, _ l: DiagnosticLog.Level = .info) {
        DiagnosticLog.shared.log("auth", l, m)
    }
    static func app(_ m: String, _ l: DiagnosticLog.Level = .info) {
        DiagnosticLog.shared.log("app", l, m)
    }
}
