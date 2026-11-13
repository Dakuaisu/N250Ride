import Foundation
import RideCore

/// Expands shortened map links (maps.app.goo.gl, goo.gl/maps) by following their
/// redirects. Only the final URL is used; no page content is read. HTTPS only,
/// at most five redirects, and every hop must stay on a known map or Google host:
/// credentials, IP literals and other hosts end the expansion.
enum LinkExpander {
    static let maxRedirects = 5
    static let timeout: TimeInterval = 10

    /// Whether a URL may be fetched at all (the first hop or any redirect target).
    static func mayFollow(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty, !isIPLiteral(host) else { return false }
        return MapLinkParser.isShortLinkHost(host) || MapLinkParser.isGoogleHost(host)
            || MapLinkParser.isAppleMapsHost(host)
    }

    static func isIPLiteral(_ host: String) -> Bool {
        host.contains(":") || host.wholeMatch(of: /[0-9.]+/) != nil
    }

    static func expand(_ url: URL) async -> URL? {
        guard mayFollow(url) else { return nil }
        let guardDelegate = RedirectGuard()
        let session = URLSession(configuration: .ephemeral, delegate: guardDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        guard let response = try? await session.data(for: request).1, var final = response.url,
              mayFollow(final) else { return nil }
        if final.host?.hasPrefix("consent.") == true,
           let next = URLComponents(url: final, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "continue" })?.value,
           let continued = URL(string: next), mayFollow(continued) {
            final = continued
        }
        return final
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        let count = lock.withLock {
            redirects += 1
            return redirects
        }
        guard count <= LinkExpander.maxRedirects, let url = request.url, LinkExpander.mayFollow(url) else { return nil }
        return request
    }
}
