import Foundation

/// Finds the services that run beside Plex, Athena and Seerr, on the
/// home-network addresses of the Plex servers this device reaches, so a new
/// device needs no address typed in. A typed address always wins.
enum HomeServerFinder {
    static let athenaPort = 8800
    /// Seerr's default, and the next one up, which it takes beside an old
    /// Overseerr.
    static let seerrPorts = [5055, 5056]

    /// The LAN addresses of the connected servers, highest priority first.
    /// Servers reached from outside are skipped: away from home, those
    /// addresses belong to whatever network the device is on. A restored
    /// session that doesn't know yet is tried; Athena and Seerr each have to
    /// say what they are.
    @MainActor
    static func hosts(plexService: PlexService) -> [String] {
        var hosts: [String] = []
        for session in plexService.pool.connections where !session.isRemote {
            let listed = plexService.pool.server(for: session.serverID)?.connections
                .filter { $0.local && !$0.relay }
                .map(\.address) ?? []
            // IPv6 addresses would need brackets in a URL; Plex lists IPv4 too.
            for address in [session.connection?.address].compactMap({ $0 }) + listed
            where !address.isEmpty && !address.contains(":") && !hosts.contains(address) {
                hosts.append(address)
            }
        }
        return hosts
    }

    /// Athena's address ("192.168.1.10:8800") on the first host where it
    /// answers.
    static func findAthena(hosts: [String]) async -> String? {
        let addresses = hosts.map { "\($0):\(athenaPort)" }
        let answers = await RecommendationGenreScoring.concurrentMap(addresses) { address in
            guard let url = URL(string: "http://\(address)/healthz"),
                  let health = await fetch(AthenaHealth.self, from: url) else { return false }
            return health.service == "athena" || health.service == "mentor"
        }
        return zip(addresses, answers).first { $0.1 }?.0
    }

    /// The first host and port where a Seerr that signs in with Plex answers.
    static func findSeerr(hosts: [String]) async -> URL? {
        let urls = hosts.flatMap { host in seerrPorts.compactMap { URL(string: "http://\(host):\($0)") } }
        let answers = await RecommendationGenreScoring.concurrentMap(urls) { url in
            guard let settings = await fetch(
                SeerrPublicSettings.self,
                from: url.appending(path: "api/v1/settings/public")
            ) else { return false }
            return settings.initialized && settings.isPlexServer && settings.mediaServerLogin
        }
        return zip(urls, answers).first { $0.1 }?.0
    }

    /// Short timeouts: a missing service is the common answer, and nothing
    /// waits on it.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private static func fetch<Value: Decodable>(_ type: Value.Type, from url: URL) async -> Value? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
