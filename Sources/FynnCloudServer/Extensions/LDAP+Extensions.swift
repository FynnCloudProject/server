import Vapor

extension Application.Services {
    public var ldap: Application.Service<LDAPService> {
        .init(application: application)
    }
}

extension Request.Services {
    public var ldap: LDAPService {
        request.application.services.ldap.service
    }
}
