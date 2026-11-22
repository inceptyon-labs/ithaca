import Foundation

@MainActor
@Observable
final class SeerrService {
    private static let defaultsBaseURLKey = "SeerrBaseURL"
    private static let defaultsServerIDKey = "SeerrPlexServerID"

    private let plexService: PlexService
    private let sessionDelegate: SeerrURLSessionDelegate
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private var storedSessions: [SeerrStoredSession]
    /// The Keychain was locked when the sessions were read (before the first
    /// unlock after a restart): they are read again before use and never saved
    /// over meanwhile.
    private var storedSessionsLocked = false
    private(set) var configuredBaseURL: URL?
    private(set) var configuredPlexServerID: String?
    private(set) var currentUser: SeerrUser?
    private(set) var publicSettings: SeerrPublicSettings?
    private(set) var isConnecting = false
    private(set) var lastConnectionError: String?
    /// Called after a request is sent from the app. `SeerrRequestTracker`
    /// starts watching it from there.
    @ObservationIgnored var requestCreated: (@MainActor (SeerrMediaRequest) -> Void)?
    /// TMDB recommendation pages by "type:tmdbID:page". See `recommendations`.
    @ObservationIgnored private var recommendationCache: [String: (fetchedAt: Date, results: [SeerrSearchMedia])] = [:]
    private static let recommendationCacheLifetime: TimeInterval = 60 * 60
    /// TMDB genre names by id, per type. They don't change, so they're kept.
    @ObservationIgnored private var genreNameCache: [SeerrMediaType: [Int: String]] = [:]
    /// Bumped by every request sent from the app: lists that carry request
    /// state (Discover's recommendations) are stale from then on.
    @ObservationIgnored private(set) var requestRevision = 0

    init(plexService: PlexService) {
        self.plexService = plexService
        self.sessionDelegate = SeerrURLSessionDelegate()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        self.session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        let storedSessions = SeerrCredentialStore.load()
        self.storedSessions = storedSessions ?? []
        self.storedSessionsLocked = storedSessions == nil

        if let value = UserDefaults.standard.string(forKey: Self.defaultsBaseURLKey) {
            self.configuredBaseURL = URL(string: value)
        }
        self.configuredPlexServerID = UserDefaults.standard.string(
            forKey: Self.defaultsServerIDKey
        )
        #if DEBUG
        if let url = ScreenshotMode.seerrBaseURL {
            self.configuredBaseURL = url
        }
        #endif
    }

    var isConfigured: Bool {
        configuredBaseURL != nil
    }

    var isConnected: Bool {
        currentStoredSession != nil
    }

    /// Seerr belongs to one Plex server. The binding is the account's
    /// highest-priority enabled server (`plexService.seerrBindingServerID`),
    /// which is stable across launches and outages — unlike the pool's primary
    /// connection, which is nil until a server answers and moves to the next
    /// server whenever the top one is offline.
    ///
    /// Nothing is sent before the Plex session is ready: until the Home check
    /// finishes, the profile and the token can belong to different people,
    /// and a re-sign-in would store one person's Seerr session under the other.
    var isAvailableForCurrentContext: Bool {
        isConnected && plexService.isSessionReady
    }

    var connectionSubtitle: String {
        if let currentUser {
            return "Connected as \(currentUser.displayName)"
        }
        if isConnected {
            return "Connected"
        }
        if isConfigured {
            return "Connect this Plex user"
        }
        return "Not configured"
    }

    func contextDidChange() async {
        currentUser = nil
        recommendationCache = [:]
        publicSettings = nil
        lastConnectionError = nil

        if storedSessionsLocked, let sessions = SeerrCredentialStore.load() {
            storedSessions = sessions
            storedSessionsLocked = false
        }
        // Signed out deletes every profile's sessions, but a Keychain that is
        // still locked only looks signed out.
        guard plexService.isAuthenticated else {
            guard !plexService.credentialsLocked, !storedSessionsLocked else { return }
            storedSessions = []
            SeerrCredentialStore.removeAll()
            return
        }
        guard !storedSessionsLocked else { return }

        rekeyLegacyServerIdentifiers()

        guard isAvailableForCurrentContext else { return }
        do {
            try await refreshConnectionStatus()
        } catch {
            lastConnectionError = error.localizedDescription
        }
    }

    func connect(serverURLString: String) async throws {
        guard !isConnecting else { return }
        guard let profileID = plexService.activeProfileID,
              let serverID = plexService.seerrBindingServerID,
              let plexToken = plexService.activeAccountToken else {
            throw SeerrServiceError.notConnected
        }

        isConnecting = true
        lastConnectionError = nil
        defer { isConnecting = false }

        let baseURL = try await resolveServerURL(serverURLString: serverURLString)
        var cookies: [String: String] = [:]
        let settings: SeerrPublicSettings = try await send(
            baseURL: baseURL,
            path: "api/v1/settings/public",
            cookies: &cookies
        )

        let body = try encoder.encode(SeerrPlexLoginBody(authToken: plexToken))
        let user: SeerrUser
        do {
            user = try await send(
                baseURL: baseURL,
                method: "POST",
                path: "api/v1/auth/plex",
                body: body,
                cookies: &cookies
            )
        } catch let error as SeerrServiceError {
            if case .permissionDenied = error {
                throw SeerrServiceError.plexUserNotAllowed
            }
            if case .authenticationRequired = error {
                throw SeerrServiceError.plexUserNotAllowed
            }
            throw error
        }

        guard cookies["connect.sid"] != nil else {
            throw SeerrServiceError.invalidResponse
        }

        configuredBaseURL = baseURL
        configuredPlexServerID = serverID
        publicSettings = settings
        currentUser = user
        persistConfiguration()
        // Another profile's session for this Seerr stays; it is kept per profile.
        storedSessions.removeAll {
            $0.baseURL != baseURL.absoluteString
                || ($0.profileID == profileID && $0.serverID != serverID)
        }
        upsertSession(
            SeerrStoredSession(
                baseURL: baseURL.absoluteString,
                profileID: profileID,
                serverID: serverID,
                cookies: cookies
            )
        )
    }

    func resolveServerURL(serverURLString: String) async throws -> URL {
        let candidates = try Self.connectionCandidates(from: serverURLString)
        var lastError: (any Error)?

        for baseURL in candidates {
            var cookies: [String: String] = [:]
            do {
                let settings: SeerrPublicSettings = try await send(
                    baseURL: baseURL,
                    path: "api/v1/settings/public",
                    cookies: &cookies
                )
                guard settings.initialized,
                      settings.isPlexServer,
                      settings.mediaServerLogin else {
                    throw SeerrServiceError.plexLoginUnavailable
                }
                return baseURL
            } catch let error as SeerrServiceError {
                if case .plexLoginUnavailable = error {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SeerrServiceError.invalidServerURL
    }

    func disconnect() async {
        if let baseURL = configuredBaseURL, var stored = currentStoredSession {
            _ = try? await sendWithoutResponse(
                baseURL: baseURL,
                method: "POST",
                path: "api/v1/auth/logout",
                cookies: &stored.cookies
            )
        }

        // Only this profile signs out; the URL is forgotten with the last session.
        if let baseURL = configuredBaseURL?.absoluteString,
           let profileID = plexService.activeProfileID {
            removeSessions { $0.baseURL == baseURL && $0.profileID == profileID }
        }
        // Reconnecting later must not announce everything that arrived meanwhile.
        if let prefix = requestOwnerPrefix {
            SeerrRequestWatchStore.removeRecords(withPrefix: prefix)
        }

        currentUser = nil
        publicSettings = nil
        lastConnectionError = nil
        recommendationCache = [:]
        guard !storedSessions.contains(where: { $0.baseURL == configuredBaseURL?.absoluteString }) else {
            return
        }
        configuredBaseURL = nil
        configuredPlexServerID = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsBaseURLKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerIDKey)
    }

    func refreshConnectionStatus() async throws {
        guard let baseURL = configuredBaseURL,
              var stored = currentStoredSession else {
            currentUser = nil
            throw SeerrServiceError.notConnected
        }

        guard isUsableSession(stored) else {
            currentUser = nil
            throw SeerrServiceError.serverMismatch
        }

        do {
            let settings: SeerrPublicSettings = try await send(
                baseURL: baseURL,
                path: "api/v1/settings/public",
                cookies: &stored.cookies
            )
            publicSettings = settings
            let user: SeerrUser = try await send(
                baseURL: baseURL,
                path: "api/v1/auth/me",
                cookies: &stored.cookies
            )
            currentUser = user
            upsertSession(stored)
        } catch let error as SeerrServiceError {
            guard case .authenticationRequired = error else {
                throw error
            }
            try await reauthenticate(baseURL: baseURL, stored: &stored)
            upsertSession(stored)
        }
    }

    func search(query: String) async throws -> [SeerrSearchMedia] {
        let response: SeerrSearchResponse = try await authenticatedSend(
            path: "api/v1/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: "1"),
            ]
        )
        return response.results.filter { $0.supportedMediaType != nil }
    }

    /// One page of a discover list: TMDB titles with Seerr's request state.
    /// Trending also returns people, which are dropped.
    func discover(_ list: SeerrDiscoverList, page: Int = 1) async throws -> [SeerrSearchMedia] {
        let response: SeerrSearchResponse = try await authenticatedSend(
            path: list.path,
            queryItems: [URLQueryItem(name: "page", value: String(page))]
        )
        return response.results.filter { $0.supportedMediaType != nil }
    }

    /// One page of the most popular titles of a type released in the past
    /// year, with Seerr's request state.
    func recentReleases(_ type: SeerrMediaType, page: Int = 1) async throws -> [SeerrSearchMedia] {
        let today = Date.now
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: today) ?? today
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        let (path, field) = switch type {
        case .movie: ("api/v1/discover/movies", "primaryReleaseDate")
        case .tv: ("api/v1/discover/tv", "firstAirDate")
        }
        let response: SeerrSearchResponse = try await authenticatedSend(
            path: path,
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "\(field)Gte", value: yearAgo.formatted(day)),
                URLQueryItem(name: "\(field)Lte", value: today.formatted(day)),
                URLQueryItem(name: "sortBy", value: "popularity.desc"),
            ]
        )
        return response.results.filter { $0.supportedMediaType == type }
    }

    func genreNames(_ type: SeerrMediaType) async throws -> [Int: String] {
        if let cached = genreNameCache[type] { return cached }
        let genres: [SeerrGenre] = try await authenticatedSend(path: "api/v1/genres/\(type.rawValue)")
        let names = Dictionary(genres.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        genreNameCache[type] = names
        return names
    }

    /// The Rotten Tomatoes scores Seerr finds for a title by its name, and for
    /// a movie IMDb's too. Empty when it finds none.
    func reviewScores(type: SeerrMediaType, id: Int) async throws -> ReviewScores {
        let percent = { (value: Double?) in value.map { Int($0.rounded()) } }
        switch type {
        case .movie:
            let ratings: SeerrCombinedRatings = try await authenticatedSend(path: "api/v1/movie/\(id)/ratingscombined")
            return ReviewScores(
                critics: percent(ratings.rt?.criticsScore),
                audience: percent(ratings.rt?.audienceScore),
                imdb: ratings.imdb?.criticsScore
            )
        case .tv:
            let rating: SeerrRottenTomatoesRating = try await authenticatedSend(path: "api/v1/tv/\(id)/ratings")
            return ReviewScores(critics: percent(rating.criticsScore), audience: percent(rating.audienceScore))
        }
    }

    /// One page of TMDB's recommendations for a title ("people who liked this
    /// also liked"), with Seerr's request state. Movies recommend movies and
    /// shows recommend shows. Pages are kept for an hour: they change slowly,
    /// and taste recommendations ask for the same titles on every Home load.
    /// `refresh` skips the cache (pull to refresh).
    func recommendations(
        type: SeerrMediaType,
        tmdbID: Int,
        page: Int = 1,
        refresh: Bool = false
    ) async throws -> [SeerrSearchMedia] {
        let key = "\(type.rawValue):\(tmdbID):\(page)"
        if !refresh, let cached = recommendationCache[key],
           Date.now.timeIntervalSince(cached.fetchedAt) < Self.recommendationCacheLifetime {
            return cached.results
        }
        let response: SeerrSearchResponse = try await authenticatedSend(
            path: "api/v1/\(type.rawValue)/\(tmdbID)/recommendations",
            queryItems: [URLQueryItem(name: "page", value: String(page))]
        )
        let results = response.results.filter { $0.supportedMediaType == type }
        recommendationCache[key] = (.now, results)
        return results
    }

    func movieDetails(id: Int) async throws -> SeerrMovieDetails {
        try await authenticatedSend(path: "api/v1/movie/\(id)")
    }

    func tvDetails(id: Int) async throws -> SeerrTVDetails {
        try await authenticatedSend(path: "api/v1/tv/\(id)")
    }

    func seasonDetails(tvID: Int, seasonNumber: Int) async throws -> SeerrSeasonDetails {
        try await authenticatedSend(path: "api/v1/tv/\(tvID)/season/\(seasonNumber)")
    }

    /// The current user's newest standard-quality requests, newest first, with
    /// Seerr's availability and live download progress, and the Seerr user
    /// they belong to.
    func myRequests(take: Int) async throws -> (userID: Int, requests: [SeerrListedRequest]) {
        try await ensureConnected()
        guard let userID = currentUser?.id else {
            throw SeerrServiceError.notConnected
        }
        let page: SeerrRequestPage = try await authenticatedSend(
            path: "api/v1/request",
            queryItems: [
                URLQueryItem(name: "take", value: String(take)),
                URLQueryItem(name: "skip", value: "0"),
                URLQueryItem(name: "filter", value: "all"),
                URLQueryItem(name: "sort", value: "added"),
                URLQueryItem(name: "requestedBy", value: String(userID)),
            ]
        )
        // Checked here too: a Seerr that ignores `requestedBy` lists an
        // admin everyone's requests.
        let requests = page.results.filter {
            $0.is4k != true && $0.mediaType != nil && ($0.requestedBy == nil || $0.requestedBy?.id == userID)
        }
        return (userID, requests)
    }

    /// Identifies whose requests these are: this Seerr, Plex profile and Seerr
    /// user. Nil until the user is known.
    var requestOwnerKey: String? {
        currentUser.flatMap { requestOwnerKey(userID: $0.id) }
    }

    func requestOwnerKey(userID: Int) -> String? {
        guard let prefix = requestOwnerPrefix else { return nil }
        return "\(prefix)\(userID)"
    }

    /// This Seerr and Plex profile: every Seerr user signed in from it.
    var requestOwnerPrefix: String? {
        guard let baseURL = configuredBaseURL?.absoluteString,
              let profileID = plexService.activeProfileID else {
            return nil
        }
        return "\(baseURL)|\(profileID)|"
    }

    func quota() async throws -> SeerrQuotaResponse {
        try await ensureConnected()
        guard let userID = currentUser?.id else {
            throw SeerrServiceError.notConnected
        }
        return try await authenticatedSend(path: "api/v1/user/\(userID)/quota")
    }

    @discardableResult
    func requestMovie(id: Int) async throws -> SeerrMediaRequest {
        try await createRequest(
            SeerrCreateRequestBody(
                mediaType: .movie,
                mediaId: id,
                seasons: nil,
                is4k: false
            )
        )
    }

    @discardableResult
    func requestTV(id: Int, seasons: SeerrRequestedSeasons) async throws -> SeerrMediaRequest {
        try await createRequest(
            SeerrCreateRequestBody(
                mediaType: .tv,
                mediaId: id,
                seasons: seasons,
                is4k: false
            )
        )
    }

    func requestState(
        mediaInfo: SeerrMediaInfo?,
        seasonNumber: Int? = nil
    ) -> SeerrRequestState {
        SeerrRequestState.resolve(
            mediaInfo: mediaInfo,
            currentUserID: currentUser?.id,
            seasonNumber: seasonNumber
        )
    }

    func posterURL(path: String?, width: Int = 500) -> URL? {
        let size: String
        switch width {
        case ...185: size = "w185"
        case ...342: size = "w342"
        case ...500: size = "w500"
        default: size = "w780"
        }
        return imageURL(path: path, size: size)
    }

    func backdropURL(path: String?, width: Int = 1280) -> URL? {
        let size: String
        switch width {
        case ...300: size = "w300"
        case ...780: size = "w780"
        default: size = "w1280"
        }
        return imageURL(path: path, size: size)
    }

    func stillURL(path: String?) -> URL? {
        imageURL(path: path, size: "w300")
    }

    static func normalizedBaseURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SeerrServiceError.invalidServerURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return try normalizedExplicitBaseURL(from: candidate)
    }

    private static func connectionCandidates(from value: String) throws -> [URL] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SeerrServiceError.invalidServerURL
        }

        if trimmed.contains("://") {
            return [try normalizedExplicitBaseURL(from: trimmed)]
        }

        return [
            try normalizedExplicitBaseURL(from: "https://\(trimmed)"),
            try normalizedExplicitBaseURL(from: "http://\(trimmed)"),
        ]
    }

    private static func normalizedExplicitBaseURL(from value: String) throws -> URL {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.nilIfEmpty != nil,
              components.user == nil,
              components.password == nil else {
            throw SeerrServiceError.invalidServerURL
        }

        components.query = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" {
            components.path = ""
        }
        components.scheme = scheme
        components.host = components.host?.lowercased()

        guard let url = components.url else {
            throw SeerrServiceError.invalidServerURL
        }
        return url
    }

    private func ensureConnected() async throws {
        guard isAvailableForCurrentContext else {
            throw isConfigured ? SeerrServiceError.notConnected : SeerrServiceError.notConfigured
        }
        if currentUser == nil {
            try await refreshConnectionStatus()
        }
    }

    private func authenticatedSend<T: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        try await ensureConnected()
        guard let baseURL = configuredBaseURL else {
            throw SeerrServiceError.notConfigured
        }
        var stored = try requireStoredSession()
        do {
            let value: T = try await send(
                baseURL: baseURL,
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                cookies: &stored.cookies
            )
            upsertSession(stored)
            return value
        } catch let error as SeerrServiceError {
            guard case .authenticationRequired = error else { throw error }
            try await reauthenticate(baseURL: baseURL, stored: &stored)
            let value: T = try await send(
                baseURL: baseURL,
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                cookies: &stored.cookies
            )
            upsertSession(stored)
            return value
        }
    }

    private func createRequest(_ body: SeerrCreateRequestBody) async throws -> SeerrMediaRequest {
        try await ensureConnected()
        guard currentUser?.canRequest(body.mediaType) == true else {
            throw SeerrServiceError.permissionDenied(
                "This Seerr account does not have permission to request this media type."
            )
        }
        let payload = try encoder.encode(body)
        let request: SeerrMediaRequest = try await authenticatedSend(
            method: "POST",
            path: "api/v1/request",
            body: payload
        )
        // Cached recommendation pages carry the old request state.
        recommendationCache = [:]
        requestRevision += 1
        requestCreated?(request)
        return request
    }

    private func reauthenticate(
        baseURL: URL,
        stored: inout SeerrStoredSession
    ) async throws {
        guard let plexToken = plexService.activeAccountToken else {
            throw SeerrServiceError.notConnected
        }
        // A local host name or address belongs to whoever answers on the
        // current network, so the token is never posted over plain HTTP without
        // the user asking. The expired session is dropped and Settings offers
        // Connect again.
        guard baseURL.scheme?.lowercased() == "https" else {
            removeSessions { $0.matches(stored) }
            currentUser = nil
            throw SeerrServiceError.notConnected
        }
        stored.cookies.removeValue(forKey: "connect.sid")
        let body = try encoder.encode(SeerrPlexLoginBody(authToken: plexToken))
        let user: SeerrUser = try await send(
            baseURL: baseURL,
            method: "POST",
            path: "api/v1/auth/plex",
            body: body,
            cookies: &stored.cookies
        )
        guard stored.cookies["connect.sid"] != nil else {
            throw SeerrServiceError.invalidResponse
        }
        currentUser = user
    }

    /// Through Seerr's image cache when it is on, otherwise straight from
    /// TMDB's image server, as Seerr's own web app does.
    private func imageURL(path: String?, size: String) -> URL? {
        guard let baseURL = configuredBaseURL,
              let path = path?.nilIfEmpty else {
            return nil
        }
        let tmdbPath = "t/p/\(size)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        guard publicSettings?.cacheImages == true else {
            return URL(string: "https://image.tmdb.org/\(tmdbPath)")
        }
        return endpointURL(baseURL: baseURL, path: "imageproxy/tmdb/\(tmdbPath)")
    }

    /// The session for this Plex user and this Seerr instance.
    ///
    /// The bound server is preferred, but a session stored against any other
    /// server this account knows still counts: the old binding followed
    /// whichever server happened to be connected at the time, and re-linking
    /// the same Seerr instance under a new key would only make the user sign in
    /// again for no reason.
    private var currentStoredSession: SeerrStoredSession? {
        guard let baseURL = configuredBaseURL?.absoluteString,
              let profileID = plexService.activeProfileID else {
            return nil
        }
        #if DEBUG
        // Screenshot mode: a signed-in session against the demo Seerr, never
        // read from or written to the Keychain.
        if ScreenshotMode.seerrBaseURL != nil {
            return SeerrStoredSession(
                baseURL: baseURL,
                profileID: profileID,
                serverID: plexService.seerrBindingServerID ?? "",
                cookies: ["connect.sid": ScreenshotMode.seerrSessionCookie]
            )
        }
        #endif
        let sessions = storedSessions.filter {
            $0.baseURL == baseURL && $0.profileID == profileID
        }
        if let bindingServerID = plexService.seerrBindingServerID,
           let bound = sessions.first(where: { $0.serverID == bindingServerID }) {
            return bound
        }
        return sessions.first { plexService.isKnownServerID($0.serverID) }
    }

    /// Whether a stored session still belongs to this account's servers.
    private func isUsableSession(_ session: SeerrStoredSession) -> Bool {
        session.serverID == plexService.seerrBindingServerID
            || plexService.isKnownServerID(session.serverID)
    }

    /// Sessions written before servers were identified by machine identifier
    /// carry a base-URL string where the identifier belongs, so they never match
    /// again. Re-key them once, where the URL still points at a known server.
    private func rekeyLegacyServerIdentifiers() {
        if let legacy = configuredPlexServerID,
           !plexService.isKnownServerID(legacy),
           let resolved = plexService.serverID(forLegacyConnectionURI: legacy) {
            configuredPlexServerID = resolved
            persistConfiguration()
        }

        var changed = false
        for index in storedSessions.indices {
            let serverID = storedSessions[index].serverID
            guard !plexService.isKnownServerID(serverID),
                  let resolved = plexService.serverID(forLegacyConnectionURI: serverID),
                  resolved != serverID else {
                continue
            }
            storedSessions[index] = SeerrStoredSession(
                baseURL: storedSessions[index].baseURL,
                profileID: storedSessions[index].profileID,
                serverID: resolved,
                cookies: storedSessions[index].cookies
            )
            changed = true
        }
        guard changed else { return }
        SeerrCredentialStore.save(storedSessions)
    }

    private func requireStoredSession() throws -> SeerrStoredSession {
        guard let currentStoredSession else {
            throw SeerrServiceError.notConnected
        }
        return currentStoredSession
    }

    private func upsertSession(_ stored: SeerrStoredSession) {
        #if DEBUG
        if ScreenshotMode.seerrBaseURL != nil { return }
        #endif
        guard !storedSessionsLocked else { return }
        if storedSessions.contains(stored) {
            return
        }
        storedSessions.removeAll { $0.matches(stored) }
        storedSessions.append(stored)
        SeerrCredentialStore.save(storedSessions)
    }

    private func removeSessions(where shouldRemove: (SeerrStoredSession) -> Bool) {
        #if DEBUG
        if ScreenshotMode.seerrBaseURL != nil { return }
        #endif
        guard !storedSessionsLocked else { return }
        let count = storedSessions.count
        storedSessions.removeAll(where: shouldRemove)
        guard storedSessions.count != count else { return }
        SeerrCredentialStore.save(storedSessions)
    }

    private func persistConfiguration() {
        if let configuredBaseURL {
            UserDefaults.standard.set(
                configuredBaseURL.absoluteString,
                forKey: Self.defaultsBaseURLKey
            )
        }
        if let configuredPlexServerID {
            UserDefaults.standard.set(
                configuredPlexServerID,
                forKey: Self.defaultsServerIDKey
            )
        }
    }

    private func send<T: Decodable>(
        baseURL: URL,
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        cookies: inout [String: String]
    ) async throws -> T {
        let (data, response, updatedCookies) = try await perform(
            baseURL: baseURL,
            method: method,
            path: path,
            queryItems: queryItems,
            body: body,
            cookies: cookies
        )
        cookies = updatedCookies
        try validate(response: response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SeerrServiceError.invalidResponse
        }
    }

    private func sendWithoutResponse(
        baseURL: URL,
        method: String,
        path: String,
        cookies: inout [String: String]
    ) async throws {
        let (data, response, updatedCookies) = try await perform(
            baseURL: baseURL,
            method: method,
            path: path,
            queryItems: [],
            body: nil,
            cookies: cookies
        )
        cookies = updatedCookies
        try validate(response: response, data: data)
    }

    private func perform(
        baseURL: URL,
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?,
        cookies: [String: String]
    ) async throws -> (Data, HTTPURLResponse, [String: String]) {
        guard let url = endpointURL(baseURL: baseURL, path: path, queryItems: queryItems) else {
            throw SeerrServiceError.invalidServerURL
        }
        // Sign-in posts the Plex token and every request carries the session
        // cookie, so plain HTTP goes only to a local address, and only while a
        // Plex server confirms this is its home network: away from home the
        // same address belongs to whoever answers there.
        if url.scheme?.lowercased() == "http" {
            guard LocalNetwork.isLocalHost(url.host ?? "") else {
                throw SeerrServiceError.insecureServerURL
            }
            guard plexService.pool.isOnHomeNetwork else {
                throw SeerrServiceError.awayFromHomeNetwork
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if !cookies.isEmpty {
            let cookieValue = cookies
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            request.setValue(cookieValue, forHTTPHeaderField: "Cookie")
        }
        if let xsrfToken = cookies["XSRF-TOKEN"] {
            request.setValue(xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw SeerrServiceError.insecureServerURL
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SeerrServiceError.invalidResponse
        }

        var updatedCookies = cookies
        let headerFields = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, element in
            guard let key = element.key as? String,
                  let value = element.value as? String else {
                return
            }
            result[key] = value
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url) {
            if cookie.value.isEmpty || cookie.expiresDate.map({ $0 <= .now }) == true {
                updatedCookies.removeValue(forKey: cookie.name)
            } else {
                updatedCookies[cookie.name] = cookie.value
            }
        }

        return (data, httpResponse, updatedCookies)
    }

    private func endpointURL(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        var url = baseURL
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }
        guard !queryItems.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Seerr rejects a value with reserved characters in it (400, "must be
        // url encoded": "Ocean's Eleven", "Dune: Part Two"), and Express reads
        // "+" as a space. URLComponents leaves all of them alone.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        components.percentEncodedQuery = queryItems.map { item in
            item.value.map { "\(encode(item.name))=\(encode($0))" } ?? encode(item.name)
        }
        .joined(separator: "&")
        return components.url
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        if response.statusCode == 202 {
            let message = (try? decoder.decode(SeerrErrorResponse.self, from: data))
                .flatMap { $0.message?.nilIfEmpty ?? $0.error?.nilIfEmpty }
                ?? "There are no new seasons available to request."
            throw SeerrServiceError.noSeasonsAvailable(message)
        }

        guard !(200...299).contains(response.statusCode) else { return }

        let message = (try? decoder.decode(SeerrErrorResponse.self, from: data))
            .flatMap { $0.message?.nilIfEmpty ?? $0.error?.nilIfEmpty }
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)

        switch response.statusCode {
        case 401:
            throw SeerrServiceError.authenticationRequired(message)
        case 403:
            throw SeerrServiceError.permissionDenied(message)
        case 409:
            throw SeerrServiceError.requestConflict(message)
        default:
            throw SeerrServiceError.serverError(message)
        }
    }
}

private struct SeerrPlexLoginBody: Encodable {
    let authToken: String
}

private struct SeerrErrorResponse: Decodable {
    let message: String?
    let error: String?
}

private extension SeerrStoredSession {
    func matches(_ other: SeerrStoredSession) -> Bool {
        baseURL == other.baseURL &&
            profileID == other.profileID &&
            serverID == other.serverID
    }
}

private final class SeerrURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.currentRequest?.url,
              let redirectedURL = request.url,
              Self.sameOrigin(originalURL, redirectedURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
            lhs.host?.lowercased() == rhs.host?.lowercased() &&
            effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
