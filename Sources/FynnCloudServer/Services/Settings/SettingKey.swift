import Vapor

/// Type-erased setting key protocol for API iteration and dynamic setting resolution.
public protocol AnySettingKey: Sendable {
    static var key: String { get }
    static var defaultValueString: String { get }
    static var envKey: String? { get }

    /// Validates (and optionally normalizes) a raw string before it is persisted, throwing
    /// `Abort(.badRequest)` if invalid. String-based so it can be called on a type-erased key.
    static func validate(_ raw: String) throws -> String
}

extension AnySettingKey {
    /// Resolves the environment variable override for this setting key, returning nil if unset or empty.
    public static var envValue: String? {
        guard let envKey else { return nil }
        return Environment.get(envKey)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Strongly-typed key protocol for dynamic application settings.
public protocol SettingKey: AnySettingKey {
    associatedtype Value: LosslessStringConvertible & Codable & Sendable
    static var key: String { get }
    static var defaultValue: Value { get }
    static var envKey: String? { get }
}

extension SettingKey {
    public static var defaultValueString: String { String(describing: defaultValue) }

    /// Default validation only requires the raw input to parse into `Value`. Enum and `Bool` values
    /// therefore validate for free (unknown strings fail to parse); freeform `String` values accept
    /// anything. Override for format rules, or conform to `RangedSettingKey` for numeric bounds.
    public static func validate(_ raw: String) throws -> String {
        guard Value(raw) != nil else {
            throw Abort(.badRequest, reason: "Invalid value for setting '\(key)': \(raw)")
        }
        return raw
    }
}

/// A key whose comparable value must fall within optional inclusive bounds. Declare `minValue` /
/// `maxValue` - the bounds-checking validator is provided for free.
public protocol RangedSettingKey: SettingKey where Value: Comparable {
    static var minValue: Value? { get }
    static var maxValue: Value? { get }
}

extension RangedSettingKey {
    public static var minValue: Value? { nil }
    public static var maxValue: Value? { nil }

    public static func validate(_ raw: String) throws -> String {
        guard let parsed = Value(raw) else {
            throw Abort(.badRequest, reason: "Invalid value for setting '\(key)': \(raw)")
        }
        if let minValue, parsed < minValue {
            throw Abort(.badRequest, reason: "Setting '\(key)' must be at least \(minValue).")
        }
        if let maxValue, parsed > maxValue {
            throw Abort(.badRequest, reason: "Setting '\(key)' must be at most \(maxValue).")
        }
        return raw
    }
}
