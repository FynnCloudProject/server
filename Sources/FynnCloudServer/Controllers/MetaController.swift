import Fluent
import Vapor

/// Public server metadata (`GET /api/info`) consumed by the frontend at boot.
struct MetaController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("api").get("info", use: info)
    }

    func info(req: Request) async throws -> ServerInfo {
        let settings = req.application.settings
        let config = req.application.config

        let appName = try await settings.get(AppSettings.AppName.self)
        let primaryColor = try await settings.get(AppSettings.PrimaryColor.self)
        let euroOfficeURL = (try? await settings.get(AppSettings.DocumentServerURL.self)) ?? ""
        let registrationEnabled = (try? await UserService.isRegistrationAllowed(on: req.db, settings: settings)) ?? false
        let isSetupRequired = ((try? await User.query(on: req.db).count()) ?? 0) == 0

        let ssoProviders = req.ssoProviders.all.map { provider -> SSOProviderInfo in
            let kind: String
            let startPath: String?
            switch provider.kind {
            case .credentials:
                kind = "credentials"
                startPath = nil
            case .redirect:
                kind = "redirect"
                // id is "oidc:<key>"; the start route uses <key>.
                let key = provider.id.split(separator: ":").last.map(String.init) ?? provider.id
                startPath = "/api/auth/oidc/\(key)/start"
            }
            return SSOProviderInfo(
                id: provider.id, kind: kind, displayName: provider.displayName, startPath: startPath)
        }

        let rawLogoUpdatedAt = (try? await settings.get(AppSettings.CustomLogoUpdatedAt.self)) ?? ""
        let logoUpdatedAt = rawLogoUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rawLogoUpdatedAt

        let rawIconUpdatedAt = (try? await settings.get(AppSettings.CustomIconUpdatedAt.self)) ?? ""
        let iconUpdatedAt = rawIconUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rawIconUpdatedAt

        let showLogoAndName = (try? await settings.get(AppSettings.ShowLogoAndName.self)) ?? false
        let svgColorMode = (try? await settings.get(AppSettings.SvgColorMode.self))?.rawValue ?? AppSettings.SvgColorMode.Mode.monochrome.rawValue

        let hostname = ProcessInfo.processInfo.hostName
        let nodeName = Environment.get("NODE_NAME") ?? Environment.get("K8S_NODE_NAME")
        let aiEnabled = (try? await settings.get(AppSettings.AiEnabled.self)) ?? AppSettings.AiEnabled.defaultValue

        return ServerInfo(
            appName: appName,
            version: config.appVersion,
            maxFileSize: Int64(req.application.routes.defaultMaxBodySize.value),
            environment: req.application.environment.name,
            primaryColor: primaryColor,
            officeEnabled: !euroOfficeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            aiEnabled: aiEnabled,
            registrationEnabled: registrationEnabled,
            ssoProviders: ssoProviders,
            isSetupRequired: isSetupRequired,
            logoUpdatedAt: logoUpdatedAt,
            iconUpdatedAt: iconUpdatedAt,
            showLogoAndName: showLogoAndName,
            svgColorMode: svgColorMode,
            hostname: hostname,
            nodeName: nodeName
        )
    }
}
