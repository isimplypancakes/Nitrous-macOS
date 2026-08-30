import Foundation

/// Discord IDs are 64-bit ints delivered as strings.
typealias Snowflake = String

extension Snowflake {
    /// The creation date encoded in a Discord snowflake.
    var snowflakeDate: Date? {
        guard let value = UInt64(self) else { return nil }
        let ms = (value >> 22) + 1_420_070_400_000 // Discord epoch
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}

/// ISO8601 timestamp parsing shared across models.
enum DiscordTime {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return formatter.date(from: s) ?? plainFormatter.date(from: s)
    }
}
