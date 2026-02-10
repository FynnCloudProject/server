import SwiftDirector
// Sources/App/Services/LDAPService.swift
import Vapor

public actor LDAPService {
    private let configuration: LDAPConfiguration

    // Store the WRAPPED connection, not the raw one
    private var connectionWrapper: UnsafeLDAPConnection?
    private var connectionTask: Task<Void, any Error>?
    private var server: LDAPServer?

    public init(configuration: LDAPConfiguration) {
        self.configuration = configuration
    }

    public func connect() async throws {
        if let existingTask = connectionTask {
            return try await existingTask.value
        }

        let task = Task {
            do {
                try await self._connect()
            } catch {
                self.connectionTask = nil  // Reset on failure so we can try again
                throw error
            }
        }

        self.connectionTask = task
        try await task.value
    }

    private func _connect() async throws {
        let config = self.configuration

        // Return BOTH connection and server to keep 'server' alive across the boundary
        let (newWrapper, keptServer) = try await Task.detached {
            let server: LDAPServer
            if config.useSSL {
                server = LDAPServer.ldaps(host: config.host, port: config.port ?? 636)
            } else {
                server = LDAPServer.ldap(host: config.host, port: config.port ?? 389)
            }

            let connection = try server.openConnection()

            if let bindDN = config.bindDN, let password = config.password {
                let dn = DistinguishedName(rawValue: bindDN)
                try connection.bind(dn: dn, credentials: password)
            }

            return (UnsafeLDAPConnection(raw: connection), server)
        }.value

        self.connectionWrapper = newWrapper
        self.server = keptServer
    }

    public func disconnect() {
        try? connectionWrapper?.raw.unbind()
        connectionWrapper = nil
    }

    public func search<T: ObjectClassProtocol>(
        for type: T.Type,
        base: String? = nil,
        filter: String? = nil
    ) async throws -> [LDAPObject<T>] {

        guard let wrapper = self.connectionWrapper else {
            try await connect()
            if let newWrapper = self.connectionWrapper {
                return try await performSearch(
                    wrapper: newWrapper, type: type, base: base, filter: filter)
            }
            throw LDAPError.notConnected
        }

        return try await performSearch(wrapper: wrapper, type: type, base: base, filter: filter)
    }

    private func performSearch<T: ObjectClassProtocol>(
        wrapper: UnsafeLDAPConnection,
        type: T.Type,
        base: String?,
        filter: String?
    ) async throws -> [LDAPObject<T>] {

        let searchBase = base ?? configuration.baseDN

        return try await Task.detached {
            return try wrapper.raw.search(for: type, inBase: searchBase, filteredBy: filter)
        }.value
    }
}

public enum LDAPError: Error {
    case notConnected
}

struct UnsafeLDAPConnection: @unchecked Sendable {
    let raw: LDAPConnection
}
