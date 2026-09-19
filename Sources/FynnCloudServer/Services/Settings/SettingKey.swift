import Foundation
import Vapor

/// Controls the exposure and read masking of dynamic settings.
public enum SettingVisibility: String, Codable, Sendable {
    /// Accessible without authentication (e.g., app name, branding colors, registration status).
    case `public`
    /// Accessible and writable only by authenticated administrators (e.g., retention periods, AI models, URLs).
    case `internal`
    /// Masked/redacted in read APIs (`value: nil`, `isConfigured: true`), safe to write/overwrite via admin UI (e.g., API keys, secrets).
    case secret
}

/// Logical grouping and backend query partition for related settings.
public enum SettingGroup: String, CaseIterable, Codable, Sendable {
    case branding
    case documentEditing
    case access
    case storage
    case sso
    case ai
    case mail
    case rateLimiting
}

/// Type-erased setting key protocol for API iteration and dynamic setting resolution.
public protocol AnySettingKey: Sendable {
    static var key: String { get }
    static var group: SettingGroup { get }
    static var visibility: SettingVisibility { get }
    static var defaultValueString: String { get }
    /// Ordered array of environment variable names checked in precedence order (canonical first, legacy fallbacks next).
    static var envKeys: [String] { get }

    /// Validates (and optionally normalizes) a raw string before it is persisted, throwing
    /// `Abort(.badRequest)` if invalid. String-based so it can be called on a type-erased key.
    static func validate(_ raw: String) throws -> String
}

extension AnySettingKey {
    public static var visibility: SettingVisibility { .internal }
    public static var envKeys: [String] { [] }

    /// Convenience check for whether the setting contains secret/sensitive credentials.
    public static var isSecret: Bool {
        visibility == .secret
    }

    /// Resolves the environment variable override for this setting key.
    /// The first non-empty environment variable found in `envKeys` wins.
    public static var envValue: String? {
        for envKey in envKeys {
            if let val = Environment.get(envKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
        }
        return nil
    }
}

/// Strongly-typed key protocol for dynamic application settings.
public protocol SettingKey: AnySettingKey {
    associatedtype Value: Codable & Sendable
    static var defaultValue: Value { get }
    static func parse(_ raw: String) -> Value?
    static func serialize(_ value: Value) -> String
}

extension SettingKey where Value: LosslessStringConvertible {
    public static func parse(_ raw: String) -> Value? {
        Value(raw)
    }

    public static func serialize(_ value: Value) -> String {
        String(describing: value)
    }
}

extension SettingKey {
    public static var defaultValueString: String {
        serialize(defaultValue)
    }

    /// Default validation checks that the raw string successfully parses into `Value`.
    public static func validate(_ raw: String) throws -> String {
        guard parse(raw) != nil else {
            throw Abort(.badRequest, reason: "Invalid value for setting '\(key)': \(raw)")
        }
        return raw
    }
}

// MARK: - Optional Value Support (Eliminating String Sentinels)

extension SettingKey where Value == Int? {
    public static func parse(_ raw: String) -> Int?? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        guard let val = Int(trimmed) else { return nil }
        return .some(val)
    }

    public static func serialize(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}

extension SettingKey where Value == String? {
    public static func parse(_ raw: String) -> String?? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .some(nil) : .some(trimmed)
    }

    public static func serialize(_ value: String?) -> String {
        value ?? ""
    }
}

extension SettingKey where Value == Date? {
    public static func parse(_ raw: String) -> Date?? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        if let ts = TimeInterval(trimmed) {
            return .some(Date(timeIntervalSince1970: ts))
        }
        if let d = ISO8601DateFormatter().date(from: trimmed) {
            return .some(d)
        }
        return nil
    }

    public static func serialize(_ value: Date?) -> String {
        guard let value else { return "" }
        return String(Int(value.timeIntervalSince1970))
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
        guard let parsed = parse(raw) else {
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
