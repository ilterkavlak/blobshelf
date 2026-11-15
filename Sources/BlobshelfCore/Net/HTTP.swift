import Foundation

/// Every request goes through one session that keeps nothing on disk (no cache, cookies or
/// credentials) and refuses redirects, so a token or signed request is never carried to another host.
enum HTTP {
    static let session = makeSession()

    static func makeSession(configure: (URLSessionConfiguration) -> Void = { _ in }) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        configure(config)
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
