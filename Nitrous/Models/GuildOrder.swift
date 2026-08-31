import Foundation
import SwiftUI

/// Reads Discord's saved server order out of `user_settings_proto`.
///
/// Modern Discord no longer sends `user_settings.guild_positions`; the sidebar
/// order lives in a protobuf blob. Verified against a live READY, the shape is:
///
///     PreloadedUserSettings {
///       guild_folders = 14 {
///         folders = 1 (repeated) {
///           guild_ids = 1 (packed fixed64)
///         }
///       }
///     }
///
/// Only enough of the wire format to walk to that field is implemented — the
/// rest of the message is skipped generically.
enum GuildOrderProto {

    /// One saved folder: a name, an optional color, and the IDs of the servers
    /// inside it (in their sidebar order).
    struct GuildFolder: Hashable {
        var id: String?
        var name: String?
        var color: Int?
        var guildIds: [Snowflake]

        var colorValue: Color? {
            guard let color, color > 0 else { return nil }
            return Color(red: Double((color >> 16) & 0xFF) / 255,
                         green: Double((color >> 8) & 0xFF) / 255,
                         blue: Double(color & 0xFF) / 255)
        }
    }

    /// Guild IDs in the order Discord has saved for this account.
    static func order(fromBase64 base64: String) -> [Snowflake] {
        folders(fromBase64: base64).flatMap(\.guildIds)
    }

    /// Folder structure, preserving sidebar order across folders. A guild that
    /// isn't inside any returned folder is, by definition, unfiled — so the
    /// rail renders each folder as one capsule and everything else as singles.
    static func folders(fromBase64 base64: String) -> [GuildFolder] {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return [] }
        var reader = Reader(data)
        // Top level: find field 14 (guild_folders).
        guard let folders = reader.findMessage(field: 14) else { return [] }

        var out: [GuildFolder] = []
        var foldersReader = Reader(folders)
        // guild_folders.folders is repeated field 1.
        while let folderBytes = foldersReader.nextMessage(field: 1) {
            var r = Reader(folderBytes)
            var ids: [Snowflake] = []
            var folderID: String?
            var name: String?
            var color: Int?

            while r.index < folderBytes.endIndex {
                guard let key = r.varint() else { break }
                let number = Int(key >> 3), wire = Int(key & 7)
                switch (number, wire) {
                case (1, 2): // guild_ids, packed fixed64
                    guard let length = r.varint().map(Int.init),
                          r.index + length <= folderBytes.endIndex else { break }
                    let packed = folderBytes.subdata(in: r.index..<(r.index + length))
                    r.index += length
                    var p = 0
                    while p + 8 <= packed.count {
                        let value = packed.subdata(in: p..<(p + 8)).withUnsafeBytes {
                            $0.loadUnaligned(as: UInt64.self).littleEndian
                        }
                        ids.append(String(value))
                        p += 8
                    }
                case (1, 1): // guild_ids, un-packed fixed64 (defensive)
                    guard r.index + 8 <= folderBytes.endIndex else { break }
                    let value = folderBytes.subdata(in: r.index..<(r.index + 8)).withUnsafeBytes {
                        $0.loadUnaligned(as: UInt64.self).littleEndian
                    }
                    r.index += 8
                    ids.append(String(value))
                case (2, 0):
                    if let id = r.varint() { folderID = String(id) }
                case (3, 2): // folder name
                    guard let length = r.varint().map(Int.init),
                          r.index + length <= folderBytes.endIndex else { break }
                    name = String(data: folderBytes.subdata(in: r.index..<(r.index + length)),
                                  encoding: .utf8)
                    r.index += length
                case (4, 0): // folder color (24-bit RGB)
                    if let v = r.varint() { color = Int(v & 0xFFFFFF) }
                default:
                    r.skip(wire: wire)
                }
            }
            out.append(GuildFolder(id: folderID, name: name, color: color, guildIds: ids))
        }
        return out
    }

    /// A forward-only protobuf field reader; unknown fields are skipped.
    private struct Reader {
        let data: Data
        var index: Int
        init(_ data: Data) { self.data = data; self.index = data.startIndex }

        mutating func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]; index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        /// Next length-delimited value carrying `field`, skipping anything else.
        mutating func nextMessage(field: Int) -> Data? {
            while index < data.endIndex {
                guard let key = varint() else { return nil }
                let number = Int(key >> 3), wire = Int(key & 7)
                switch wire {
                case 0:
                    guard varint() != nil else { return nil }
                case 1:
                    guard index + 8 <= data.endIndex else { return nil }
                    index += 8
                case 5:
                    guard index + 4 <= data.endIndex else { return nil }
                    index += 4
                case 2:
                    guard let length = varint().map(Int.init),
                          index + length <= data.endIndex else { return nil }
                    let payload = data.subdata(in: index..<(index + length))
                    index += length
                    if number == field { return payload }
                default:
                    return nil
                }
            }
            return nil
        }

        /// First occurrence of a length-delimited `field`, from the current position.
        mutating func findMessage(field: Int) -> Data? { nextMessage(field: field) }

        /// Advance past a field we don't care about so the walk doesn't stall.
        mutating func skip(wire: Int) {
            switch wire {
            case 0: _ = varint()
            case 1: index = min(index + 8, data.endIndex)
            case 5: index = min(index + 4, data.endIndex)
            case 2:
                if let length = varint().map(Int.init) {
                    index = min(index + length, data.endIndex)
                }
            default: index = data.endIndex
            }
        }
    }
}

extension GuildOrderProto.GuildFolder {
    /// Folder members resolved against `AppModel.guilds`, preserving order.
    func guilds(in all: [Guild]) -> [Guild] {
        guildIds.compactMap { id in all.first { $0.id == id } }
    }
}
