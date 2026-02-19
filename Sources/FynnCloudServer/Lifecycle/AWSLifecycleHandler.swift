import Vapor

struct AWSLifecycleHandler: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        try? await application.services.awsClient.service.shutdown()
    }
}
