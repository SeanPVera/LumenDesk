import Foundation

/// A string-keyed dictionary that decodes each value on its own and drops
/// the ones that fail.
struct LossyDictionary<Value: Decodable>: Decodable {
    let values: [String: Value]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var values: [String: Value] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) { values[key.stringValue] = value }
        }
        self.values = values
    }
}

/// An array that decodes each element on its own and drops the ones that fail.
struct LossyArray<Element: Decodable>: Decodable {
    let values: [Element]

    /// Accepts any JSON value without reading it, so a damaged element is
    /// stepped over. A plain empty struct would only accept objects, and a
    /// failed decode leaves the cursor where it was: the loop would spin.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                values.append(value)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        self.values = values
    }
}
