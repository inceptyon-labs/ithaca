import SwiftUI

/// Every media route carries a `PlexItemID`, not a bare rating key: rating keys
/// are per-server counters that collide across servers, so a route without the
/// server would open whatever item happens to share that key on the primary
/// one. Navigating from an item therefore always opens it on *its* server.
enum AppNavigationRoute: Hashable {
    case search
    case discover
    case library(PlexLibrary)
    case libraryGenre(library: PlexLibrary, genre: LibraryGenreOption)
    case libraryCollection(library: PlexLibrary, collection: PlexLibraryCollection)
    case libraryRecommendations(PlexLibrary)
    case hub(PlexHub)
    case media(type: PlexMediaType, id: PlexItemID)
    case downloadedMedia(type: PlexMediaType, id: PlexItemID)
    case video(id: PlexItemID)
    case downloadedVideo(id: PlexItemID)
    /// Person tag ids are per-server too, so the route carries the server the
    /// credit was read from; nil falls back to the primary server.
    case person(PlexPersonReference, serverID: String?)
    case seerrMedia(type: SeerrMediaType, id: Int)
    /// A Seerr title Seerr reports as in Plex, by TMDB id: opens its Plex page
    /// once found (`DiscoverPlexTitleView`), else the Seerr page.
    case seerrInPlex(type: SeerrMediaType, id: Int, title: String)
    case seerrSeason(tvID: Int, seasonNumber: Int)
    case pickSomething(PickSomethingKind)
    #if DEBUG
    /// Screenshot mode only (`ScreenshotMode`): Settings › Server Priority is
    /// otherwise reached through a plain NavigationLink.
    case screenshotServerPriority
    /// Screenshot mode only: Settings › Ithaca Pro.
    case screenshotPro
    #endif

    /// Also remembers the item as the detail page's seed (`DetailSeeds`):
    /// every card builds its link here, so the page it opens can draw its hero
    /// from what the card already had.
    @MainActor
    static func destination(for item: PlexItem) -> Self {
        DetailSeeds.remember(item)
        if let person = PlexPersonReference(item: item) {
            return .person(person, serverID: item.serverID)
        }

        // Clips report `type == "movie"` with `subtype == "clip"`, so they must
        // never fall through to the movie detail flow.
        if item.isClip {
            return .video(id: item.id)
        }

        return .media(type: item.type, id: item.id)
    }
}

/// The items cards were showing, by id, so a detail page can paint its hero
/// (art, logo, title, summary) while its metadata loads. Memory only, bounded,
/// and cleared with the server sessions.
@MainActor
enum DetailSeeds {
    private static let capacity = 500
    private static var items: [PlexItemID: PlexItem] = [:]

    static func remember(_ item: PlexItem) {
        if items.count >= capacity, items[item.id] == nil {
            items.removeAll(keepingCapacity: true)
        }
        items[item.id] = item
    }

    /// Seeds a season or episode row's route. Both models are `Codable` with the
    /// same keys as `PlexItem`, so the row re-decodes as the item a card would
    /// have carried; nothing is remembered if that fails. Routes are built on
    /// every render, so a row already seeded is skipped.
    static func remember<Row: Encodable>(_ row: Row, id: PlexItemID, type: PlexMediaType) {
        guard items[id] == nil,
              let data = try? JSONEncoder().encode(row),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        object["type"] = type.rawValue
        guard let seedData = try? JSONSerialization.data(withJSONObject: object) else { return }
        let decoder = JSONDecoder()
        decoder.userInfo[.ithacaServerID] = id.serverID
        guard let item = try? decoder.decode(PlexItem.self, from: seedData) else { return }
        remember(item)
    }

    static func remember(_ season: PlexSeason) {
        remember(season, id: season.id, type: .season)
    }

    static func remember(_ episode: PlexEpisode) {
        remember(episode, id: episode.id, type: .episode)
    }

    static func item(for id: PlexItemID) -> PlexItem? {
        items[id]
    }

    static func removeAll() {
        items.removeAll()
    }
}

struct AppNavigationDestinationView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Environment(SeerrService.self) private var seerrService
    @Environment(UserPreferences.self) private var preferences
    @Environment(TasteRecommender.self) private var tasteRecommender
    @Environment(IthacaStore.self) private var store

    let route: AppNavigationRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .search:
            SearchRootContent()
        case .discover:
            DiscoverRootContent()
        case let .seerrInPlex(type, id, title):
            DiscoverPlexTitleView(type: type, tmdbID: id, title: title)
        case .library(let library):
            LibraryItemsView(library: library, plexService: plexService)
        case .libraryGenre(let library, let genre):
            LibraryItemsView(
                library: library,
                plexService: plexService,
                initialGenre: genre,
                preferLocalGenreFiltering: true
            )
        case .libraryCollection(let library, let collection):
            LibraryCollectionItemsView(library: library, collection: collection)
        case .libraryRecommendations(let library):
            LibraryRecommendationsView(
                library: library,
                plexService: plexService,
                navigationTitle: library.title
            )
        case .hub(let hub):
            HomeHubItemsView(hub: hub, plexService: plexService)
        case let .media(type, id):
            MediaDetailDestinationView(
                type: type,
                id: id,
                plexService: plexService,
                seerrService: seerrService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case let .downloadedMedia(type, id):
            MediaDetailDestinationView(
                type: type,
                id: id,
                plexService: plexService,
                seerrService: seerrService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: DownloadsFeature.isVisible
            )
        case let .video(id):
            VideoDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case let .downloadedVideo(id):
            VideoDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case let .person(person, serverID):
            ActorDetailView(person: person, serverID: serverID, plexService: plexService)
        case let .seerrMedia(type, id):
            SeerrMediaDetailView(mediaType: type, mediaID: id, service: seerrService)
        case let .seerrSeason(tvID, seasonNumber):
            SeerrSeasonDetailView(
                tvID: tvID,
                seasonNumber: seasonNumber,
                service: seerrService
            )
        case let .pickSomething(kind):
            PickSomethingView(
                initialKind: kind,
                plexService: plexService,
                preferences: preferences,
                tasteRecommender: tasteRecommender,
                seerrService: seerrService,
                store: store
            )
        #if DEBUG
        case .screenshotServerPriority:
            ServerPrioritySettingsView()
        case .screenshotPro:
            ProView()
        #endif
        }
    }
}

extension View {
    func ithacaAppNavigationDestinations() -> some View {
        navigationDestination(for: AppNavigationRoute.self) { route in
            AppNavigationDestinationView(route: route)
        }
    }
}
