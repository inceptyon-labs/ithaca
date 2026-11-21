import Foundation

/// Athena: the small server beside Plex (its own repo, `inceptyon-labs/athena`) that answers
/// Pick Something's Describe It with Claude. Ithaca sends the titles that fit
/// the screen's filters and the viewer's taste; Athena answers with ids from
/// that list and a one-line reason for each, and, when asked, titles outside
/// the library to request. The API key lives on the server, so the apps need
/// no cloud account.
struct AthenaClient: Sendable {
    let baseURL: URL

    /// An address as typed in Settings. Without a scheme it is plain HTTP:
    /// Athena runs on the home network. Plain HTTP to anywhere else is no
    /// address, because a request carries titles, ratings and watch history.
    init?(address: String) {
        guard let url = Self.parsedURL(address), !Self.isPlainHTTPOffNetwork(url) else { return nil }
        baseURL = url
    }

    /// True for an address that is well formed but refused for being plain
    /// HTTP to a host outside the home network.
    static func refusesAsInsecure(_ address: String) -> Bool {
        parsedURL(address).map(isPlainHTTPOffNetwork) ?? false
    }

    private static func isPlainHTTPOffNetwork(_ url: URL) -> Bool {
        url.scheme == "http" && !LocalNetwork.isLocalHost(url.host(percentEncoded: false) ?? "")
    }

    private static func parsedURL(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.nilIfEmpty != nil else {
            return nil
        }
        components.scheme = scheme
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Up to `request.count` picks and `request.suggest` suggestions, best fit
    /// first.
    ///
    /// - Parameter plexToken: the active profile's plex.tv account token (not a
    ///   server's access token). Athena asks plex.tv whether that account can
    ///   reach its Plex server. nil sends no header.
    func pick(_ request: AthenaPickRequest, plexToken: String? = nil) async throws -> AthenaAnswer {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/pick"), timeoutInterval: 90)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let plexToken { urlRequest.setValue(plexToken, forHTTPHeaderField: "X-Plex-Token") }
        urlRequest.httpBody = try JSONEncoder().encode(request)
        return try await send(urlRequest)
    }

    func health() async throws -> AthenaHealth {
        try await send(URLRequest(url: baseURL.appending(path: "healthz"), timeoutInterval: 10))
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AthenaError.unreachable(host: baseURL.host() ?? baseURL.absoluteString)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 {
                throw AthenaError.plexAccessRequired(host: baseURL.host() ?? baseURL.absoluteString)
            }
            let message = (try? JSONDecoder().decode(AthenaErrorBody.self, from: data))?.error
            throw AthenaError.server(message ?? "Athena answered with an error (\(status)).")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AthenaError.server("Athena's answer could not be read.")
        }
    }
}

enum AthenaError: LocalizedError {
    case unreachable(host: String)
    case plexAccessRequired(host: String)
    case server(String)
    case noLibrary

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): "Couldn't reach Athena at \(host)."
        case .plexAccessRequired(let host): "Athena at \(host) only answers people with access to its Plex server."
        case .server(let message): message
        case .noLibrary: "Couldn't read your libraries."
        }
    }
}

/// `POST /v1/pick`. Mirrors `PickRequest` in Athena's `src/pick.ts`.
struct AthenaPickRequest: Encodable, Sendable, Equatable {
    struct Title: Encodable, Sendable, Equatable {
        let id: String
        let title: String
        var year: Int?
        var genres: [String]?
        /// A movie's running time, or a show's typical episode.
        var minutes: Int?
        var contentRating: String?
        var scores: ReviewScores?
        /// Only sent when true.
        var seen: Bool?
        /// `PlexTasteRating.rawValue`.
        var rating: String?
    }

    struct Taste: Encodable, Sendable, Equatable {
        var loved: [String] = []
        var liked: [String] = []
        var disliked: [String] = []
        var recent: [String] = []
    }

    /// A title the household doesn't have, from Seerr's trending and recent
    /// lists: Haiku doesn't know the newest releases.
    struct Outside: Encodable, Sendable, Equatable {
        let id: String
        let title: String
        var year: Int?
        var genres: [String]?
        var overview: String?
        /// TMDB's average, out of 10.
        var tmdb: Double?
    }

    let request: String
    let kind: String
    /// 0 asks for suggestions only.
    let count: Int
    let titles: [Title]
    let taste: Taste
    /// Ids already on screen or queued.
    let exclude: [String]
    /// How many titles outside the library to suggest requesting.
    var suggest = 0
    var discover: [Outside]?
    /// The screen's filters: `titles` already meet them, suggestions must.
    var maxMinutes: Int?
    var genre: String?
}

/// What Athena answers. An older Athena sends only picks.
struct AthenaAnswer: Decodable, Sendable {
    var picks: [AthenaPick] = []
    var suggestions: [AthenaSuggestion] = []
    var minimums = AthenaMinimums()

    private enum CodingKeys: String, CodingKey {
        case picks, suggestions, minimums
    }

    /// Ithaca's own answer, without Athena (`DescribeItRanker`).
    init(picks: [AthenaPick] = [], suggestions: [AthenaSuggestion] = [], minimums: AthenaMinimums = AthenaMinimums()) {
        self.picks = picks
        self.suggestions = suggestions
        self.minimums = minimums
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        picks = try container.decodeIfPresent([AthenaPick].self, forKey: .picks) ?? []
        suggestions = try container.decodeIfPresent([AthenaSuggestion].self, forKey: .suggestions) ?? []
        minimums = try container.decodeIfPresent(AthenaMinimums.self, forKey: .minimums) ?? AthenaMinimums()
    }
}

struct AthenaPick: Decodable, Sendable, Equatable {
    let id: String
    let reason: String
}

/// A title outside the library, to look up on Seerr.
struct AthenaSuggestion: Decodable, Sendable, Equatable {
    let title: String
    let year: Int?
    /// Set when it came from the request's `discover` list.
    let discoverId: String?
    let reason: String
}

/// Any minimum rating the request asked for ("over 8 on Rotten Tomatoes" is
/// critics 80). Claude sometimes picks a title below one anyway, so Ithaca
/// checks the scores itself.
struct AthenaMinimums: Decodable, Sendable, Equatable {
    /// Rotten Tomatoes, percent.
    var critics: Double?
    var audience: Double?
    /// Out of 10.
    var imdb: Double?
}

extension ReviewScores {
    /// False only when a score with a minimum is known and falls short. An
    /// unknown score passes: Claude judged that one from what it knows.
    func meets(_ minimums: AthenaMinimums) -> Bool {
        if let minimum = minimums.critics, let critics, Double(critics) < minimum { return false }
        if let minimum = minimums.audience, let audience, Double(audience) < minimum { return false }
        if let minimum = minimums.imdb, let imdb, imdb < minimum { return false }
        return true
    }
}

struct AthenaHealth: Decodable, Sendable {
    let ok: Bool
    /// False until the server has an API key.
    let ready: Bool
    let model: String
    /// "athena": how `HomeServerFinder` tells Athena from anything else on
    /// its port. Older Athenas don't send it.
    let service: String?
    /// The machine identifier of the Plex Media Server Athena checks sign-ins
    /// against. Informational; absent on older servers or without Plex set up.
    let server: String?
}

private struct AthenaErrorBody: Decodable {
    let error: String
}

extension AthenaPickRequest.Taste {
    /// What the viewer loved, liked, disliked or finished lately, as
    /// "Title (year)".
    init(catalog: TasteCatalog) {
        for seed in catalog.seeds {
            let year = catalog.library.item(for: seed.key)?.year
            let name = year.map { "\(seed.title) (\($0))" } ?? seed.title
            switch seed.reason {
            case .loved: loved.append(name)
            case .liked: liked.append(name)
            case .disliked: disliked.append(name)
            case .watched: recent.append(name)
            }
        }
    }
}

/// The titles a Describe It request picks from: the profile's library of the
/// screen's kind that fits its filters, one entry per title (the copy on the
/// highest-priority server). Ids are positions in a stable order, so the same
/// filters send the same list and Athena's cached prompt is reused.
struct PickSomethingAthenaOptions: Sendable {
    struct Entry: Sendable {
        let key: TasteTitleKey
        /// The copy a card shows.
        let item: PlexItem
        /// Every server's copy, highest priority first.
        let copies: [PlexItem]
    }

    let titles: [AthenaPickRequest.Title]
    private let entries: [String: Entry]

    /// Athena's own limit; past it, titles late in the alphabet are left out.
    static let maximumTitles = 5000

    /// - Parameter genreMemberIDs: the copies Plex files under the criteria's
    ///   genre (`PickSomethingEngine.genreMemberIDs`); nil without a genre.
    init(library: TasteLibrary, criteria: PickSomethingCriteria, genreMemberIDs: Set<PlexItemID>?) {
        // Unwatched is judged across every copy below, not just the shown one.
        var shape = criteria
        shape.unwatchedOnly = false

        let fitting: [Entry] = library.copies.compactMap { key, copies in
            guard let item = copies.first, shape.matches(item), !item.title.isEmpty else { return nil }
            if criteria.unwatchedOnly, library.isSeen(key) { return nil }
            if let genreMemberIDs, !copies.contains(where: { genreMemberIDs.contains($0.id) }) {
                return nil
            }
            return Entry(key: key, item: item, copies: copies)
        }
        .sorted { lhs, rhs in
            let order = lhs.item.title.localizedStandardCompare(rhs.item.title)
            return order == .orderedSame ? lhs.key.tmdbID < rhs.key.tmdbID : order == .orderedAscending
        }

        var titles: [AthenaPickRequest.Title] = []
        var entries: [String: Entry] = [:]
        for (index, entry) in fitting.prefix(Self.maximumTitles).enumerated() {
            let id = String(index + 1)
            entries[id] = entry
            titles.append(Self.title(id: id, entry: entry, isSeen: library.isSeen(entry.key)))
        }
        self.titles = titles
        self.entries = entries
    }

    func entry(for id: String) -> Entry? {
        entries[id]
    }

    /// The ids of entries whose shown copy passes `isIncluded`.
    func ids(where isIncluded: (PlexItem) -> Bool) -> [String] {
        titles.map(\.id).filter { id in entries[id].map { isIncluded($0.item) } ?? false }
    }

    private static func title(id: String, entry: Entry, isSeen: Bool) -> AthenaPickRequest.Title {
        let item = entry.item
        let rating = entry.copies.lazy.compactMap { PlexTasteRating(plexValue: $0.userRating) }.first
        let minutes = (item.duration ?? 0) / 60_000
        let scores = ReviewScores(item: item)
        // Clamped to Athena's limits: one value over them rejects the request.
        let genres = (item.genres ?? []).prefix(12).map { String($0.tag.prefix(60)) }
        return AthenaPickRequest.Title(
            id: id,
            title: String(item.title.prefix(300)),
            year: item.year,
            genres: genres.isEmpty ? nil : genres,
            minutes: minutes > 0 ? minutes : nil,
            contentRating: item.contentRating?.nilIfEmpty.map { String($0.prefix(20)) },
            scores: scores.isEmpty ? nil : scores,
            seen: isSeen ? true : nil,
            rating: rating?.rawValue
        )
    }
}
