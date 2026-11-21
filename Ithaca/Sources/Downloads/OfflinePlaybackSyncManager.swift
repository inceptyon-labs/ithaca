import Foundation
import Network
import Observation
import OSLog

private let syncLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Ithaca",
    category: "OfflinePlaybackSync"
)

@MainActor
@Observable
final class OfflinePlaybackSyncManager {
    private static let syncAttemptInterval: TimeInterval = 60
    private static let retryLoopInterval: Duration = .seconds(60)

    private let plexService: PlexService
    private let store: OfflinePlaybackSyncStore

    private(set) var storedActions: [OfflinePlaybackSyncAction] = []
    private(set) var isSyncing = false
    private(set) var isNetworkAvailable = false
    @ObservationIgnored private var lastSyncAttemptAt: Date?
    @ObservationIgnored private var isPreparingProfileSwitch = false
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private let networkMonitorQueue = DispatchQueue(label: "com.inceptyon.ithaca.offlinePlaybackSync.networkMonitor")
    @ObservationIgnored private var retryLoopTask: Task<Void, Never>?
    /// Called after a forced sync (launch, becoming active, Sync Watch Progress
    /// Now) and after any other sync that sent something, outside a profile
    /// switch: Plex then has every watch state this device could send. Smart
    /// Downloads runs here.
    @ObservationIgnored var didFinishSync: (@MainActor () -> Void)?

    init(
        plexService: PlexService,
        store: OfflinePlaybackSyncStore = OfflinePlaybackSyncStore()
    ) {
        self.plexService = plexService
        self.store = store
        storedActions = store.loadSnapshot().actions
        startNetworkMonitoring()
        plexService.watchStateObserver = { [weak self] reports, requestedAt in
            self?.recordPlexWatchStates(reports, requestedAt: requestedAt)
        }
    }

    deinit {
        networkMonitor?.cancel()
        retryLoopTask?.cancel()
    }

    var actions: [OfflinePlaybackSyncAction] {
        storedActions.filter { $0.accountProfileID == plexService.activeProfileID }
    }

    var pendingSyncCount: Int {
        actions.filter(\.needsSync).count
    }

    func recordProgress(
        serverID: String?,
        ratingKey: String,
        viewOffsetMs: Int,
        durationMs: Int,
        state: PlaybackState = .stopped
    ) {
        guard let serverID = serverID?.nilIfEmpty else { return }
        let shouldMarkWatched = durationMs > 0 && Double(viewOffsetMs) / Double(durationMs) >= 0.9
        upsertAction(
            serverID: serverID,
            ratingKey: ratingKey,
            kind: .progress,
            viewOffsetMs: viewOffsetMs,
            durationMs: durationMs,
            shouldMarkWatched: shouldMarkWatched,
            plexState: Self.plexStateString(for: state)
        )
    }

    func recordWatchState(serverID: String?, ratingKey: String, watched: Bool) {
        guard let serverID = serverID?.nilIfEmpty else { return }
        upsertAction(
            serverID: serverID,
            ratingKey: ratingKey,
            kind: watched ? .watched : .unwatched,
            viewOffsetMs: nil,
            durationMs: nil,
            shouldMarkWatched: watched,
            plexState: nil
        )
    }

    /// Drops the profile's synced actions. Pending ones stay so the watch
    /// progress still reaches Plex once their server is back.
    func deleteAllLocalState() {
        let activeProfileID = plexService.activeProfileID
        storedActions.removeAll { $0.accountProfileID == activeProfileID && !$0.needsSync }
        persist()
    }

    /// Flushes the outgoing profile while its Plex token and server are still
    /// active, then stops retries so a later callback cannot use another
    /// profile's credentials.
    func prepareForProfileSwitch() async {
        isPreparingProfileSwitch = true
        stopAutomaticSync()
        while isSyncing {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        await syncPendingActions(force: true)
    }

    /// Refreshes profile-scoped state after PlexService has installed the new
    /// identity. Legacy adoption must only be requested for the original
    /// pre-Plex-Home account.
    func activateProfile() {
        if plexService.shouldAdoptLegacyProfileData,
           let primaryProfileID = plexService.primaryProfileID?.nilIfEmpty {
            var changed = false
            for index in storedActions.indices where storedActions[index].accountProfileID == nil {
                storedActions[index].accountProfileID = primaryProfileID
                changed = true
            }
            if changed {
                persist()
            }
        }
        lastSyncAttemptAt = nil
        isPreparingProfileSwitch = false
        startAutomaticSync()
    }

    func effectiveViewOffsetMs(serverID: String?, ratingKey: String, fallback: Int?) -> Int? {
        guard let action = action(serverID: serverID, ratingKey: ratingKey) else { return fallback }
        return action.effectiveViewOffsetMs(fallback: fallback)
    }

    func effectiveWatched(serverID: String?, ratingKey: String, fallback: Bool) -> Bool {
        guard let action = action(serverID: serverID, ratingKey: ratingKey) else { return fallback }
        return action.effectiveWatched(fallback: fallback)
    }

    /// Keeps each action's copy of Plex's state current. `PlexService` calls
    /// this for every live metadata fetch.
    func recordPlexWatchStates(_ reports: [PlexWatchStateReport], requestedAt: Date) {
        guard !storedActions.isEmpty,
              !isPreparingProfileSwitch,
              let activeProfileID = plexService.activeProfileID?.nilIfEmpty else {
            return
        }
        var indexByKey: [String: Int] = [:]
        for (index, action) in storedActions.enumerated() where action.accountProfileID == activeProfileID {
            indexByKey[action.globalKey] = index
        }
        guard !indexByKey.isEmpty else { return }

        var changed = false
        for report in reports {
            let globalKey = DownloadedMediaRecord.globalKey(
                accountProfileID: activeProfileID,
                serverID: report.serverID,
                ratingKey: report.ratingKey
            )
            if applyPlexState(PlexWatchState(report: report, requestedAt: requestedAt), toActionAt: indexByKey[globalKey]) {
                changed = true
            }
        }
        if changed {
            persist()
        }
    }

    @discardableResult
    private func applyPlexState(_ state: PlexWatchState, toActionAt index: Int?) -> Bool {
        guard let index else { return false }
        var action = storedActions[index]
        guard action.applyPlexState(state) else { return false }
        storedActions[index] = action
        return true
    }

    func syncPendingActions(force: Bool = false) async {
        guard !isSyncing else { return }
        guard force || !isPreparingProfileSwitch else { return }
        guard force || isNetworkAvailable else { return }
        guard plexService.isSessionReady else { return }
        guard let activeProfileID = plexService.activeProfileID?.nilIfEmpty else { return }

        rekeyLegacyServerIdentifiers()

        let now = Date()
        // Each action goes to the server it was recorded on, and only while that
        // server is connected. Actions for servers that are offline or switched
        // off simply wait — replaying them anywhere else would move watch state
        // on a completely different title.
        let pendingActions = storedActions
            .filter { action in
                action.needsSync &&
                    action.accountProfileID == activeProfileID &&
                    plexService.pool.connection(for: action.serverID) != nil &&
                    (force || shouldAttemptSync(action, now: now))
            }
            .sorted { $0.updatedAt < $1.updatedAt }
        guard !pendingActions.isEmpty else {
            if force {
                notifySyncFinished()
            }
            return
        }

        if !force,
           let lastSyncAttemptAt,
           now.timeIntervalSince(lastSyncAttemptAt) < Self.syncAttemptInterval {
            return
        }
        lastSyncAttemptAt = now

        isSyncing = true
        var sentAny = false
        defer {
            isSyncing = false
            if force || sentAny {
                notifySyncFinished()
            }
        }

        for pendingAction in pendingActions {
            do {
                // Drops this write instead if another device changed the item after it.
                let requestedAt = Date()
                let details = try await plexService.getMediaDetails(
                    ratingKey: pendingAction.ratingKey,
                    serverID: pendingAction.serverID
                )
                let state = PlexWatchState(
                    report: PlexWatchStateReport(serverID: pendingAction.serverID, item: details),
                    requestedAt: requestedAt
                )
                if applyPlexState(state, toActionAt: storedActions.firstIndex { $0.globalKey == pendingAction.globalKey }) {
                    persist()
                }
                guard storedActions.first(where: { $0.globalKey == pendingAction.globalKey })?.needsSync == true else {
                    continue
                }
                try await sync(pendingAction)
                markSynced(pendingAction)
                sentAny = true
            } catch PlexServiceError.httpError(statusCode: 404) {
                // Only the item lookup can 404 for a missing item; the write
                // calls target the same item, so it can never sync.
                discard(pendingAction)
            } catch {
                markAttemptFailed(pendingAction)
            }
        }
    }

    private func notifySyncFinished() {
        guard !isPreparingProfileSwitch else { return }
        didFinishSync?()
    }

    func startAutomaticSync() {
        retryLoopTask?.cancel()
        retryLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.syncPendingActions()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.retryLoopInterval)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await self.syncPendingActions()
            }
        }
    }

    func stopAutomaticSync() {
        retryLoopTask?.cancel()
        retryLoopTask = nil
    }

    private func sync(_ action: OfflinePlaybackSyncAction) async throws {
        switch action.kind {
        case .progress:
            try await plexService.submitTimeline(
                ratingKey: action.ratingKey,
                state: playbackState(for: action.plexState),
                timeMs: action.viewOffsetMs ?? 0,
                durationMs: action.durationMs ?? 0,
                serverID: action.serverID
            )
            if action.shouldMarkWatched {
                // The timeline write moved Plex's lastViewedAt. Record it so a
                // retry after a failed scrobble doesn't read it as another device.
                markWriteReachedPlex(action)
                try await plexService.scrobble(ratingKey: action.ratingKey, serverID: action.serverID)
            }
        case .watched:
            try await plexService.scrobble(ratingKey: action.ratingKey, serverID: action.serverID)
        case .unwatched:
            try await plexService.unscrobble(ratingKey: action.ratingKey, serverID: action.serverID)
        }
    }

    /// Actions queued before servers were identified by machine identifier can
    /// carry the server's base URL instead, which matches no connection and
    /// would keep them pending forever. Re-key them once their server is known;
    /// an address that resolves to nothing is left alone rather than replayed
    /// against a server that would move watch state on a different title.
    private func rekeyLegacyServerIdentifiers() {
        var changed = false
        for index in storedActions.indices {
            let legacyServerID = storedActions[index].serverID
            guard !plexService.isKnownServerID(legacyServerID),
                  let resolved = plexService.serverID(forLegacyConnectionURI: legacyServerID),
                  resolved != legacyServerID else {
                continue
            }
            storedActions[index].serverID = resolved
            changed = true
        }
        guard changed else { return }
        persist()
    }

    private func action(serverID: String?, ratingKey: String) -> OfflinePlaybackSyncAction? {
        guard let serverID = serverID?.nilIfEmpty else { return nil }
        let globalKey = DownloadedMediaRecord.globalKey(
            accountProfileID: plexService.activeProfileID,
            serverID: serverID,
            ratingKey: ratingKey
        )
        return storedActions.first { $0.globalKey == globalKey }
    }

    private func upsertAction(
        serverID: String,
        ratingKey: String,
        kind: OfflinePlaybackSyncActionKind,
        viewOffsetMs: Int?,
        durationMs: Int?,
        shouldMarkWatched: Bool,
        plexState: String?
    ) {
        guard !isPreparingProfileSwitch,
              plexService.isSessionReady,
              let activeProfileID = plexService.activeProfileID?.nilIfEmpty else {
            return
        }
        let globalKey = DownloadedMediaRecord.globalKey(
            accountProfileID: activeProfileID,
            serverID: serverID,
            ratingKey: ratingKey
        )
        if let index = storedActions.firstIndex(where: { $0.globalKey == globalKey }) {
            // Rewinding after passing 90% must not cancel the pending scrobble;
            // only an explicit watched/unwatched action decides it.
            let keepsWatchedMark = kind == .progress
                && storedActions[index].needsSync
                && storedActions[index].shouldMarkWatched
            storedActions[index].kind = kind
            storedActions[index].viewOffsetMs = viewOffsetMs
            storedActions[index].durationMs = durationMs
            storedActions[index].shouldMarkWatched = shouldMarkWatched || keepsWatchedMark
            storedActions[index].plexState = plexState
            storedActions[index].needsSync = true
            storedActions[index].updatedAt = .now
            storedActions[index].writtenAt = .now
        } else {
            storedActions.append(OfflinePlaybackSyncAction(
                accountProfileID: activeProfileID,
                serverID: serverID,
                ratingKey: ratingKey,
                kind: kind,
                viewOffsetMs: viewOffsetMs,
                durationMs: durationMs,
                shouldMarkWatched: shouldMarkWatched,
                plexState: plexState,
                needsSync: true,
                attemptCount: 0,
                lastAttemptAt: nil,
                createdAt: .now,
                updatedAt: .now,
                writtenAt: .now
            ))
        }
        persist()
    }

    private func markSynced(_ action: OfflinePlaybackSyncAction) {
        guard action.accountProfileID == plexService.activeProfileID,
              let index = storedActions.firstIndex(where: { $0.globalKey == action.globalKey }) else {
            return
        }
        guard storedActions[index].updatedAt == action.updatedAt,
              storedActions[index].kind == action.kind,
              storedActions[index].viewOffsetMs == action.viewOffsetMs,
              storedActions[index].durationMs == action.durationMs,
              storedActions[index].plexState == action.plexState else {
            return
        }
        storedActions[index].needsSync = false
        storedActions[index].attemptCount = 0
        storedActions[index].lastAttemptAt = .now
        storedActions[index].updatedAt = .now
        storedActions[index].writtenAt = .now
        persist()
    }

    private func markWriteReachedPlex(_ action: OfflinePlaybackSyncAction) {
        guard let index = storedActions.firstIndex(where: { $0.globalKey == action.globalKey }),
              storedActions[index].updatedAt == action.updatedAt else {
            return
        }
        storedActions[index].writtenAt = .now
        persist()
    }

    private func discard(_ action: OfflinePlaybackSyncAction) {
        guard action.accountProfileID == plexService.activeProfileID else { return }
        syncLogger.notice("Dropping pending sync for \(action.ratingKey, privacy: .public): item no longer exists on server \(action.serverID, privacy: .public)")
        storedActions.removeAll { $0.globalKey == action.globalKey }
        persist()
    }

    private func markAttemptFailed(_ action: OfflinePlaybackSyncAction) {
        guard action.accountProfileID == plexService.activeProfileID,
              let index = storedActions.firstIndex(where: { $0.globalKey == action.globalKey }) else {
            return
        }
        storedActions[index].attemptCount += 1
        storedActions[index].lastAttemptAt = .now
        storedActions[index].updatedAt = .now
        persist()
    }

    private func persist() {
        try? store.saveSnapshot(OfflinePlaybackSyncSnapshot(actions: storedActions))
    }

    private func shouldAttemptSync(_ action: OfflinePlaybackSyncAction, now: Date) -> Bool {
        guard let lastAttemptAt = action.lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= retryDelay(for: action.attemptCount)
    }

    private func retryDelay(for attemptCount: Int) -> TimeInterval {
        switch attemptCount {
        case ...0:
            return 0
        case 1:
            return 60
        case 2:
            return 120
        case 3:
            return 300
        default:
            return 900
        }
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(path)
            }
        }
        monitor.start(queue: networkMonitorQueue)
        networkMonitor = monitor
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = path.status == .satisfied

        if !wasAvailable && isNetworkAvailable {
            Task { @MainActor [weak self] in
                await self?.syncPendingActions()
            }
        }
    }

    private func playbackState(for value: String?) -> PlaybackState {
        switch value {
        case "playing":
            return .playing
        case "paused":
            return .paused
        default:
            return .stopped
        }
    }

    private static func plexStateString(for state: PlaybackState) -> String {
        switch state {
        case .playing:
            return "playing"
        case .paused:
            return "paused"
        default:
            return "stopped"
        }
    }
}
