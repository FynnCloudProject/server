import Vapor

struct LocalizedAbort: Error, AbortError {
    let abort: Abort
    let localizationKey: String

    var status: HTTPResponseStatus { abort.status }
    var reason: String { abort.reason }
    var headers: HTTPHeaders { abort.headers }
}

extension Abort {
    func localized(_ key: String) -> LocalizedAbort {
        return LocalizedAbort(abort: self, localizationKey: key)
    }
}
