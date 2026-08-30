import Foundation

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

    /// Guild IDs in the order Discord has saved for this account.
    static func order(fromBase64 base64: String) -> [Snowflake] {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return [] }
        var reader = Reader(data)
        // Top level: find field 14 (guild_folders).
        guard let folders = reader.findMessage(field: 14) else { return [] }

        var ids: [Snowflake] = []
        var foldersReader = Reader(folders)
        // guild_folders.folders is repeated field 1.
        while let folder = foldersReader.nextMessage(field: 1) {
            var folderReader = Reader(folder)
            // folder.guild_ids is packed fixed64 in field 1.
            while let packed = folderReader.nextMessage(field: 1) {
                var p = 0
                while p + 8 <= packed.count {
                    let value = packed.subdata(in: p..<(p + 8)).withUnsafeBytes {
                        $0.loadUnaligned(as: UInt64.self).littleEndian
                    }
                    ids.append(String(value))
                    p += 8
                }
            }
        }
        return ids
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
    }
}
