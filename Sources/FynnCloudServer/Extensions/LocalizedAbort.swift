import Vapor

struct LocalizedAbort: Error, AbortError {
    let abort: Abort
    let localizationKey: String
    let params: [String: String]?

    init(abort: Abort, localizationKey: String, params: [String: String]? = nil) {
        self.abort = abort
        self.localizationKey = localizationKey
        self.params = params
    }

    var status: HTTPResponseStatus { abort.status }
    var reason: String { abort.reason }
    var headers: HTTPHeaders { abort.headers }
}

extension Abort {
    func localized(_ key: String, params: [String: String]? = nil) -> LocalizedAbort {
        return LocalizedAbort(abort: self, localizationKey: key, params: params)
    }
}
