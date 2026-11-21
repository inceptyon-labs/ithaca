import Foundation
import SwiftUI

extension PlaybackCoordinator {
    func startTimelineReporting() {
        transcodePingTickCounter = 0
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reportCurrentTimeline()
                self?.pingActiveTranscodeSessionIfNeeded()
            }
        }
    }

    /// Keep-alive for the server transcoder: Plex reaps transcode sessions it
    /// has not heard from, so while one is active ping it roughly every 60
    /// seconds (every 6th 10-second timeline tick).
    func pingActiveTranscodeSessionIfNeeded() {
        guard let transcodeSessionID = activeTranscodeSessionID else {
            transcodePingTickCounter = 0
            return
        }

        transcodePingTickCounter += 1
        guard transcodePingTickCounter >= 6 else { return }
        transcodePingTickCounter = 0
        let serverID = activePlaybackServerID
        Task {
            await plexService.pingTranscodeSession(
                transcodeSessionID: transcodeSessionID,
                serverID: serverID
            )
        }
    }

    /// Latches `engineHasStartedThisAttempt` the first time the engine is
    /// playing or paused with its clock past the resume seek (or with no seek
    /// pending). Afterwards a clock at 0:00 is a real position, not "not
    /// started".
    func noteEngineStartIfNeeded() {
        guard !engineHasStartedThisAttempt, let engine,
              engine.state == .playing || engine.state == .paused else { return }
        if engine.currentTime > 0 || (playbackSource?.startPosition ?? 0) <= 0 {
            engineHasStartedThisAttempt = true
        }
    }

    /// The one position rule for timeline reports, the final stopped report and
    /// every engine rebuild. Once the engine has started, its live clock wins
    /// even when it is behind the saved offset or at 0:00 (the viewer sought).
    /// Before that, the attempt's own start position is the position (the
    /// replacement's seek target), falling back to the last reported time. Once
    /// the engine is gone, use the last reported time, then the start position.
    /// An engine stopped by a network change reports the position captured then.
    var currentPlaybackPosition: TimeInterval {
        if let stoppedResumePosition { return stoppedResumePosition }
        noteEngineStartIfNeeded()
        let startPosition = playbackSource?.startPosition
        let lastReported = TimeInterval(max(lastReportedTimeMs - activePartOffsetMs, 0)) / 1000.0
        let fallback = engineHasStartedThisAttempt
            ? (lastReportedTimeMs > 0 ? lastReported : startPosition ?? 0)
            : startPosition ?? lastReported
        guard let engine else { return fallback }
        switch engine.state {
        case .playing, .paused, .loading:
            return engineHasStartedThisAttempt ? engine.currentTime : fallback
        case .idle, .stopped, .error:
            // Engines keep their clock on error; only a never-started engine
            // needs the fallback.
            return engineHasStartedThisAttempt ? engine.currentTime : max(engine.currentTime, fallback)
        }
    }

    /// Item-level start of the part being played; 0 for single-part playback.
    var activePartOffsetMs: Int {
        activePartTimeline?.startMs(ofPart: activePartIndex) ?? 0
    }

    /// The position Plex sees: `currentPlaybackPosition` is relative to the
    /// current part, so a stacked item adds that part's start.
    var currentItemPositionMs: Int {
        activePartOffsetMs + Int(currentPlaybackPosition * 1000)
    }

    /// The item's length for Plex; a stacked item with known part lengths
    /// reports the sum rather than the current part's.
    func itemDurationMs(engineDurationMs: Int) -> Int {
        activePartTimeline?.totalDurationMs ?? engineDurationMs
    }

    /// Without part lengths a stacked item's time is part-relative, so only
    /// its last part may count as watched.
    var canScrobbleAtCurrentPart: Bool {
        guard let activePartTimeline, activePartTimeline.durationsMs == nil else { return true }
        return activePartTimeline.isLastPart(activePartIndex)
    }

    /// Without part lengths a later part's position is not item time, so its
    /// timeline and stopped reports are skipped and Plex keeps the last
    /// position the first part reported.
    var canReportItemPositionAtCurrentPart: Bool {
        activePartTimeline?.reportsItemPosition(forPart: activePartIndex) ?? true
    }

    func reportCurrentTimeline(stateOverride: PlaybackState? = nil) {
        guard let engine, let ratingKey else { return }
        noteEngineStartIfNeeded()

        nowPlayingController.updatePlaybackState(
            state: engine.state,
            currentTime: engine.currentTime,
            duration: engine.duration
        )

        let plexState: PlaybackState
        if let stateOverride {
            plexState = stateOverride
        } else {
            switch engine.state {
            case .playing: plexState = .playing
            case .paused: plexState = .paused
            case .loading:
                // Report "buffering" (see submitTimeline's mapping) instead of
                // dropping the tick, so Plex keeps the session and any server
                // transcoder alive while the engine opens or refills. Local
                // downloads keep the old drop behavior: their ticks feed the
                // offline sync manager, which has no buffering concept.
                guard !activePlaybackUsesLocalDownload else { return }
                plexState = .loading
            default: return
            }
        }

        // A loading engine reports time 0 until its resume seek lands; the
        // shared position rule keeps the saved offset instead of regressing
        // the server's view of progress.
        let isBufferingReport = plexState == .loading
        let timeMs = currentItemPositionMs
        let durationMs = itemDurationMs(
            engineDurationMs: isBufferingReport
                ? max(lastReportedDurationMs, Int(engine.duration * 1000))
                : Int(engine.duration * 1000)
        )

        lastReportedTimeMs = timeMs
        lastReportedDurationMs = durationMs

        if canReportItemPositionAtCurrentPart {
            reportTimelineOrQueueOfflineSync(
                ratingKey: ratingKey,
                state: plexState,
                timeMs: timeMs,
                durationMs: durationMs
            )
        }

        if activeLiveTVContext == nil, canScrobbleAtCurrentPart,
           !hasScrobbled, durationMs > 0, timeMs > Int(Double(durationMs) * 0.9) {
            hasScrobbled = true
            if activePlaybackUsesLocalDownload {
                offlinePlaybackSyncManager?.recordProgress(
                    serverID: activePlaybackServerID,
                    ratingKey: ratingKey,
                    viewOffsetMs: timeMs,
                    durationMs: durationMs,
                    state: plexState
                )
                Task {
                    await offlinePlaybackSyncManager?.syncPendingActions()
                }
            } else {
                let serverID = activePlaybackServerID
                Task {
                    try? await plexService.scrobble(ratingKey: ratingKey, serverID: serverID)
                }
            }
        }
    }

    @discardableResult
    func reportTimelineOrQueueOfflineSync(
        ratingKey: String,
        state: PlaybackState,
        timeMs: Int,
        durationMs: Int
    ) -> Task<Void, Never> {
        if activePlaybackUsesLocalDownload {
            offlinePlaybackSyncManager?.recordProgress(
                serverID: activePlaybackServerID,
                ratingKey: ratingKey,
                viewOffsetMs: timeMs,
                durationMs: durationMs,
                state: state
            )
            return Task {
                await offlinePlaybackSyncManager?.syncPendingActions()
            }
        } else {
            let sessionIdentifier = activePlaybackSessionIdentifier
            let timelineKey = activeLiveTVContext?.sessionPath
            // Only the server this session plays from: the same rating key is a
            // different title everywhere else, so a fan-out would corrupt watch
            // state on every other server.
            let serverID = activePlaybackServerID
            return Task {
                await plexService.reportTimeline(
                    ratingKey: ratingKey,
                    key: timelineKey,
                    state: state,
                    timeMs: timeMs,
                    durationMs: durationMs,
                    sessionIdentifier: sessionIdentifier,
                    serverID: serverID
                )
            }
        }
    }

    func flushTimelineForScenePhase(_ phase: ScenePhase) {
        guard engine != nil, ratingKey != nil else { return }

        switch phase {
        case .inactive:
            reportCurrentTimeline()
        case .background:
            didEnterBackgroundDuringPlayback = true
            reportCurrentTimeline()
        case .active:
            // Control Center or Notification Center only make the scene
            // inactive; the rendering pipeline is torn down only in background.
            guard didEnterBackgroundDuringPlayback else { return }
            didEnterBackgroundDuringPlayback = false
            engine?.handleReturnToForeground()
        @unknown default:
            break
        }
    }
}
