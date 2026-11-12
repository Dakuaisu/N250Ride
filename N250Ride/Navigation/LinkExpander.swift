import Foundation

/// Expands shortened map links (maps.app.goo.gl, goo.gl/maps) by following their
/// redirects. Only the final URL is used; no page content is read.
enum LinkExpander {
    static func expand(_ url: URL) async -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        guard let response = try? await URLSession.shared.data(for: request).1,
              var final = response.url else { return nil }
        if final.host?.hasPrefix("consent.") == true,
           let next = URLComponents(url: final, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "continue" })?.value,
           let continued = URL(string: next) {
            final = continued
        }
        return final
    }
}
