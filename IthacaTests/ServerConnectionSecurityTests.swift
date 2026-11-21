import Foundation
import Testing
@testable import Ithaca

/// The Plex token only travels over plain HTTP on the server's own network,
/// only after HTTPS to that address failed, and only to the right server.
@Suite("Server connection security", .serialized)
@MainActor
struct ServerConnectionSecurityTests {
    // MARK: - Candidates

    private func connection(_ scheme: String, _ address: String, port: Int = 32400, local: Bool, uri: String) -> [String: Any] {
        ["protocol": scheme, "address": address, "port": port, "uri": uri, "local": local, "relay": false]
    }

    private func server(
        httpsRequired: Bool = false,
        publicAddressMatches: Bool? = true,
        connections: [[String: Any]]
    ) throws -> PlexServer {
        var json: [String: Any] = [
            "name": "Uranus",
            "clientIdentifier": "test-\(UUID().uuidString)",
            "provides": "server",
            "owned": true,
            "presence": true,
            "httpsRequired": httpsRequired,
            "connections": connections,
        ]
        json["publicAddressMatches"] = publicAddressMatches
        return try JSONDecoder().decode(PlexServer.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private var homeConnections: [[String: Any]] {
        [
            connection("https", "plex.example.com", port: 443, local: false, uri: "https://plex.example.com"),
            connection("https", "192.168.1.10", local: true, uri: "https://192-168-1-10.hash.plex.direct:32400"),
        ]
    }

    private func candidateURLs(_ server: PlexServer) -> [String] {
        ServerPool.connectionCandidates(for: server).map(\.baseURL.absoluteString)
    }

    @Test func remoteConnectionGetsNoPlainHTTPTwin() throws {
        let urls = candidateURLs(try server(connections: homeConnections))
        #expect(urls.contains("http://192.168.1.10:32400"))
        #expect(!urls.contains { $0.hasPrefix("http://plex.example.com") })
    }

    @Test func noPlainHTTPAwayFromTheServersNetwork() throws {
        let away = candidateURLs(try server(publicAddressMatches: false, connections: homeConnections))
        let unknown = candidateURLs(try server(publicAddressMatches: nil, connections: homeConnections))
        #expect(!away.contains { $0.hasPrefix("http://") })
        #expect(!unknown.contains { $0.hasPrefix("http://") })
    }

    @Test func noPlainHTTPWhenTheServerRequiresHTTPS() throws {
        let urls = candidateURLs(try server(httpsRequired: true, connections: homeConnections))
        #expect(!urls.contains { $0.hasPrefix("http://") })
    }

    @Test func plainHTTPRemoteConnectionIsDropped() throws {
        let urls = candidateURLs(try server(connections: [
            connection("http", "203.0.113.5", local: false, uri: "http://203.0.113.5:32400"),
        ]))
        #expect(urls.isEmpty)
    }

    @Test func localConnectionWithAPublicAddressGetsNoPlainHTTPTwin() throws {
        let urls = candidateURLs(try server(connections: [
            connection("https", "203.0.113.5", local: true, uri: "https://203-0-113-5.hash.plex.direct:32400"),
        ]))
        #expect(urls == ["https://203-0-113-5.hash.plex.direct:32400"])
    }

    @Test func plainHTTPHostsStayOnTheLocalNetwork() {
        let local = ["192.168.1.10", "10.0.0.5", "172.20.0.4", "100.101.102.103", "127.0.0.1",
                     "[fd00::1]", "nas.local", "localhost", "seerr"]
        let remote = ["plex.example.com", "203.0.113.5", "172.32.0.1", "8.8.8.8", "[2001:db8::1]", ""]
        for host in local {
            #expect(LocalNetwork.isLocalHost(host), "\(host) should count as local")
        }
        for host in remote {
            #expect(!LocalNetwork.isLocalHost(host), "\(host) should not count as local")
        }
    }

    // MARK: - URL building

    @Test func buildURLEncodesPlusAndKeepsExistingEncodedQuery() {
        let url = PlexService().buildURL(
            base: "https://plex.example.com",
            path: "/hubs/search?genre=a%2Bb",
            queryItems: [
                URLQueryItem(name: "query", value: "Romeo + Juliet"),
                URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: "add(a)+add(b)"),
            ]
        )
        let query = url?.query ?? ""
        #expect(query.contains("genre=a%2Bb"))
        #expect(query.contains("query=Romeo%20%2B%20Juliet"))
        #expect(query.contains("X-Plex-Client-Profile-Extra=add(a)+add(b)"))
    }

    @Test func artworkCacheKeyIsTheSameOnEveryConnection() throws {
        let service = PlexService()
        let uranus = try server(connections: homeConnections)
        let other = try server(connections: homeConnections)
        func posterKey(_ server: PlexServer, at base: String, width: Int = 300) -> URL? {
            service.pool.adopt(server: server, baseURL: URL(string: base)!, token: "secret-token", connection: nil)
            return service.transcodedImageURL(
                for: "/library/metadata/7/thumb/1",
                size: ImageRequestSize(width: width, height: 450),
                serverID: server.clientIdentifier
            ).map(AppImageCache.cacheKey(for:))
        }

        let lan = try #require(posterKey(uranus, at: "http://192.168.1.10:32400"))
        let remote = posterKey(uranus, at: "https://203-0-113-5.hash.plex.direct:32400")
        #expect(lan == remote)
        #expect(lan != posterKey(uranus, at: "http://192.168.1.10:32400", width: 600))
        #expect(lan != posterKey(other, at: "https://198-51-100-7.hash.plex.direct:32400"))
        #expect(!lan.absoluteString.contains("secret-token"))

        let tmdb = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
        #expect(AppImageCache.cacheKey(for: tmdb) == tmdb)
    }

    // MARK: - Identity

    @Test func readsMachineIdentifierFromJSONAndXML() {
        let json = Data(#"{"MediaContainer":{"size":0,"machineIdentifier":"abc123","version":"1.42"}}"#.utf8)
        let xml = Data(#"<MediaContainer size="0" claimed="1" machineIdentifier="abc123" version="1.42"/>"#.utf8)
        #expect(ServerProbe.machineIdentifier(in: json) == "abc123")
        #expect(ServerProbe.machineIdentifier(in: xml) == "abc123")
        #expect(ServerProbe.machineIdentifier(in: Data("nope".utf8)) == nil)
    }

    // MARK: - Probe race

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeStubProtocol.self]
        return URLSession(configuration: configuration)
    }()

    /// Races an HTTPS URI against its plain-HTTP twin for one connection.
    private func race(https httpsHost: String, http httpHost: String) async -> (ConnectionResolution, [ProbeStubProtocol.Request]) {
        let plexConnection = PlexConnection(
            protocol: "https",
            address: "192.168.1.10",
            port: 32400,
            uri: "https://\(httpsHost)",
            local: true,
            relay: false,
            iPv6: nil
        )
        let candidates = ["https://\(httpsHost)", "http://\(httpHost)"].map { base in
            ConnectionCandidate(
                baseURL: URL(string: base)!,
                probeURL: URL(string: base + "/identity")!,
                connection: plexConnection
            )
        }
        let plans = ServerProbe.makePlans(
            candidates: candidates,
            headers: ["Accept": "application/json"],
            token: "secret-token",
            machineIdentifier: ProbeStubProtocol.serverID
        )
        let resolution = await ServerProbe.resolve(plans: plans, serverName: "Uranus", session: Self.session, grace: .milliseconds(50))
        return (resolution, ProbeStubProtocol.requests(to: [httpsHost, httpHost]))
    }

    @Test func workingHTTPSMeansTheTokenNeverGoesOverHTTP() async {
        let (resolution, requests) = await race(https: "ok-1.test", http: "ok-1-plain.test")
        guard case let .connected(url, _) = resolution else {
            Issue.record("Expected a connection, got \(resolution)")
            return
        }
        #expect(url.scheme == "https")
        #expect(!requests.contains { $0.host == "ok-1-plain.test" && $0.hasToken })
        #expect(!requests.contains { $0.path == "/identity" && $0.hasToken })
    }

    @Test func failedHTTPSFallsBackToHTTPAfterConfirmingTheServer() async {
        let (resolution, requests) = await race(https: "down-2.test", http: "ok-2.test")
        guard case let .connected(url, _) = resolution else {
            Issue.record("Expected a connection, got \(resolution)")
            return
        }
        #expect(url.scheme == "http")
        let plain = requests.filter { $0.host == "ok-2.test" }
        #expect(plain.first { $0.path == "/identity" }?.hasToken == false)
        #expect(plain.first { $0.path == "/library/sections" }?.hasToken == true)
    }

    @Test func aDifferentServerOverHTTPNeverReceivesTheToken() async {
        let (resolution, requests) = await race(https: "down-3.test", http: "imposter-3.test")
        guard case .failed = resolution else {
            Issue.record("Expected a failure, got \(resolution)")
            return
        }
        #expect(requests.contains { $0.host == "imposter-3.test" && $0.path == "/identity" })
        #expect(!requests.contains { $0.host == "imposter-3.test" && $0.hasToken })
    }

    @Test func lanOverHTTPBeatsRemoteWhenLocalHTTPSHangs() async {
        let lan = PlexConnection(
            protocol: "https", address: "192.168.1.10", port: 32400,
            uri: "https://hang-4.test", local: true, relay: false, iPv6: nil
        )
        let remote = PlexConnection(
            protocol: "https", address: "plex.example.com", port: 443,
            uri: "https://ok-4-remote.test", local: false, relay: false, iPv6: nil
        )
        let candidates = [
            ("https://hang-4.test", lan), ("http://ok-4.test", lan), ("https://ok-4-remote.test", remote),
        ].map { base, connection in
            ConnectionCandidate(baseURL: URL(string: base)!, probeURL: URL(string: base + "/identity")!, connection: connection)
        }
        let plans = ServerProbe.makePlans(
            candidates: candidates,
            headers: ["Accept": "application/json"],
            token: "secret-token",
            machineIdentifier: ProbeStubProtocol.serverID
        )
        let resolution = await ServerProbe.resolve(
            plans: plans,
            serverName: "Uranus",
            session: Self.session,
            grace: .milliseconds(600),
            headStart: .milliseconds(100)
        )
        guard case let .connected(url, _) = resolution else {
            Issue.record("Expected a connection, got \(resolution)")
            return
        }
        #expect(url.absoluteString == "http://ok-4.test")
    }
}

/// Answers probe requests by host name: `down-*` refuses the connection,
/// `hang-*` never answers, `imposter-*` reports another server, anything else
/// is the expected server.
/// `/library/sections` accepts any request that carries a token.
final class ProbeStubProtocol: URLProtocol {
    struct Request: Sendable {
        let host: String
        let path: String
        let hasToken: Bool
    }

    static let serverID = "server-a"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [Request] = []

    static func requests(to hosts: Set<String>) -> [Request] {
        lock.withLock { log.filter { hosts.contains($0.host) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let hasToken = request.value(forHTTPHeaderField: "X-Plex-Token") != nil
        Self.lock.withLock { Self.log.append(Request(host: host, path: url.path, hasToken: hasToken)) }

        if host.hasPrefix("hang") {
            return
        }
        if host.hasPrefix("down") {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let status: Int
        let body: Data
        if url.path == "/identity" {
            let identifier = host.hasPrefix("imposter") ? "someone-else" : Self.serverID
            status = 200
            body = Data(#"{"MediaContainer":{"machineIdentifier":"\#(identifier)"}}"#.utf8)
        } else {
            status = hasToken ? 200 : 401
            body = Data()
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
