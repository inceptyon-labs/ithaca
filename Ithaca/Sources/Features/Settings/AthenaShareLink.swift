import Foundation
import Observation

/// `ithaca://athena?url=https://…`: an Athena address that a Plex server's
/// owner shares from Athena's Share page, as a link or a QR code. Only HTTPS,
/// since a shared address is reached over the internet, and nothing else in
/// the link: any app or web page can open `ithaca://`.
struct AthenaShareLink: Equatable {
    /// The address as `AthenaClient` normalizes it.
    let address: String
    let host: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "ithaca",
              url.host()?.lowercased() == "athena",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1,
              items[0].name == "url",
              let value = items[0].value,
              value.lowercased().hasPrefix("https://"),
              let client = AthenaClient(address: value),
              let host = client.baseURL.host(percentEncoded: false) else {
            return nil
        }
        address = client.baseURL.absoluteString
        self.host = client.baseURL.port.map { "\(host):\($0)" } ?? host
    }
}

/// Holds a shared Athena link until the viewer says whether to use it. Saving
/// it needs a yes: requests to Athena carry the viewer's token for its Plex
/// server (`AthenaCredentials`), so a link must never point Describe It
/// somewhere unseen. The yes is also the
/// consent Pick Something would otherwise ask for (`AthenaConsent`).
@MainActor @Observable
final class AthenaLinkInbox {
    var pending: AthenaShareLink?

    /// True when the URL was an Athena link, whether or not it was valid.
    func open(_ url: URL) -> Bool {
        guard url.host()?.lowercased() == "athena" else { return false }
        pending = AthenaShareLink(url: url)
        return true
    }

    func accept(_ link: AthenaShareLink, preferences: UserPreferences) {
        preferences.athenaURL = link.address
        preferences.athenaConsent = .allowed
        pending = nil
    }
}
