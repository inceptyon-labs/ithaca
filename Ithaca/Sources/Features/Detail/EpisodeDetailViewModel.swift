#if !os(tvOS)
import Foundation

@MainActor
@Observable
final class EpisodeDetailViewModel {
    private let plexService: PlexService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    /// Server-scoped identity of the episode; every request goes to its server.
    let id: PlexItemID

    var ratingKey: String { id.ratingKey }

    private(set) var details: PlexMediaDetails?
    /// What the card that opened this page was showing. Draws the hero while
    /// `details` loads (`DetailSeeds`).
    let seed: PlexItem?
    private(set) var isLoading = false
    private(set) var error: String?
    /// A failed action (Mark Watched and the like). Shown as an alert, because
    /// `error` only shows while the screen has no content.
    var actionError: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0

    init(
        id: PlexItemID,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        self.id = id
        self.seed = DetailSeeds.item(for: id)
        self.plexService = plexService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
    }

    func load() async {
        guard details == nil else { return }
        await refresh()
    }

    func refresh() async {
        await reload()
    }

    func toggleWatched() async {
        guard let details else { return }
        let targetWatched = !isWatched

        // A download only takes the offline path when its server is unreachable;
        // online, the write fans out across servers and re-reads the details.
        if isUsingCachedData || (isPlayableOffline && plexService.pool.connection(for: serverID) == nil) {
            offlinePlaybackSyncManager?.recordWatchState(
                serverID: serverID,
                ratingKey: details.ratingKey,
                watched: targetWatched
            )
            offlineStateVersion += 1
            await offlinePlaybackSyncManager?.syncPendingActions(force: true)
            return
        }

        do {
            try await plexService.setWatchedAcrossServers(
                targetWatched,
                id: PlexItemID(serverID: serverID, ratingKey: details.ratingKey)
            )
            await reload()
        } catch {
            if isPlayableOffline {
                offlinePlaybackSyncManager?.recordWatchState(
                    serverID: serverID,
                    ratingKey: details.ratingKey,
                    watched: targetWatched
                )
                offlineStateVersion += 1
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    var seasonLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: details?.parentIndex, episode: nil)
    }

    var seasonID: PlexItemID? {
        details?.parentRatingKey.map { PlexItemID(serverID: serverID, ratingKey: $0) }
    }

    var episodeLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: nil, episode: details?.index)
    }

    var showTitle: String? {
        details?.grandparentTitle
    }

    var showID: PlexItemID? {
        details?.grandparentRatingKey.map { PlexItemID(serverID: serverID, ratingKey: $0) }
    }

    var formattedDuration: String? {
        MediaTextFormatter.shortDuration(milliseconds: details?.duration)
    }

    var isWatched: Bool {
        guard let details else { return false }
        _ = offlineStateVersion
        let fallback = isWatched(details)
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID,
            ratingKey: details.ratingKey,
            fallback: fallback
        ) ?? fallback
    }

    var isPlayableOffline: Bool {
        downloadManager?.isPlayableOffline(id: id) == true
    }

    var offlineBannerText: String? {
        guard DownloadsFeature.isVisible, isUsingCachedData else { return nil }
        return isPlayableOffline
            ? "Showing saved episode metadata. This episode is available offline."
            : "Showing saved episode metadata. This episode is not downloaded on this device."
    }

    /// - Parameter hidesStill: Hide Spoilers and the episode is unstarted: the
    ///   show's art stands in for its still.
    func backdropURL(width: Int, height: Int, hidesStill: Bool = false) -> URL? {
        let path = hidesStill
            ? details?.art ?? seed?.art
            : details != nil ? details?.thumb ?? details?.art : seed?.thumb ?? seed?.art
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        let path = details?.parentThumb ?? details?.grandparentThumb ?? details?.thumb
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    /// The show's title logo (clear-logo art) inherited onto the episode metadata.
    /// Used in place of the show-name text in the iOS episode hero; nil when Plex
    /// didn't attach a clear logo, in which case the hero falls back to text.
    func showTitleLogoURL(width: Int, height: Int) -> URL? {
        let path = details != nil ? details?.clearLogo : seed?.clearLogo
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    private func reload() async {
        isLoading = true
        error = nil

        // Seed from the offline cache only on a first load; a refresh over live
        // data would flash the values saved at download time. A live answer
        // from the last few minutes beats the download-time copy.
        var seededFromRecent = false
        if details == nil, let recentDetails = plexService.recentMediaDetails(for: id) {
            details = recentDetails
            seededFromRecent = true
        } else if details == nil, let cachedDetails = downloadManager?.cachedMediaDetails(for: id) {
            details = cachedDetails
            isUsingCachedData = true
        }

        do {
            details = try await plexService.getMediaDetails(ratingKey: ratingKey, serverID: serverID)
            isUsingCachedData = false
        } catch {
            // Recent metadata that could not be revalidated is offline data.
            if seededFromRecent { isUsingCachedData = true }
            if details == nil {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func isWatched(_ details: PlexMediaDetails) -> Bool {
        guard let viewCount = details.viewCount else { return false }
        return viewCount > 0
    }

    /// The route's server wins; the download record and the primary server are
    /// only fallbacks for an id that reached us without one (an offline cache).
    var serverID: String? {
        id.serverID
            ?? downloadManager?.serverID(for: id)
            ?? plexService.pool.primary?.serverID
    }
}

// MARK: - Subtitle Search

extension EpisodeDetailViewModel {
    /// Gated exactly like the player's entry point: Plex only lets the server
    /// owner (and non-restricted Home users) write sidecar files, and there has
    /// to be a real part on disk to write next to.
    var canDownloadSubtitles: Bool {
        plexService.canDownloadSubtitles(serverID: serverID) && !isUsingCachedData && hasPlayablePart
    }

    private var hasPlayablePart: Bool {
        details?.media.contains { !$0.parts.isEmpty } == true
    }

    /// Builds the flow's view model so the view never reaches for `PlexService`.
    /// Re-reading the item afterwards is what surfaces the new subtitle stream in
    /// the media info; the next playback session mounts it on its own.
    func makeSubtitleSearchViewModel(preferredLanguageCode: String?) -> SubtitleSearchViewModel {
        SubtitleSearchViewModel(
            plexService: plexService,
            ratingKey: ratingKey,
            serverID: serverID,
            preferredLanguageCode: preferredLanguageCode
        ) { [weak self] _ in
            await self?.refresh()
        }
    }
}
#endif
