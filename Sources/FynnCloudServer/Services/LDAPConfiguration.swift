import Vapor

public struct LDAPConfiguration: Sendable {
    public let host: String
    public let port: UInt16?
    public let useSSL: Bool
    public let baseDN: String
    public let bindDN: String?
    public let password: String?

    public init(
        host: String,
        port: UInt16? = nil,
        useSSL: Bool = false,
        baseDN: String,
        bindDN: String? = nil,
        password: String? = nil
    ) {
        self.host = host
        self.port = port
        self.useSSL = useSSL
        self.baseDN = baseDN
        self.bindDN = bindDN
        self.password = password
    }
}
