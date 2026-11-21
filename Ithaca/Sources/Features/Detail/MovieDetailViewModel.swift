import Foundation

@MainActor
@Observable
final class MovieDetailViewModel {
    private let plexService: PlexService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    /// Server-scoped identity of the movie. Every request this model makes goes
    /// to `id.serverID`, never to whichever server happens to be primary.
    let id: PlexItemID

    var ratingKey: String { id.ratingKey }

    /// What the card that opened this page was showing. Draws the hero while
    /// `details` loads (`DetailSeeds`).
    let seed: PlexItem?
    private(set) var details: PlexMediaDetails?
    private(set) var isLoading = false
    private(set) var error: String?
    /// A failed action (Mark Watched and the like). Shown as an alert, because
    /// `error` only shows while the screen has no content.
    var actionError: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0
    /// Trailers, featurettes and the like. Loaded once per page, after the
    /// details, and never from offline data: they play from the server.
    private(set) var extras: [PlexItem] = []
    @ObservationIgnored private var hasLoadedExtras = false
    @ObservationIgnored private var extrasTask: Task<Void, Never>?

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

    func loadDetails() async {
        guard details == nil else { return }
        await refreshDetails()
    }

    func refreshDetails() async {
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
            // Without a download nothing can play from it, so fall back like a
            // first load: the download-time copy, else the error with Retry.
            if seededFromRecent {
                if isPlayableOffline {
                    isUsingCachedData = true
                } else {
                    details = downloadManager?.cachedMediaDetails(for: id)
                    isUsingCachedData = details != nil
                }
            }
            if details == nil {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
        startExtrasLoad()
    }

    /// Loads the extras in the background after a refresh, so they never hold
    /// up the page. Runs until one load succeeds: a failed first load, Retry,
    /// or offline data that comes back online all try again.
    private func startExtrasLoad() {
        guard !hasLoadedExtras, extrasTask == nil else { return }
        extrasTask = Task { [weak self] in
            await self?.loadExtras()
            self?.extrasTask = nil
        }
    }

    private func loadExtras() async {
        guard !hasLoadedExtras, details != nil, !isUsingCachedData else { return }
        do {
            extras = try await plexService.getExtras(ratingKey: ratingKey, serverID: serverID)
            hasLoadedExtras = true
        } catch {
            // No row; the next refresh tries again.
        }
    }

    /// The trailer the tvOS hero previews: Plex's main trailer, else the first.
    var previewTrailer: PlexItem? {
        PlexItem.previewTrailer(in: extras, primaryExtraKey: details?.primaryExtraKey)
    }

    func toggleWatched() async {
        guard details != nil else { return }
        let targetWatched = !isWatched

        // A download only takes the offline path when its server is unreachable;
        // online, the write fans out across servers and re-reads the details.
        if isUsingCachedData || (isPlayableOffline && plexService.pool.connection(for: serverID) == nil) {
            offlinePlaybackSyncManager?.recordWatchState(
                serverID: serverID,
                ratingKey: ratingKey,
                watched: targetWatched
            )
            offlineStateVersion += 1
            await offlinePlaybackSyncManager?.syncPendingActions(force: true)
            return
        }

        do {
            try await plexService.setWatchedAcrossServers(
                targetWatched,
                id: PlexItemID(serverID: serverID, ratingKey: ratingKey)
            )
            self.details = try await plexService.getMediaDetails(ratingKey: ratingKey, serverID: serverID)
        } catch {
            if isPlayableOffline {
                offlinePlaybackSyncManager?.recordWatchState(
                    serverID: serverID,
                    ratingKey: ratingKey,
                    watched: targetWatched
                )
                offlineStateVersion += 1
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: - Rating

    private var pendingRating = PendingTasteRating()

    /// The viewer's rating, shown by the hero's rating button.
    var tasteRating: PlexTasteRating? {
        pendingRating.resolved(stored: details?.userRating)
    }

    /// Saves the rating on every copy of the title, then re-reads the details.
    func rate(_ rating: PlexTasteRating?) async {
        guard details != nil else { return }
        pendingRating.begin(rating)
        defer { pendingRating.end() }
        do {
            try await plexService.setRatingAcrossServers(
                rating,
                id: PlexItemID(serverID: serverID, ratingKey: ratingKey)
            )
        } catch {
            actionError = error.localizedDescription
            return
        }
        if let refreshed = try? await plexService.getMediaDetails(ratingKey: ratingKey, serverID: serverID) {
            details = refreshed
        }
    }

    // MARK: - Computed Helpers

    var isWatched: Bool {
        _ = offlineStateVersion
        let fallback = (details?.viewCount ?? 0) > 0
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID,
            ratingKey: ratingKey,
            fallback: fallback
        ) ?? fallback
    }

    var isPlayableOffline: Bool {
        downloadManager?.isPlayableOffline(id: id) == true
    }

    var offlineBannerText: String? {
        guard DownloadsFeature.isVisible, isUsingCachedData else { return nil }
        return isPlayableOffline
            ? "Showing saved movie metadata. This movie is available offline."
            : "Showing saved movie metadata. This movie is not downloaded on this device."
    }

    var resumePositionSeconds: TimeInterval? {
        _ = offlineStateVersion
        guard let offset = offlinePlaybackSyncManager?.effectiveViewOffsetMs(
            serverID: serverID,
            ratingKey: ratingKey,
            fallback: details?.viewOffset
        ) ?? details?.viewOffset, offset > 0 else { return nil }
        return TimeInterval(offset) / 1000.0
    }

    var formattedDuration: String? {
        MediaTextFormatter.playbackDuration(milliseconds: details?.duration)
    }

    var formattedResume: String? {
        guard let seconds = resumePositionSeconds else { return nil }
        return MediaTextFormatter.playbackDuration(milliseconds: Int(seconds * 1000))
    }

    var mediaInfo: String? {
        guard let media = details?.media.first else { return nil }
        var parts: [String] = []
        if let res = media.videoResolution?.uppercased() {
            parts.append(res)
        }
        if let codec = media.videoCodec?.uppercased() {
            parts.append(codec)
        }
        if let audioCodec = media.audioCodec?.uppercased() {
            parts.append(audioCodec)
        }
        if let channels = media.audioChannels {
            parts.append("\(channels)ch")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var genreText: String? {
        guard let genres = details?.genres, !genres.isEmpty else { return nil }
        return genres.prefix(3).map(\.tag).joined(separator: ", ")
    }

    var directorText: String? {
        guard let directors = details?.directors, !directors.isEmpty else { return nil }
        return directors.map(\.tag).joined(separator: ", ")
    }

    func posterURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.thumb)
            ?? plexService.imageURL(for: details?.thumb, serverID: serverID, width: width, height: height)
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        let path = details != nil ? details?.art : seed?.art
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    func titleLogoURL(width: Int, height: Int) -> URL? {
        let path = details != nil ? details?.clearLogo : seed?.clearLogo
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
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

extension MovieDetailViewModel {
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
            await self?.refreshDetails()
        }
    }
}
