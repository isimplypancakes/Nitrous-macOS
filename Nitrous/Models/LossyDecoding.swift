import Foundation

/// Element-wise array decoding that skips unparseable entries.
///
/// Discord payloads are large and evolve; a strict `[T]` means one unexpected
/// element discards the entire response. READY in particular carries thousands
/// of objects, so all-or-nothing decoding turns any single schema drift into a
/// total login failure.
extension KeyedDecodingContainer {
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        guard contains(key) else { return nil }
        // Decode as a permissive array of per-element results.
        guard var container = try? nestedUnkeyedContainer(forKey: key) else { return nil }
        var out: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                out.append(value)
            } else {
                // Consume the bad element so the cursor advances.
                _ = try? container.decode(AnySkipped.self)
            }
        }
        return out
    }
}

extension UnkeyedDecodingContainer {
    mutating func decodeLossyRemaining<T: Decodable>(_ type: T.Type) -> [T] {
        var out: [T] = []
        while !isAtEnd {
            if let value = try? decode(T.self) { out.append(value) }
            else { _ = try? decode(AnySkipped.self) }
        }
        return out
    }
}

/// Decodes and discards any JSON value, used to step past elements we reject.
struct AnySkipped: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? JSONValue(from: decoder)
    }
}

/// A top-level lossy array wrapper for use as a property type.
@propertyWrapper
struct Lossy<T: Decodable>: Decodable {
    var wrappedValue: [T]
    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            wrappedValue = container.decodeLossyRemaining(T.self)
        } else {
            wrappedValue = []
        }
    }
    init(wrappedValue: [T]) { self.wrappedValue = wrappedValue }
}
