import Foundation
import Testing
@testable import Ithaca

/// Which watch state wins between a local offline write and Plex.
@Suite("Offline playback sync")
struct OfflinePlaybackSyncTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func action(
        kind: OfflinePlaybackSyncActionKind = .progress,
        offsetMs: Int? = 2_400_000,
        needsSync: Bool,
        writtenAt: Date,
        plex: PlexWatchState? = nil
    ) -> OfflinePlaybackSyncAction {
        OfflinePlaybackSyncAction(
            accountProfileID: "profile",
            serverID: "server-a",
            ratingKey: "100",
            kind: kind,
            viewOffsetMs: offsetMs,
            durationMs: 7_200_000,
            shouldMarkWatched: false,
            plexState: "stopped",
            needsSync: needsSync,
            attemptCount: 0,
            lastAttemptAt: nil,
            createdAt: writtenAt,
            updatedAt: writtenAt,
            writtenAt: writtenAt,
            plexWatchState: plex
        )
    }

    private func plex(offsetMs: Int?, watched: Bool = false, lastViewedAfter: TimeInterval?, requestedAfter: TimeInterval) -> PlexWatchState {
        PlexWatchState(
            viewOffsetMs: offsetMs,
            watched: watched,
            lastViewedAt: lastViewedAfter.map { start.addingTimeInterval($0) },
            requestedAt: start.addingTimeInterval(requestedAfter)
        )
    }

    @Test func syncedProgressBeatsTheMetadataSavedAtDownload() {
        let synced = action(needsSync: false, writtenAt: start)
        #expect(synced.effectiveViewOffsetMs(fallback: 600_000) == 2_400_000)
    }

    @Test func plexWinsOnceFetchedAfterTheSyncedWrite() {
        var synced = action(needsSync: false, writtenAt: start)
        let changed = synced.applyPlexState(plex(offsetMs: 5_400_000, lastViewedAfter: 3_600, requestedAfter: 7_200))
        #expect(changed)
        // Offline later, the saved download metadata still says 10 minutes.
        #expect(synced.effectiveViewOffsetMs(fallback: 600_000) == 5_400_000)
    }

    @Test func plexUnwatchedElsewhereBeatsASyncedWatchedMark() {
        var synced = action(kind: .watched, offsetMs: nil, needsSync: false, writtenAt: start)
        _ = synced.applyPlexState(plex(offsetMs: nil, watched: false, lastViewedAfter: nil, requestedAfter: 600))
        #expect(synced.effectiveWatched(fallback: true) == false)
        #expect(synced.effectiveViewOffsetMs(fallback: 600_000) == nil)
    }

    @Test func pendingWriteNewerThanPlexStillWins() {
        var pending = action(needsSync: true, writtenAt: start.addingTimeInterval(7_200))
        _ = pending.applyPlexState(plex(offsetMs: 600_000, lastViewedAfter: 0, requestedAfter: 7_300))
        #expect(pending.needsSync)
        #expect(pending.effectiveViewOffsetMs(fallback: 600_000) == 2_400_000)
    }

    @Test func pendingWriteIsDroppedWhenPlexChangedAfterIt() {
        var pending = action(needsSync: true, writtenAt: start)
        _ = pending.applyPlexState(plex(offsetMs: 5_400_000, lastViewedAfter: 3_600, requestedAfter: 7_200))
        #expect(!pending.needsSync)
        #expect(pending.effectiveViewOffsetMs(fallback: 600_000) == 5_400_000)
    }

    @Test func plexChangeWithinTheClockAllowanceKeepsThePendingWrite() {
        var pending = action(needsSync: true, writtenAt: start)
        _ = pending.applyPlexState(plex(offsetMs: 5_400_000, lastViewedAfter: 60, requestedAfter: 7_200))
        #expect(pending.needsSync)
    }

    @Test func olderResponseArrivingLateIsIgnored() {
        var synced = action(needsSync: false, writtenAt: start)
        _ = synced.applyPlexState(plex(offsetMs: 5_400_000, lastViewedAfter: 3_600, requestedAfter: 7_200))
        let changed = synced.applyPlexState(plex(offsetMs: 900_000, lastViewedAfter: 0, requestedAfter: 7_100))
        #expect(!changed)
        #expect(synced.effectiveViewOffsetMs(fallback: nil) == 5_400_000)
    }

    @Test func localProgressKeepsPlexWatchedFlagNotTheSavedOne() {
        let rewatching = action(needsSync: true, writtenAt: start.addingTimeInterval(600), plex: plex(offsetMs: nil, watched: true, lastViewedAfter: 0, requestedAfter: 0))
        #expect(rewatching.effectiveWatched(fallback: false))

        let unwatchedElsewhere = action(needsSync: true, writtenAt: start.addingTimeInterval(600), plex: plex(offsetMs: nil, watched: false, lastViewedAfter: nil, requestedAfter: 0))
        #expect(unwatchedElsewhere.effectiveWatched(fallback: true) == false)
    }

    @Test func actionSavedBeforeWrittenAtDecodesWithItsUpdateTime() throws {
        let saved = action(needsSync: false, writtenAt: start)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "writtenAt")
        json.removeValue(forKey: "plexWatchState")
        let decoded = try JSONDecoder().decode(OfflinePlaybackSyncAction.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.writtenAt == saved.updatedAt)
        #expect(decoded.plexWatchState == nil)
    }
}
