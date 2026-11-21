import Foundation
import OSLog

private let smartDownloadsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Ithaca",
    category: "SmartDownloads"
)

/// Smart Downloads (iOS, Settings → Downloads). For every show the active
/// profile has an episode of on this device, a pass removes the episodes the
/// profile has watched from the device and keeps the next
/// `smartDownloadEpisodeCount` unwatched ones downloaded or queued.
///
/// Only local files and records change, through `DownloadManager`'s own delete
/// and queue paths, so Wi-Fi Only, quality, concurrency and Keep Free still
/// apply. Nothing on the server is ever deleted. Owned by `DownloadManager`
/// (`smartDownloads`); nil on tvOS.
@MainActor
final class SmartDownloads {
    private let plexService: PlexService
    private let preferences: UserPreferences
    private unowned let downloadManager: DownloadManager
    private let playbackSync: OfflinePlaybackSyncManager
    /// While the player is up nothing is removed: it may be reading a file,
    /// or about to, while it loads. A later pass removes what was held back.
    private let isPlayerShowing: @MainActor () -> Bool

    private var passTask: Task<Void, Never>?
    private var passGeneration = 0
    private var isRerunRequested = false
    /// A pass is asked to queue whatever the window needs, not only when it
    /// has moved: the setting was just turned on or the count changed.
    private var isRefillRequested = false

    /// The furthest finished episode each show's window was last filled
    /// after, by profile, server and show. Queueing waits for it to move, so a
    /// download the viewer cancelled or deleted isn't fetched again.
    private static let windowsKey = "smartDownloadsWindows"
    private var windows: [String: String] = UserDefaults.standard.dictionary(forKey: windowsKey) as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(windows, forKey: Self.windowsKey) }
    }

    init(
        plexService: PlexService,
        preferences: UserPreferences,
        downloadManager: DownloadManager,
        playbackSync: OfflinePlaybackSyncManager,
        isPlayerShowing: @escaping @MainActor () -> Bool = { false }
    ) {
        self.plexService = plexService
        self.preferences = preferences
        self.downloadManager = downloadManager
        self.playbackSync = playbackSync
        self.isPlayerShowing = isPlayerShowing
        // Launch, becoming active and every upload of offline watch states end
        // in a sync; Plex's watch state is as current as it gets right after.
        playbackSync.didFinishSync = { [weak self] in
            Task { await self?.run() }
        }
        observePreferences()
    }

    /// Runs a pass. A request while one is running is coalesced into one more
    /// pass right after it, since it may come from a change the running pass
    /// has already read past. Returns once the pass covering this request is
    /// done.
    /// - Parameter refills: queue what each window needs even if it hasn't
    ///   moved since it was last filled.
    func run(refills: Bool = false) async {
        isRefillRequested = isRefillRequested || refills
        if let passTask {
            isRerunRequested = true
            await passTask.value
            return
        }
        passGeneration += 1
        let generation = passGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                isRerunRequested = false
                let refills = isRefillRequested
                isRefillRequested = false
                await performPass(refills: refills)
            } while isRerunRequested && !Task.isCancelled
            if passGeneration == generation {
                passTask = nil
            }
        }
        passTask = task
        await task.value
    }

    /// Ends the running pass before a profile switch or sign-out
    /// (`DownloadManager.prepareForProfileSwitch`), so a plan made for one
    /// profile is never applied to the next one's downloads.
    func stop() {
        isRerunRequested = false
        isRefillRequested = false
        passTask?.cancel()
        passTask = nil
    }

    /// Turning the setting on, or raising the count, applies it right away.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.smartDownloadsEnabled
            _ = preferences.smartDownloadEpisodeCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                observePreferences()
                if preferences.smartDownloadsEnabled {
                    await run(refills: true)
                }
            }
        }
    }

    private func performPass(refills: Bool) async {
        guard let profileID = plexService.activeProfileID?.nilIfEmpty,
              canContinue(as: profileID),
              // Offline the next episodes can't be known, so nothing changes.
              playbackSync.isNetworkAvailable else {
            return
        }

        let shows = showsOnDevice()
        // A show gone from the device fills its window afresh if it comes back.
        let kept = Set(shows.map { "\(profileID)|\($0.serverID ?? "")|\($0.ratingKey)" })
        let stale = windows.keys.filter { $0.hasPrefix("\(profileID)|") && !kept.contains($0) }
        if !stale.isEmpty { windows = windows.filter { !stale.contains($0.key) } }

        for show in shows {
            guard canContinue(as: profileID) else { return }
            guard let serverID = show.serverID,
                  plexService.pool.connection(for: serverID) != nil else {
                continue
            }
            do {
                try await update(show: show, serverID: serverID, profileID: profileID, refills: refills)
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                smartDownloadsLogger.error(
                    "Smart Downloads skipped show \(show.ratingKey, privacy: .public) on \(serverID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Whether the pass may still act for `profileID`. Checked again after
    /// every suspension: a switch, sign-out or the setting turning off may have
    /// happened meanwhile.
    private func canContinue(as profileID: String) -> Bool {
        !Task.isCancelled
            && preferences.smartDownloadsEnabled
            && plexService.isSessionReady
            && !downloadManager.isProfileSwitching
            && plexService.activeProfileID == profileID
    }

    private func update(show: PlexItemID, serverID: String, profileID: String, refills: Bool) async throws {
        // `fetchMetadata` hands the listing's watch states to the sync manager
        // before it returns, so the effective states below already include it.
        let episodes = try await plexService.getAllEpisodes(showKey: show.ratingKey, serverID: serverID)
        guard canContinue(as: profileID) else { throw CancellationError() }
        // The user, or Delete All, may have removed the show meanwhile.
        guard !episodeRecords(of: show).isEmpty else { return }

        // Any record counts as on the device, whatever its status: a paused or
        // failed download is the user's to resume or retry.
        let records = downloadManager.records.filter { $0.serverID == serverID }
        let onDevice = Set(records.map(\.ratingKey))
        let downloadedAt = Dictionary(records.map { ($0.ratingKey, $0.addedAt) }) { first, _ in first }
        let plan = SmartDownloadsPlan(
            episodes: episodes.map { episode in
                SmartDownloadsEpisode(
                    episode,
                    watched: playbackSync.effectiveWatched(
                        serverID: serverID,
                        ratingKey: episode.ratingKey,
                        fallback: episode.isWatched
                    ),
                    viewOffsetMs: playbackSync.effectiveViewOffsetMs(
                        serverID: serverID,
                        ratingKey: episode.ratingKey,
                        fallback: episode.viewOffset
                    )
                )
            },
            onDevice: onDevice,
            downloadedAt: downloadedAt,
            keepReadyCount: preferences.smartDownloadEpisodeCount.rawValue
        )

        let removals = isPlayerShowing() ? [] : plan.ratingKeysToRemove
        for ratingKey in removals {
            downloadManager.deleteDownload(id: PlexItemID(serverID: serverID, ratingKey: ratingKey))
        }

        // A show seen for the first time fills its window; after that only
        // watching further does, or a refill.
        let windowKey = "\(profileID)|\(serverID)|\(show.ratingKey)"
        let furthest = plan.furthestFinishedRatingKey ?? ""
        guard refills || windows[windowKey] != furthest else { return logged(show, serverID, removals.count, 0) }
        windows[windowKey] = furthest

        let episodesByKey = Dictionary(episodes.map { ($0.ratingKey, $0) }) { first, _ in first }
        var queuedCount = 0
        for ratingKey in plan.ratingKeysToQueue {
            guard canContinue(as: profileID) else { throw CancellationError() }
            guard let episode = episodesByKey[ratingKey] else { continue }
            // Queued without lifting Pause All: an automatic download must not
            // restart a queue the user stopped.
            await downloadManager.queueDownload(episode: episode, liftsPauseAll: false)
            queuedCount += 1
        }

        logged(show, serverID, removals.count, queuedCount)
    }

    private func logged(_ show: PlexItemID, _ serverID: String, _ removed: Int, _ queued: Int) {
        guard removed > 0 || queued > 0 else { return }
        smartDownloadsLogger.info(
            "Smart Downloads: show \(show.ratingKey, privacy: .public) on \(serverID, privacy: .public): removed \(removed) watched, queued \(queued)"
        )
    }

    /// Shows with at least one of this profile's episodes on the device,
    /// downloaded or in the queue, by server and show key.
    private func showsOnDevice() -> [PlexItemID] {
        var seen: Set<PlexItemID> = []
        return downloadManager.records
            .compactMap { showID(of: $0) }
            .filter { seen.insert($0).inserted }
    }

    private func episodeRecords(of show: PlexItemID) -> [DownloadedMediaRecord] {
        downloadManager.records.filter { showID(of: $0) == show }
    }

    /// The show a record keeps on the device. Records being deleted keep
    /// nothing; a record queued before its show key was known joins once its
    /// download starts and the key is filled in.
    private func showID(of record: DownloadedMediaRecord) -> PlexItemID? {
        guard record.type == .episode,
              let showKey = record.grandparentRatingKey,
              !downloadManager.deletingDownloadIDs.contains(record.globalKey) else {
            return nil
        }
        return PlexItemID(serverID: record.serverID, ratingKey: showKey)
    }
}

/// One episode as a smart downloads pass sees it: Plex's listing with this
/// device's offline watch state laid over it.
struct SmartDownloadsEpisode: Sendable {
    let ratingKey: String
    let seasonNumber: Int?
    let watched: Bool
    let viewOffsetMs: Int?
    let durationMs: Int?
    /// When Plex last saw it watched.
    let lastViewedAt: Date?

    init(_ episode: PlexEpisode, watched: Bool, viewOffsetMs: Int?) {
        ratingKey = episode.ratingKey
        seasonNumber = episode.parentIndex
        self.watched = watched
        self.viewOffsetMs = viewOffsetMs
        durationMs = episode.duration
        lastViewedAt = episode.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Watched, and not started again: a rewatch stopped before the 90 percent
    /// watched point (the scrobble threshold) counts as unwatched, like a
    /// first watch in progress.
    var isFinished: Bool {
        guard watched else { return false }
        guard let viewOffsetMs, viewOffsetMs > 0 else { return true }
        guard let durationMs, durationMs > 0 else { return false }
        return Double(viewOffsetMs) >= Double(durationMs) * 0.9
    }
}

/// What one pass does for one show. Pure, so the rules are tested without
/// Plex (`SmartDownloadsTests`).
struct SmartDownloadsPlan: Equatable, Sendable {
    /// Episodes on the device the profile has watched since downloading them,
    /// to remove from it. One watched before it was downloaded is a rewatch
    /// the viewer asked for, and stays.
    let ratingKeysToRemove: [String]
    /// The next unwatched episodes not on the device yet, in viewing order.
    let ratingKeysToQueue: [String]
    /// The episode the window starts after; nil before any is finished.
    let furthestFinishedRatingKey: String?

    /// - Parameters:
    ///   - episodes: the show's episodes in Plex's viewing order (`allLeaves`).
    ///   - onDevice: rating keys with a download record of any status.
    ///   - downloadedAt: when each record was added. An episode watched only
    ///     before then isn't removed; without a date it is.
    ///   - keepReadyCount: unwatched episodes to keep after the last watched one.
    init(
        episodes: [SmartDownloadsEpisode],
        onDevice: Set<String>,
        downloadedAt: [String: Date] = [:],
        keepReadyCount: Int
    ) {
        ratingKeysToRemove = episodes
            .filter { episode in
                guard episode.isFinished, onDevice.contains(episode.ratingKey) else { return false }
                guard let added = downloadedAt[episode.ratingKey], let viewed = episode.lastViewedAt else { return true }
                return viewed > added
            }
            .map(\.ratingKey)
        // Specials sit outside the story's order: removed once watched, never
        // queued.
        let story = episodes.filter { $0.seasonNumber != 0 }
        let furthest = story.lastIndex(where: \.isFinished)
        furthestFinishedRatingKey = furthest.map { story[$0].ratingKey }
        let next = furthest.map { $0 + 1 } ?? story.startIndex
        ratingKeysToQueue = story[next...]
            .prefix(max(keepReadyCount, 0))
            .filter { !onDevice.contains($0.ratingKey) }
            .map(\.ratingKey)
    }
}
