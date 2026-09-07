import Vapor

/// Wrapper for application settings returned in administrative responses,
/// containing the resolved value and metadata indicating whether the setting
/// is controlled by an environment variable.
public struct ManagedSetting<T: Codable & Sendable>: Content, Sendable {
    public let value: T
    public let isManagedByEnv: Bool

    public init(value: T, isManagedByEnv: Bool) {
        self.value = value
        self.isManagedByEnv = isManagedByEnv
    }
}
