import Foundation

enum SeerrMediaType: String, Codable, Sendable, Hashable {
    case movie
    case tv
}

enum SeerrMediaStatus: Int, Codable, Sendable, Hashable {
    case unknown = 1
    case pending
    case processing
    case partiallyAvailable
    case available
    case blocklisted
    case deleted
}

enum SeerrMediaRequestStatus: Int, Codable, Sendable, Hashable {
    case pending = 1
    case approved
    case declined
    case failed
    case completed
}

struct SeerrPublicSettings: Decodable, Sendable {
    let initialized: Bool
    let applicationTitle: String?
    let mediaServerLogin: Bool
    let mediaServerType: Int
    let partialRequestsEnabled: Bool
    let enableSpecialEpisodes: Bool
    /// Settings → General → Enable Image Caching, off by default. Off, Seerr
    /// answers every `/imageproxy` request with 404.
    let cacheImages: Bool?

    var isPlexServer: Bool {
        mediaServerType == 1
    }
}

struct SeerrUser: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let email: String?
    let username: String?
    let plexUsername: String?
    let permissions: Int64

    var displayName: String {
        plexUsername?.nilIfEmpty
            ?? username?.nilIfEmpty
            ?? email?.nilIfEmpty
            ?? "Plex User"
    }

    func hasAnyPermission(_ permissionsToCheck: [SeerrPermission]) -> Bool {
        let value = SeerrPermission(rawValue: permissions)
        return value.contains(.admin) || permissionsToCheck.contains(where: value.contains)
    }

    func canRequest(_ mediaType: SeerrMediaType) -> Bool {
        switch mediaType {
        case .movie:
            return hasAnyPermission([.request, .requestMovie])
        case .tv:
            return hasAnyPermission([.request, .requestTV])
        }
    }
}

struct SeerrPermission: OptionSet, Sendable {
    let rawValue: Int64

    static let admin = SeerrPermission(rawValue: 2)
    static let request = SeerrPermission(rawValue: 32)
    static let requestMovie = SeerrPermission(rawValue: 262_144)
    static let requestTV = SeerrPermission(rawValue: 524_288)
}

struct SeerrSearchResponse: Decodable, Sendable {
    let page: Int?
    let totalPages: Int?
    let totalResults: Int?
    let results: [SeerrSearchMedia]
}

struct SeerrSearchMedia: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let releaseDate: String?
    let firstAirDate: String?
    let mediaInfo: SeerrMediaInfo?
    /// TMDB genre ids (`SeerrService.genreNames`) and average score out of 10.
    var genreIds: [Int]? = nil
    var voteAverage: Double? = nil

    var supportedMediaType: SeerrMediaType? {
        SeerrMediaType(rawValue: mediaType)
    }

    var displayTitle: String {
        title?.nilIfEmpty ?? name?.nilIfEmpty ?? "Untitled"
    }

    var year: Int? {
        let date = releaseDate?.nilIfEmpty ?? firstAirDate?.nilIfEmpty
        guard let yearText = date?.prefix(4) else { return nil }
        return Int(yearText)
    }
}

extension SeerrSearchMedia {
    /// The server doesn't have it and nobody has asked for it.
    var isUnrequested: Bool {
        SeerrMediaInfo.isUnrequested(mediaInfo)
    }
}

extension SeerrMediaInfo {
    static func isUnrequested(_ mediaInfo: SeerrMediaInfo?) -> Bool {
        switch mediaInfo?.status {
        case nil, .unknown?, .deleted?: true
        default: false
        }
    }
}

/// `GET /api/v1/movie/{id}/ratingscombined`. Seerr finds the title on Rotten
/// Tomatoes and IMDb by name; either is missing when it finds no match.
struct SeerrCombinedRatings: Decodable, Sendable {
    let rt: SeerrRottenTomatoesRating?
    let imdb: SeerrIMDbRating?
}

/// Also the whole of `GET /api/v1/tv/{id}/ratings`. Scores are percent.
struct SeerrRottenTomatoesRating: Decodable, Sendable {
    let criticsScore: Double?
    let audienceScore: Double?
}

/// Out of 10, though Seerr calls it `criticsScore`.
struct SeerrIMDbRating: Decodable, Sendable {
    let criticsScore: Double?
}

/// The Seerr discover lists the Discover screen shows, in order.
enum SeerrDiscoverList: String, CaseIterable, Sendable, Identifiable {
    case trending
    case popularMovies
    case upcomingMovies
    case popularTV
    case upcomingTV

    var id: Self { self }

    var title: String {
        switch self {
        case .trending: "Trending"
        case .popularMovies: "Popular Movies"
        case .upcomingMovies: "Upcoming Movies"
        case .popularTV: "Popular TV"
        case .upcomingTV: "Upcoming TV"
        }
    }

    var path: String {
        switch self {
        case .trending: "api/v1/discover/trending"
        case .popularMovies: "api/v1/discover/movies"
        case .upcomingMovies: "api/v1/discover/movies/upcoming"
        case .popularTV: "api/v1/discover/tv"
        case .upcomingTV: "api/v1/discover/tv/upcoming"
        }
    }
}

struct SeerrMediaInfo: Decodable, Sendable, Hashable {
    let id: Int?
    let tmdbId: Int?
    let tvdbId: Int?
    let status: SeerrMediaStatus?
    let status4k: SeerrMediaStatus?
    let requests: [SeerrMediaRequest]?
    let seasons: [SeerrMediaSeason]?
    let ratingKey: String?
}

struct SeerrMediaRequest: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let status: SeerrMediaRequestStatus
    let requestedBy: SeerrUser?
    let seasons: [SeerrSeasonRequest]?
    let is4k: Bool?
}

struct SeerrSeasonRequest: Decodable, Sendable, Hashable {
    let id: Int?
    let seasonNumber: Int
    let status: SeerrMediaRequestStatus
}

struct SeerrMediaSeason: Decodable, Sendable, Hashable {
    let id: Int?
    let seasonNumber: Int
    let status: SeerrMediaStatus?
    let status4k: SeerrMediaStatus?
}

/// One page of `GET /api/v1/request`. A request that fails to decode (a
/// status a newer Seerr added) is dropped rather than failing the page.
struct SeerrRequestPage: Decodable, Sendable {
    let results: [SeerrListedRequest]

    private enum CodingKeys: String, CodingKey {
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode([SeerrLossy<SeerrListedRequest>].self, forKey: .results)
            .compactMap(\.value)
    }
}

struct SeerrLossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A request from Seerr's request list. Its media record carries no title or
/// artwork, only the TMDB id, Seerr's availability and the Radarr/Sonarr queue.
struct SeerrListedRequest: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let status: SeerrMediaRequestStatus
    let type: String
    let is4k: Bool?
    let createdAt: String?
    let seasons: [SeerrSeasonRequest]?
    let media: SeerrRequestMedia
    let requestedBy: SeerrRequestOwner?

    var mediaType: SeerrMediaType? {
        SeerrMediaType(rawValue: type)
    }

    var createdDate: Date? {
        SeerrDate.parse(createdAt)
    }
}

struct SeerrRequestOwner: Decodable, Sendable, Hashable {
    let id: Int
}

struct SeerrRequestMedia: Decodable, Sendable, Hashable {
    let tmdbId: Int
    let status: SeerrMediaStatus?
    let ratingKey: String?
    /// Radarr/Sonarr queue entries for this title, refreshed by Seerr's
    /// download sync job (every minute by default). Empty when nothing is
    /// downloading.
    let downloadStatus: [SeerrDownloadItem]?
}

/// One Radarr/Sonarr queue entry as Seerr relays it.
struct SeerrDownloadItem: Decodable, Sendable, Hashable {
    let size: Double?
    let sizeLeft: Double?
    let status: String?
    let estimatedCompletionTime: String?
}

enum SeerrDate {
    /// Seerr writes JavaScript ISO 8601 dates, with milliseconds.
    static func parse(_ value: String?) -> Date? {
        guard let value = value?.nilIfEmpty else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

struct SeerrGenre: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
}

struct SeerrMovieDetails: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let title: String
    let overview: String?
    let releaseDate: String?
    let runtime: Int?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let genres: [SeerrGenre]?
    let mediaInfo: SeerrMediaInfo?

    var year: Int? {
        guard let value = releaseDate?.prefix(4) else { return nil }
        return Int(value)
    }
}

struct SeerrTVDetails: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let firstAirDate: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let genres: [SeerrGenre]?
    let seasons: [SeerrSeasonSummary]
    let mediaInfo: SeerrMediaInfo?

    var year: Int? {
        guard let value = firstAirDate?.prefix(4) else { return nil }
        return Int(value)
    }
}

struct SeerrSeasonSummary: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let airDate: String?
    let episodeCount: Int?
    let name: String
    let overview: String?
    let posterPath: String?
    let seasonNumber: Int
}

struct SeerrSeasonDetails: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let airDate: String?
    let episodes: [SeerrEpisode]?
    let name: String
    let overview: String?
    let posterPath: String?
    let seasonNumber: Int
}

struct SeerrEpisode: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let airDate: String?
    let episodeNumber: Int?
    let name: String?
    let overview: String?
    let runtime: Int?
    let stillPath: String?
}

struct SeerrQuotaResponse: Decodable, Sendable {
    let movie: SeerrQuota
    let tv: SeerrQuota
}

struct SeerrQuota: Decodable, Sendable {
    let days: Int?
    let limit: Int?
    let used: Int?
    let remaining: Int?
    let restricted: Bool
}

struct SeerrCreateRequestBody: Encodable, Sendable {
    let mediaType: SeerrMediaType
    let mediaId: Int
    let seasons: SeerrRequestedSeasons?
    let is4k: Bool
}

enum SeerrRequestedSeasons: Encodable, Sendable {
    case all
    case numbers([Int])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all:
            try container.encode("all")
        case .numbers(let values):
            try container.encode(values)
        }
    }
}

enum SeerrRequestState: Sendable, Hashable {
    case requestable
    case pending
    case approved
    case processing
    case partiallyAvailable
    case available
    case blocklisted
    case declined
    case failed
    case completed

    var badgeTitle: String {
        switch self {
        case .requestable: "Request"
        case .pending: "Pending"
        case .approved: "Approved"
        case .processing: "Processing"
        case .partiallyAvailable: "Partial"
        case .available: "Available"
        case .blocklisted: "Unavailable"
        case .declined: "Declined"
        case .failed: "Failed"
        case .completed: "Available"
        }
    }

    var detailTitle: String {
        switch self {
        case .requestable: "Available to request"
        case .pending: "Pending approval"
        case .approved: "Approved"
        case .processing: "Being processed"
        case .partiallyAvailable: "Partially available"
        case .available, .completed: "Available in Plex"
        case .blocklisted: "Not available to request"
        case .declined: "Request declined"
        case .failed: "Request failed"
        }
    }

    var canRequest: Bool {
        self == .requestable || self == .declined
    }

    var systemImage: String {
        switch self {
        case .requestable: "paperplane.fill"
        case .pending: "clock"
        case .approved: "checkmark.circle"
        case .processing: "arrow.triangle.2.circlepath"
        case .partiallyAvailable: "circle.lefthalf.filled"
        case .available, .completed: "checkmark.circle.fill"
        case .blocklisted: "nosign"
        case .declined: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    static func resolve(
        mediaInfo: SeerrMediaInfo?,
        currentUserID: Int?,
        seasonNumber: Int? = nil
    ) -> SeerrRequestState {
        let mediaSeason = seasonNumber.flatMap { number in
            mediaInfo?.seasons?.first { $0.seasonNumber == number }
        }
        if seasonNumber == nil {
            switch mediaInfo?.status {
            case .available: return .available
            case .partiallyAvailable: return .partiallyAvailable
            case .processing: return .processing
            case .blocklisted: return .blocklisted
            default: break
            }
        } else {
            switch mediaSeason?.status {
            case .available: return .available
            case .partiallyAvailable: return .partiallyAvailable
            case .processing: return .processing
            case .blocklisted: return .blocklisted
            default: break
            }
        }

        let standardRequests = mediaInfo?.requests?.filter { $0.is4k != true } ?? []
        // Seerr lists requests unordered. A live request beats a declined or
        // failed one (a re-request after a decline), then the user's own, then
        // the newest.
        func rank(_ status: SeerrMediaRequestStatus, in request: SeerrMediaRequest) -> (Int, Int, Int) {
            (
                status == .declined || status == .failed ? 1 : 0,
                request.requestedBy?.id == currentUserID ? 0 : 1,
                -request.id
            )
        }

        let requestStatus: SeerrMediaRequestStatus? = {
            if let seasonNumber {
                return standardRequests
                    .flatMap { request in
                        (request.seasons ?? [])
                            .filter { $0.seasonNumber == seasonNumber }
                            .map { (request: request, status: $0.status) }
                    }
                    .min { rank($0.status, in: $0.request) < rank($1.status, in: $1.request) }?
                    .status
            }
            return standardRequests
                .min { rank($0.status, in: $0) < rank($1.status, in: $1) }?
                .status
        }()

        switch requestStatus {
        case .pending: return .pending
        case .approved: return .approved
        case .declined: return .declined
        case .failed: return .failed
        case .completed: return .completed
        case nil:
            // A single season is decided by its own record and requests only.
            if seasonNumber != nil {
                switch mediaSeason?.status {
                case .pending: return .pending
                case .processing: return .processing
                default: return .requestable
                }
            }
            switch mediaInfo?.status {
            case .pending: return .pending
            case .deleted, .unknown, nil: return .requestable
            case .processing: return .processing
            case .partiallyAvailable: return .partiallyAvailable
            case .available: return .available
            case .blocklisted: return .blocklisted
            }
        }
    }
}
