import Foundation

/// An accessibility snapshot can temporarily omit a value while UIKit replaces a screen or rotates it.
/// Absence means "not ready"; a present but invalid payload is a real failure. Never cache a previous snapshot.
public enum NibUITestSnapshot {
    public static func decode<Value: Decodable>(_ value: Any?, as type: Value.Type) throws -> Value? {
        guard let value else { return nil }
        guard let text = value as? String else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: [], debugDescription: "QA state must be a JSON string"))
        }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
