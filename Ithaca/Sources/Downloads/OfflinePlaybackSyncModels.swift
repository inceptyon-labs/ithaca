import Foundation

enum OfflinePlaybackSyncActionKind: String, Codable, Sendable {
    case progress
    case watched
    case unwatched
}

struct OfflinePlaybackSyncAction: Codable, Sendable, Identifiable, Hashable {
    var id: String { globalKey }

    /// Stable Plex Home identity that owns this local watch-state mutation.
    /// Nil identifies an action written before Plex Home support.
    var accountProfileID: String? = nil
    /// Machine identifier of the server this action has to be replayed on.
    /// Mutable only so an action written before servers were identified by
    /// machine identifier can be re-keyed (see `OfflinePlaybackSyncManager`).
    var serverID: String
    let ratingKey: String
    var kind: OfflinePlaybackSyncActionKind
    var viewOffsetMs: Int?
    var durationMs: Int?
    var shouldMarkWatched: Bool
    var plexState: String?
    var needsSync: Bool
    var attemptCount: Int
    var lastAttemptAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// When the local write happened, moved forward each time it reaches Plex.
    /// Compared with Plex's `lastViewedAt` to tell which side changed last.
    var writtenAt: Date
    /// Plex's state from the newest live fetch of this item. Offline it stands
    /// in for the metadata saved at download time, which is never refreshed.
    var plexWatchState: PlexWatchState? = nil

    var globalKey: String {
        DownloadedMediaRecord.globalKey(
            accountProfileID: accountProfileID,
            serverID: serverID,
            ratingKey: ratingKey
        )
    }

    enum CodingKeys: String, CodingKey {
        case accountProfileID, serverID, ratingKey, kind
        case viewOffsetMs, durationMs, shouldMarkWatched, plexState
        case needsSync, attemptCount, lastAttemptAt, createdAt, updatedAt
        case writtenAt, plexWatchState
    }
}

extension OfflinePlaybackSyncAction {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountProfileID = try container.decodeIfPresent(String.self, forKey: .accountProfileID)
        serverID = try container.decode(String.self, forKey: .serverID)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        kind = try container.decode(OfflinePlaybackSyncActionKind.self, forKey: .kind)
        viewOffsetMs = try container.decodeIfPresent(Int.self, forKey: .viewOffsetMs)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        shouldMarkWatched = try container.decode(Bool.self, forKey: .shouldMarkWatched)
        plexState = try container.decodeIfPresent(String.self, forKey: .plexState)
        needsSync = try container.decode(Bool.self, forKey: .needsSync)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        writtenAt = try container.decodeIfPresent(Date.self, forKey: .writtenAt) ?? updatedAt
        plexWatchState = try container.decodeIfPresent(PlexWatchState.self, forKey: .plexWatchState)
    }
}

/// What Plex reported for an item in one live fetch.
struct PlexWatchState: Codable, Sendable, Hashable {
    var viewOffsetMs: Int?
    var watched: Bool
    /// The last time any device played or marked the item, by Plex's clock.
    var lastViewedAt: Date?
    /// When the request was sent. The response includes every write that
    /// reached Plex before this moment.
    var requestedAt: Date

    init(viewOffsetMs: Int?, watched: Bool, lastViewedAt: Date?, requestedAt: Date) {
        self.viewOffsetMs = viewOffsetMs.flatMap { $0 > 0 ? $0 : nil }
        self.watched = watched
        self.lastViewedAt = lastViewedAt
        self.requestedAt = requestedAt
    }

    init(report: PlexWatchStateReport, requestedAt: Date) {
        self.init(
            viewOffsetMs: report.viewOffsetMs,
            watched: (report.viewCount ?? 0) > 0,
            lastViewedAt: report.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            requestedAt: requestedAt
        )
    }

    func hasSameState(as other: PlexWatchState) -> Bool {
        viewOffsetMs == other.viewOffsetMs && watched == other.watched && lastViewedAt == other.lastViewedAt
    }
}

extension OfflinePlaybackSyncAction {
    /// How far apart the device's and the server's clocks may be before a Plex
    /// change counts as newer than a local write.
    static let clockSkewAllowance: TimeInterval = 300

    /// True once a fetch sent after the local write reached Plex has come back.
    /// Plex then holds that write or something newer, so Plex's state wins.
    var isSupersededByPlex: Bool {
        guard !needsSync, let plexWatchState else { return false }
        return plexWatchState.requestedAt > writtenAt
    }

    func effectiveViewOffsetMs(fallback: Int?) -> Int? {
        if isSupersededByPlex { return plexWatchState?.viewOffsetMs }
        let base: Int? = if let plexWatchState { plexWatchState.viewOffsetMs } else { fallback }
        guard kind == .progress, let viewOffsetMs, viewOffsetMs > 0 else { return base }
        return viewOffsetMs
    }

    func effectiveWatched(fallback: Bool) -> Bool {
        if isSupersededByPlex, let plexWatchState { return plexWatchState.watched }
        switch kind {
        case .watched:
            return true
        case .unwatched:
            return false
        case .progress:
            return shouldMarkWatched || (plexWatchState?.watched ?? fallback)
        }
    }

    /// Records a live Plex fetch of this item. A write not yet sent is dropped
    /// when Plex changed after it, so it can't rewind another device's progress.
    /// Returns false when nothing visible changed.
    mutating func applyPlexState(_ state: PlexWatchState) -> Bool {
        if let current = plexWatchState, current.requestedAt > state.requestedAt {
            return false
        }
        var updated = self
        if updated.needsSync,
           let plexChangedAt = state.lastViewedAt,
           plexChangedAt > updated.writtenAt.addingTimeInterval(Self.clockSkewAllowance) {
            updated.needsSync = false
            updated.attemptCount = 0
        }
        updated.plexWatchState = state
        if let current = plexWatchState,
           current.hasSameState(as: state),
           updated.needsSync == needsSync,
           updated.isSupersededByPlex == isSupersededByPlex {
            return false
        }
        self = updated
        return true
    }
}

struct OfflinePlaybackSyncSnapshot: Codable, Sendable {
    var actions: [OfflinePlaybackSyncAction] = []
}
