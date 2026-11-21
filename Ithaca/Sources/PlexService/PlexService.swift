import Foundation
import OSLog

let plexAuthLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Ithaca",
    category: "PlexAuth"
)

@MainActor
@Observable
final class PlexService {
    /// Durable credential created by the normal Plex sign-in flow. This token
    /// belongs to the linked full account and is the only credential allowed to
    /// enumerate or switch Plex Home members.
    var primaryAccountToken: String?
    /// Credential used for account-scoped API calls in the current session.
    /// It equals `primaryAccountToken` outside Plex Home and becomes the token
    /// returned by the Home switch endpoint for another member.
    var activeAccountToken: String?
    var authTokenUpdatedAt: Date?
    var currentUser: PlexUser?
    /// Cached account entitlement: nil = unknown/not fetched, true/false = known.
    /// Drives the remote-streaming (Plex Pass) restriction check.
    var accountSubscriptionActive: Bool?
    var homeUsers: [PlexHomeUser] = []
    var activeHomeUser: PlexHomeUser?
    var homeBootstrapCompleted = false
    /// True while the session runs on the offline fallback of
    /// `bootstrapHomeSession()` because plex.tv did not answer. The shell
    /// re-runs the bootstrap until it succeeds.
    var homeBootstrapNeedsRevalidation = false
    /// Bumped whenever the Home session is reset (sign-out, account change), so
    /// a bootstrap still awaiting plex.tv can tell its result is stale.
    @ObservationIgnored var homeSessionGeneration = 0
    /// Receives the watch state of every item a live metadata fetch returns,
    /// with the time the request was sent (see `OfflinePlaybackSyncManager`).
    @ObservationIgnored var watchStateObserver: (@MainActor ([PlexWatchStateReport], Date) -> Void)?
    /// Runs at the start of `signOut()`, while the outgoing account is still
    /// the active profile (see `DownloadManager`).
    @ObservationIgnored var willSignOut: (@MainActor () -> Void)?
    /// Recent metadata answers, so a detail page opened again draws at once
    /// while it revalidates. See `recentMediaDetails(for:)`.
    @ObservationIgnored var mediaDetailsCache = RecentMetadataCache<PlexMediaDetails>()
    @ObservationIgnored var seasonsCache = RecentMetadataCache<[PlexSeason]>()
    @ObservationIgnored var episodesCache = RecentMetadataCache<[PlexEpisode]>()
    /// Bumped by every rating this app writes (`setRatingAcrossServers`), so
    /// recommendations rebuild from the new taste.
    var tasteRevision = 0
    var homeSelectionRequested = false
    var primaryProfileID: String?
    var hasRememberedHomeUserToken = false

    /// Compatibility name for the account token used by existing service code.
    /// New account operations should choose `primaryAccountToken` or
    /// `activeAccountToken` explicitly.
    var authToken: String? { activeAccountToken }

    var isAuthenticated: Bool { primaryAccountToken != nil }
    var hasPlexHome: Bool { homeUsers.count > 1 }
    var activeProfileID: String? {
        if needsHomeUserSelection, activeHomeUser == nil {
            return nil
        }
        return activeHomeUser?.stableProfileID
            ?? currentUser?.uuid?.nilIfEmpty
            ?? (activeAccountToken == primaryAccountToken ? primaryProfileID : nil)
    }
    var needsHomeUserSelection: Bool {
        homeBootstrapCompleted && hasPlexHome && homeSelectionRequested
    }
    var isSessionReady: Bool {
        isAuthenticated
            && homeBootstrapCompleted
            && activeProfileID != nil
            && !needsHomeUserSelection
    }
    var shouldAdoptLegacyProfileData: Bool {
        homeBootstrapCompleted
            && primaryProfileID != nil
            && activeAccountToken == primaryAccountToken
            && (activeHomeUser == nil || activeHomeUser?.stableProfileID == primaryProfileID)
    }
    var automaticHomeSignIn = true {
        didSet {
            automaticHomeSignInDidChange()
        }
    }

    /// Cached account library order (plex.tv `experience` setting) plus the
    /// connected server's sections. See `PlexService+LibraryOrder`.
    let libraryOrder = LibraryOrderStore()

    /// Every server this account can use and the live session with each one.
    /// Everything that talks to a server resolves through here.
    let pool = ServerPool()

    /// The user's server order and per-server on/off switch.
    let serverPriority = ServerPriorityStore()

    /// Which items on different servers are the same content. Filled by the
    /// merge layers, read by playback to fall back to another server.
    let alternates = ContentAlternatesIndex()

    /// Per-server recovery bookkeeping. Owned by `PlexService+Servers`
    /// (`recoverServer(serverID:)`) — nothing else may touch these.
    @ObservationIgnored var serverRecoveryTasks: [String: Task<PlexServerConnection, Error>] = [:]
    @ObservationIgnored var serverRecoveryCooldowns: [String: Date] = [:]

    let clientIdentifier: String
    let session: URLSession
    /// Scrub previews and images from outside Plex. A separate session has its
    /// own connection pool, so a backlog of downloads never queues the
    /// metadata request for the title the user just selected.
    let imageSession: URLSession
    /// Plex server artwork, likewise on its own connection pool. It has no URL
    /// cache: each response is stored under `AppImageCache.cacheKey(for:)`,
    /// which does not depend on the connection, rather than under the URL.
    let artworkSession: URLSession
    /// plex.tv requests that set their own short timeout. The main session
    /// waits for connectivity, which overrides a request timeout entirely: an
    /// offline launch sat on the Home bootstrap spinner for the 30 s resource
    /// timeout before the offline fallback could run.
    let failFastSession: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    static var plexTVBase: String {
        #if DEBUG
        if let override = ScreenshotMode.plexTVBase { return override }
        #endif
        return "https://plex.tv"
    }
    /// Kept at the legacy name so existing users' linked-account credential
    /// migrates without requiring another sign-in.
    static let keychainTokenKey = "PlexAuthToken"
    static let keychainActiveHomeTokenKey = "PlexActiveHomeUserToken"
    static let defaultsClientIDKey = "PlexClientIdentifier"
    // The four keys below are the single-server layout. Nothing writes them any
    // more: they are read once by `migrateLegacySingleServerState()` and then
    // deleted, and `ServerPool` reuses their names as the prefix of its
    // per-server keys ("PlexServerURL.<id>", …) so an install keeps one
    // recognisable namespace.
    static let keychainServerTokenKey = "PlexServerAuthToken"
    static let defaultsServerURLKey = "PlexServerURL"
    static let defaultsServerDataKey = "PlexServerData"
    static let defaultsLastGoodConnectionURIKey = "PlexLastGoodConnectionURI"
    /// Legacy selection, still read by `ServerPriorityStore` to seed the first
    /// priority order. Only sign-out removes it.
    static let defaultsServerIDKey = "PlexServerID"
    static let defaultsActiveHomeUserDataKey = "PlexActiveHomeUserData"
    static let defaultsAutomaticHomeSignInKey = "PlexAutomaticallySignInHomeUser"
    static let defaultsHomeMigrationCompletedKey = "PlexHomeMigrationCompleted"
    static let defaultsPrimaryProfileIDKey = "PlexPrimaryProfileID"
    /// Size of the Plex Home the last successful bootstrap saw. It lets a cold
    /// launch with plex.tv unreachable tell a single-user account (safe to
    /// restore) from a multi-user Home (needs the remembered member).
    static let defaultsLastVerifiedHomeUserCountKey = "PlexLastVerifiedHomeUserCount"
    /// How long requests to a server keep failing fast after its recovery
    /// failed. Long enough that a screenful of requests cannot re-run discovery
    /// over and over, short enough that a server coming back is picked up on the
    /// next screen refresh.
    static let serverRecoveryCooldown: TimeInterval = 30
    /// The Home bootstrap gates the whole shell, so it gives up on plex.tv
    /// sooner than the session's 15s default and lets the offline fallback run.
    static let homeBootstrapTimeout: TimeInterval = 8
    static let authenticationPropagationRetryWindow: TimeInterval = 20
    static let authenticationPropagationRetryAttempts = 20

    init() {
        let config = URLSessionConfiguration.default
        // API requests always reload; without a cache their JSON no longer
        // takes space in the image disk cache.
        config.urlCache = nil
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)

        let imageConfig = URLSessionConfiguration.default
        imageConfig.urlCache = AppImageCache.shared
        imageConfig.waitsForConnectivity = true
        imageConfig.timeoutIntervalForRequest = 15
        imageConfig.timeoutIntervalForResource = 30
        self.imageSession = URLSession(configuration: imageConfig)

        let artworkConfig = URLSessionConfiguration.default
        artworkConfig.urlCache = nil
        artworkConfig.waitsForConnectivity = true
        artworkConfig.timeoutIntervalForRequest = 15
        artworkConfig.timeoutIntervalForResource = 30
        self.artworkSession = URLSession(configuration: artworkConfig)

        let failFastConfig = URLSessionConfiguration.default
        failFastConfig.urlCache = nil
        failFastConfig.waitsForConnectivity = false
        failFastConfig.timeoutIntervalForRequest = 15
        failFastConfig.timeoutIntervalForResource = 30
        self.failFastSession = URLSession(configuration: failFastConfig)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()

        if let stored = UserDefaults.standard.string(forKey: Self.defaultsClientIDKey) {
            clientIdentifier = stored
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: Self.defaultsClientIDKey)
            clientIdentifier = id
        }

        KeychainHelper.migrateAccessibilityIfNeeded()
        if let data = KeychainHelper.load(key: Self.keychainTokenKey),
           let token = String(data: data, encoding: .utf8) {
            primaryAccountToken = token.nilIfEmpty
        }
        #if DEBUG
        // Screenshot mode signs in to the mock server's demo account and never
        // touches a real Plex sign-in stored in the Keychain.
        if ScreenshotMode.isActive {
            primaryAccountToken = ScreenshotMode.accountToken
        }
        #endif

        if let profileData = UserDefaults.standard.data(forKey: Self.defaultsActiveHomeUserDataKey),
           let profile = try? decoder.decode(PlexHomeUser.self, from: profileData) {
            activeHomeUser = profile
        }

        let shouldAutomaticallySignIn: Bool
        if UserDefaults.standard.object(forKey: Self.defaultsAutomaticHomeSignInKey) == nil {
            shouldAutomaticallySignIn = true
        } else {
            shouldAutomaticallySignIn = UserDefaults.standard.bool(
                forKey: Self.defaultsAutomaticHomeSignInKey
            )
        }
        automaticHomeSignIn = shouldAutomaticallySignIn

        primaryProfileID = UserDefaults.standard
            .string(forKey: Self.defaultsPrimaryProfileIDKey)?
            .nilIfEmpty

        if shouldAutomaticallySignIn,
           activeHomeUser != nil,
           let data = KeychainHelper.load(key: Self.keychainActiveHomeTokenKey),
           let token = String(data: data, encoding: .utf8)?.nilIfEmpty {
            activeAccountToken = token
            hasRememberedHomeUserToken = true
        } else {
            activeAccountToken = primaryAccountToken
        }

        pool.configure(session: session, baseHeaders: plexRequestHeaders)
        migrateLegacySingleServerState()
        restorePersistedSessions()
    }

    /// Seeds the pool from the sessions persisted by the previous launch, so a
    /// cold start already has every enabled server usable before plex.tv
    /// discovery answers. `ServerConnectionCoordinator`'s pass then verifies and
    /// refreshes them; a restored endpoint that has since moved simply fails
    /// over on its next request.
    private func restorePersistedSessions() {
        for server in ServerPool.storedSnapshots()
        where !server.clientIdentifier.isEmpty && serverPriority.isEnabled(server.clientIdentifier) {
            let serverID = server.clientIdentifier
            guard let token = ServerPool.storedToken(serverID: serverID) else { continue }
            // The remembered base URL is the exact endpoint that worked; the
            // last-good connection URI is the fallback for installs that
            // upgraded before base URLs were kept per server.
            guard let baseURL = ServerPool.storedBaseURL(serverID: serverID)
                    ?? ServerPool.lastGoodConnectionURI(serverID: serverID)
                    .flatMap(URL.init(string:)) else { continue }
            // A plain-HTTP endpoint is never adopted blind, and not probed
            // here either: the snapshot's `publicAddressMatches` is from an
            // earlier launch, maybe on another network. Discovery decides;
            // `connectRememberedServersWithoutPlexTV` covers a LAN-only launch.
            guard baseURL.scheme?.lowercased() != "http" else { continue }

            pool.adopt(
                server: server,
                baseURL: baseURL,
                token: token,
                connection: Self.connection(in: server, matching: baseURL),
                priority: serverPriority
            )
        }
    }

    /// Probes, without plex.tv, every enabled server, connected or not: the
    /// cached snapshot's connections (with their plain-HTTP twins) plus a
    /// remembered plain-HTTP endpoint, and the server must confirm its identity
    /// before the token is sent over HTTP. A "connected" session can be a
    /// plex.direct endpoint that needs internet DNS, so on a LAN-only network
    /// the HTTP twin is what connects; a session that still works wins the
    /// race again and nothing changes. Only for when plex.tv can't be reached;
    /// otherwise discovery decides, because the snapshot's
    /// `publicAddressMatches` describes the network of an earlier session.
    func connectRememberedServersWithoutPlexTV() async {
        var probes: [Task<Void, Never>] = []
        for server in ServerPool.storedSnapshots()
        where !server.clientIdentifier.isEmpty && serverPriority.isEnabled(server.clientIdentifier) {
            let serverID = server.clientIdentifier
            guard ServerPool.storedToken(serverID: serverID) != nil,
                  let baseURL = ServerPool.storedBaseURL(serverID: serverID)
                    ?? ServerPool.lastGoodConnectionURI(serverID: serverID).flatMap(URL.init(string:)) else { continue }
            probes.append(Task { [pool, serverPriority] in
                await pool.connectRestored(server, rememberedURL: baseURL, priority: serverPriority)
            })
        }
        for probe in probes {
            await probe.value
        }
    }

    /// Moves the pre-multi-server session (`PlexServerURL`, `PlexServerData`,
    /// `PlexLastGoodConnectionURI`, Keychain `PlexServerAuthToken`) onto the
    /// per-server keys and retires the originals. Nothing writes them any more,
    /// so this is a one-time upgrade step; `PlexServerID` is deliberately left
    /// in place because `ServerPriorityStore` still seeds its order from it.
    private func migrateLegacySingleServerState() {
        let defaults = UserDefaults.standard
        let legacyToken = KeychainHelper.load(key: Self.keychainServerTokenKey)
            .flatMap { String(data: $0, encoding: .utf8) }?
            .nilIfEmpty
        let legacyLastGoodURI = defaults
            .string(forKey: Self.defaultsLastGoodConnectionURIKey)?
            .nilIfEmpty
        let legacyBaseURL = defaults
            .string(forKey: Self.defaultsServerURLKey)
            .flatMap(URL.init(string:))
        let legacyServer = defaults
            .data(forKey: Self.defaultsServerDataKey)
            .flatMap { try? decoder.decode(PlexServer.self, from: $0) }

        if let legacyServer, !legacyServer.clientIdentifier.isEmpty {
            ServerPool.migrateLegacyState(
                serverID: legacyServer.clientIdentifier,
                // Older releases persisted the server token inside the snapshot.
                token: legacyToken ?? legacyServer.usableAccessToken,
                lastGoodURI: legacyLastGoodURI,
                baseURL: legacyBaseURL,
                snapshot: legacyServer.withoutAccessToken
            )
        }

        defaults.removeObject(forKey: Self.defaultsServerURLKey)
        defaults.removeObject(forKey: Self.defaultsServerDataKey)
        defaults.removeObject(forKey: Self.defaultsLastGoodConnectionURIKey)
        KeychainHelper.delete(key: Self.keychainServerTokenKey)
    }

    /// Matches a restored base URL back onto the stored server's connection
    /// list by host, so a session restored without a probe still knows whether
    /// it is local, remote, or relayed.
    private static func connection(in server: PlexServer, matching baseURL: URL) -> PlexConnection? {
        guard let host = baseURL.host else { return nil }
        return server.connections.first { connection in
            for uri in [connection.uri, connection.httpFallbackURI].compactMap({ $0 }) {
                guard let url = URL(string: uri), url.host == host else { continue }
                if let basePort = baseURL.port, let connectionPort = url.port, basePort != connectionPort {
                    continue
                }
                return true
            }
            return false
        }
    }

    // MARK: - Teardown

    /// Tears down *every* server session. Sign-out and Plex Home switches only:
    /// a single failing request must never clear the pool, because that would
    /// sign the user out of the servers that are working fine.
    ///
    /// - Parameter forgetServers: Sign-out. Also drops the stored priority order
    ///   and every per-server credential and remembered endpoint, including
    ///   those of servers that never connected this launch.
    func tearDownServerSessions(forgetServers: Bool = false) {
        libraryOrder.invalidate()
        // Rating keys only mean something for the account that fetched them.
        alternates.reset()
        for task in serverRecoveryTasks.values {
            task.cancel()
        }
        serverRecoveryTasks = [:]
        serverRecoveryCooldowns = [:]
        // Server tokens belong to the identity that fetched them, so a Home
        // switch invalidates every one of them just as a sign-out does — and the
        // pool only knows the servers it has seen this launch, so the stored
        // order and snapshots have to be swept too.
        let known = Set(serverPriority.entries.map(\.machineIdentifier))
            .union(ServerPool.storedSnapshots().map(\.clientIdentifier))
            .union(pool.knownServerIDs)
        for serverID in known {
            ServerPool.forget(serverID: serverID)
        }
        pool.clear()
        // Siri's titles belong to this identity's libraries too.
        SiriTitleCatalog.shared.clear()
        // So does what detail pages draw before their metadata arrives.
        invalidateRecentMetadata()
        DetailSeeds.removeAll()
        #if os(tvOS)
        // The Top Shelf mirrors this identity's Continue Watching.
        TopShelfPublisher.shared.clear()
        #endif
        if forgetServers {
            UserDefaults.standard.removeObject(forKey: Self.defaultsServerIDKey)
            serverPriority.reset()
        }
    }
}
