import Foundation

/// A Plex Media Server returned from `GET https://plex.tv/api/v2/resources`.
struct PlexServer: Codable, Sendable, Identifiable {
    var id: String { clientIdentifier }

    let name: String
    let clientIdentifier: String
    let product: String?
    let productVersion: String?
    let platform: String?
    let platformVersion: String?
    let provides: String?
    let owned: Bool
    let presence: Bool
    let accessToken: String?
    let sourceTitle: String?
    let connections: [PlexConnection]
    /// The server is set to require secure connections.
    let httpsRequired: Bool?
    /// plex.tv saw this device and the server behind the same public IP when
    /// the server list was fetched, so the device is on the server's network.
    let publicAddressMatches: Bool?

    private init(
        name: String,
        clientIdentifier: String,
        product: String?,
        productVersion: String?,
        platform: String?,
        platformVersion: String?,
        provides: String?,
        owned: Bool,
        presence: Bool,
        accessToken: String?,
        sourceTitle: String?,
        connections: [PlexConnection],
        httpsRequired: Bool?,
        publicAddressMatches: Bool?
    ) {
        self.name = name
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.productVersion = productVersion
        self.platform = platform
        self.platformVersion = platformVersion
        self.provides = provides
        self.owned = owned
        self.presence = presence
        self.accessToken = accessToken
        self.sourceTitle = sourceTitle
        self.connections = connections
        self.httpsRequired = httpsRequired
        self.publicAddressMatches = publicAddressMatches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        clientIdentifier = try container.decode(String.self, forKey: .clientIdentifier)
        provides = try container.decodeIfPresent(String.self, forKey: .provides)
        product = try container.decodeIfPresent(String.self, forKey: .product)
        productVersion = try container.decodeIfPresent(String.self, forKey: .productVersion)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        platformVersion = try container.decodeIfPresent(String.self, forKey: .platformVersion)
        owned = try container.decodeIfPresent(Bool.self, forKey: .owned) ?? false
        presence = try container.decodeIfPresent(Bool.self, forKey: .presence) ?? false
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        connections = try container.decodeIfPresent([PlexConnection].self, forKey: .connections) ?? []
        httpsRequired = (try? container.decodeIfPresent(Bool.self, forKey: .httpsRequired)) ?? nil
        publicAddressMatches = (try? container.decodeIfPresent(Bool.self, forKey: .publicAddressMatches)) ?? nil
    }

    /// Plain HTTP carries the token unencrypted, so it is only allowed on the
    /// server's own network: a private address of a local connection, while
    /// this device shares the server's public IP, and never when the server
    /// requires secure connections.
    func allowsPlainHTTP(to connection: PlexConnection) -> Bool {
        httpsRequired != true
            && publicAddressMatches == true
            && connection.local
            && !connection.relay
            && connection.isPrivateNetworkAddress
    }

    /// Returns connections sorted by preference: local first, then remote, then relay.
    var sortedConnections: [PlexConnection] {
        connections.sorted { lhs, rhs in
            if lhs.sortPriority != rhs.sortPriority {
                return lhs.sortPriority < rhs.sortPriority
            }

            if lhs.isHTTPS != rhs.isHTTPS {
                return lhs.isHTTPS
            }

            return false
        }
    }

    var usableAccessToken: String? {
        accessToken?.nilIfEmpty
    }

    /// Server snapshots live in UserDefaults, while credentials belong only in
    /// Keychain. Older Ithaca versions persisted `accessToken` as part of this
    /// model; bootstrap migrates that token once and rewrites a tokenless copy.
    var withoutAccessToken: PlexServer {
        PlexServer(
            name: name,
            clientIdentifier: clientIdentifier,
            product: product,
            productVersion: productVersion,
            platform: platform,
            platformVersion: platformVersion,
            provides: provides,
            owned: owned,
            presence: presence,
            accessToken: nil,
            sourceTitle: sourceTitle,
            connections: connections,
            httpsRequired: httpsRequired,
            publicAddressMatches: publicAddressMatches
        )
    }
}

/// A single connection endpoint for a Plex server (local, remote, or relay).
struct PlexConnection: Codable, Sendable, Hashable {
    let `protocol`: String
    let address: String
    let port: Int
    let uri: String
    let local: Bool
    let relay: Bool
    let iPv6: Bool?

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case address
        case port
        case uri
        case local
        case relay
        case iPv6 = "IPv6"
    }

    var sortPriority: Int {
        if local && !relay { return 0 }
        if !local && !relay { return 1 }
        return 2
    }

    var isHTTPS: Bool {
        `protocol`.caseInsensitiveCompare("https") == .orderedSame
    }

    private var normalizedAddress: String {
        address
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "-", with: ":")
            .lowercased()
    }

    /// RFC 1918, carrier-grade NAT (Tailscale), loopback and IPv6 unique-local
    /// addresses. Hostnames never count.
    var isPrivateNetworkAddress: Bool {
        LocalNetwork.isPrivateAddress(normalizedAddress)
    }

    var isKnownUnreachableAddress: Bool {
        let normalized = normalizedAddress

        // Docker's default bridge only; other 172.16/12 ranges are real LANs.
        if normalized.hasPrefix("172.17.") {
            return true
        }

        if normalized == "::" || normalized == "0000:0000:0000:0000:0000:0000:0000:0000" {
            return true
        }

        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("fe80::") {
            return true
        }

        return false
    }

    var httpFallbackURI: String? {
        guard isHTTPS else { return nil }

        let host: String
        if address.contains(":") && !address.hasPrefix("[") && !address.hasSuffix("]") {
            host = "[\(address)]"
        } else {
            host = address
        }

        return "http://\(host):\(port)"
    }
}
