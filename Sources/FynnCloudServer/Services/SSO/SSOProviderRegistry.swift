import Vapor

/// Holds the configured SSO identity providers, keyed by their stable `id`.
/// Built once at startup in `configure.swift` and read on the auth paths.
struct SSOProviderRegistry: Sendable {
    private let providers: [String: any IdentityProvider]

    init(_ providers: [any IdentityProvider]) {
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var all: [any IdentityProvider] { Array(providers.values) }

    var isEmpty: Bool { providers.isEmpty }

    func credentialsProvider(id: String) -> (any CredentialsIdentityProvider)? {
        providers[id] as? any CredentialsIdentityProvider
    }

    func redirectProvider(id: String) -> (any RedirectIdentityProvider)? {
        providers[id] as? any RedirectIdentityProvider
    }

    var redirectProviders: [any RedirectIdentityProvider] {
        providers.values.compactMap { $0 as? any RedirectIdentityProvider }
    }
}

extension Application {
    private struct SSOProviderRegistryKey: StorageKey {
        typealias Value = SSOProviderRegistry
    }

    var ssoProviders: SSOProviderRegistry {
        get { storage[SSOProviderRegistryKey.self] ?? SSOProviderRegistry([]) }
        set { storage[SSOProviderRegistryKey.self] = newValue }
    }
}

extension Request {
    var ssoProviders: SSOProviderRegistry { application.ssoProviders }
}
