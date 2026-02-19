import Vapor

struct LDAPLifecycleHandler: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.services.ldap.service.disconnect()
        application.logger.info("LDAP Service disconnected")
    }
}
