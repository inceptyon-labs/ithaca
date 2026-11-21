#if os(tvOS)
import AVFoundation
import OSLog
import SwiftUI
import UIKit

private let trailerPreviewLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Ithaca",
    category: "TrailerPreview"
)

/// Plays a detail page's trailer, muted, over the hero backdrop once the page
/// has been on screen for a few seconds (Apple TV only).
///
/// The page owns one controller. Its `AVPlayer` exists only while a preview
/// runs, and `TrailerPreviewGate` never runs one while a playback session
/// exists (including Picture in Picture), so a preview cannot hold a decoder
/// the real player or the Dolby Vision path needs. Previews never report a
/// timeline or touch watch state.
@MainActor
@Observable
final class TrailerPreviewController {
    /// How long the page has to be on screen before the trailer starts.
    static let dwell: Duration = .seconds(4)
    private static let fadeInSeconds = 0.8
    private static let fadeOutSeconds = 0.5
    /// How long the trailer may take to start before the page gives up.
    private static let startLimit: Duration = .seconds(15)
    /// A trailer that stalls this long fades back to the artwork.
    private static let stallLimit: Duration = .seconds(10)

    private(set) var player: AVPlayer?
    /// True once the trailer's frames are on screen; drives the fade.
    private(set) var isShowingVideo = false
    /// True from the end of the fade-in to the start of the fade-out, while the
    /// video covers the artwork completely. The hero then stops drawing the
    /// artwork, which sits in its masked group re-rendered every video frame.
    private(set) var coversBackdrop = false

    private let plexService: PlexService

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    /// One preview, run from `.task(id:)`: waits out the dwell, starts the
    /// trailer, fades it in once it is playing, and fades back to the artwork
    /// when it ends, fails or stalls. Cancelling the task stops it.
    func run(trailer: PlexItem) async {
        var player: AVPlayer?
        var stream: PreviewStream?
        defer { finish(player: player, transcodeSessionID: stream?.transcodeSessionID, serverID: stream?.serverID) }

        do {
            try await Task.sleep(for: Self.dwell)
            // Starting an item activates the app's non-mixable audio session even
            // muted, which would stop music another app is playing.
            guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }
            stream = try await previewStream(for: trailer)
            guard let stream else { return }
            try Task.checkCancellation()

            let item = AVPlayerItem(url: stream.url)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = true
            // The screen saver still comes on over a page left playing previews.
            newPlayer.preventsDisplaySleepDuringVideoPlayback = false
            newPlayer.actionAtItemEnd = .pause
            player = newPlayer
            self.player = newPlayer
            newPlayer.play()

            guard try await waitUntilPlaying(newPlayer, item: item) else { return }
            withAnimation(.easeInOut(duration: Self.fadeInSeconds)) {
                isShowingVideo = true
            } completion: { [weak self] in
                guard let self, self.isShowingVideo, self.player === newPlayer else { return }
                self.coversBackdrop = true
            }
            try await waitUntilFinished(newPlayer, item: item)
        } catch {
            // A cancelled preview (the page moved on) is not worth a log line;
            // `finish` cleans up either way.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            trailerPreviewLogger.notice(
                "Trailer preview for \(trailer.ratingKey, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Drops the player at once, with no fade. Called when a playback session
    /// starts, so its decoder is free before the real player needs one.
    func releaseNow() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        coversBackdrop = false
        isShowingVideo = false
    }

    // MARK: - Stream

    private struct PreviewStream {
        let url: URL
        /// Set for a Plex HLS stream, which has to be stopped afterwards.
        let transcodeSessionID: String?
        let serverID: String?
    }

    /// Direct play when AVPlayer can open the file. An H.264 trailer AVPlayer
    /// can't open (MKV, DTS and the like) goes through the AVPlayer-safe Plex
    /// HLS the AirPlay route uses, which copies the video. Anything that would
    /// need a video re-encode gets no preview, and neither does a server
    /// reached over the WAN or Plex Relay.
    private func previewStream(for trailer: PlexItem) async throws -> PreviewStream? {
        guard let connection = plexService.pool.connection(for: trailer.serverID),
              !connection.isRemote, !connection.isRelay else { return nil }
        let details = try await plexService.getMediaDetails(ratingKey: trailer.ratingKey, serverID: trailer.serverID)
        guard let mediaIndex = details.media.firstIndex(where: \.hasAvailablePart) else { return nil }
        let media = details.media[mediaIndex]
        let decision = StreamResolver.evaluate(media: media)

        if decision.engine == .avPlayer, !decision.requiresServerTranscode, let part = media.firstAvailablePart {
            return plexService.directPlayURL(for: part, serverID: details.serverID).map {
                PreviewStream(url: $0, transcodeSessionID: nil, serverID: details.serverID)
            }
        }

        // The AirPlay route has no bitrate or resolution cap, so any other codec
        // would be a full-resolution transcode for a muted background video.
        guard media.videoCodec?.lowercased() == "h264" else { return nil }
        let sessionID = UUID().uuidString
        let result = try await plexService.airPlayStreamURL(
            ratingKey: details.ratingKey,
            mediaIndex: mediaIndex,
            sessionIdentifier: sessionID,
            transcodeSessionID: sessionID,
            serverID: details.serverID
        )
        guard case .transcodeAvailable = result.outcome else { return nil }
        return PreviewStream(url: result.url, transcodeSessionID: sessionID, serverID: details.serverID)
    }

    // MARK: - Progress

    /// True once the trailer has played a moment, so frames are on screen
    /// before it fades in; false when it fails or never starts.
    private func waitUntilPlaying(_ player: AVPlayer, item: AVPlayerItem) async throws -> Bool {
        let deadline = ContinuousClock.now + Self.startLimit
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if item.status == .failed { return false }
            if player.timeControlStatus == .playing, item.currentTime().seconds >= 0.3 { return true }
        }
        return false
    }

    /// Returns when the trailer reaches its end (the player pauses itself
    /// there), fails, or stalls past `stallLimit`.
    private func waitUntilFinished(_ player: AVPlayer, item: AVPlayerItem) async throws {
        var stalledSince: ContinuousClock.Instant?
        while true {
            try await Task.sleep(for: .milliseconds(500))
            if item.status == .failed { return }
            switch player.timeControlStatus {
            case .playing:
                stalledSince = nil
            case .waitingToPlayAtSpecifiedRate:
                let since = stalledSince ?? .now
                stalledSince = since
                if ContinuousClock.now - since > Self.stallLimit { return }
            case .paused:
                return
            @unknown default:
                return
            }
        }
    }

    // MARK: - Teardown

    /// Ends one preview: stops its Plex stream, fades the video out over its
    /// last frame, then lets the player go. Only touches what that preview
    /// created, so a late finish cannot tear down the next one.
    private func finish(player: AVPlayer?, transcodeSessionID: String?, serverID: String?) {
        if let transcodeSessionID {
            let plexService = plexService
            Task {
                await plexService.stopTranscodeSession(transcodeSessionID: transcodeSessionID, serverID: serverID)
            }
        }
        guard let player else { return }
        player.pause()
        guard self.player === player else {
            player.replaceCurrentItem(with: nil)
            return
        }
        coversBackdrop = false
        withAnimation(.easeInOut(duration: Self.fadeOutSeconds)) {
            isShowingVideo = false
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOutSeconds))
            player.replaceCurrentItem(with: nil)
            if let self, self.player === player {
                self.player = nil
            }
        }
    }
}

// MARK: - Video

/// The preview's video, for `DetailHeroSection(backdropAccessory:)`. Clear
/// until the trailer is playing, so the artwork shows through until then.
struct TrailerPreviewVideo: View {
    let controller: TrailerPreviewController

    var body: some View {
        TrailerPreviewPlayerLayer(player: controller.player)
            .opacity(controller.isShowingVideo ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TrailerPreviewPlayerLayer: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> TrailerPreviewPlayerLayerView {
        TrailerPreviewPlayerLayerView()
    }

    func updateUIView(_ view: TrailerPreviewPlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

private final class TrailerPreviewPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Gate

/// Decides when a page may preview its trailer: the page is on screen and
/// active, its hero is in view, Trailer Previews is on in Settings, the
/// system's Auto-Play Video Previews setting allows it, and no playback
/// session exists. Any of those changing cancels the running preview; the
/// dwell starts over when they all hold again.
private struct TrailerPreviewGate: ViewModifier {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false

    let controller: TrailerPreviewController
    let trailer: PlexItem?
    let isHeroInView: Bool

    private var runKey: PlexItemID? {
        guard let trailer,
              isOnScreen,
              isHeroInView,
              preferences.trailerPreviewsEnabled,
              // Read on every evaluation: changing it means leaving the app,
              // and coming back changes `scenePhase`.
              UIAccessibility.isVideoAutoplayEnabled,
              scenePhase == .active,
              !playback.showPlayer,
              playback.engine == nil else { return nil }
        return trailer.id
    }

    func body(content: Content) -> some View {
        content
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .onChange(of: playback.showPlayer) { _, isShowing in
                if isShowing { controller.releaseNow() }
            }
            .task(id: runKey) {
                guard runKey != nil, let trailer else { return }
                await controller.run(trailer: trailer)
            }
    }
}

extension View {
    /// Runs `controller`'s trailer preview while the page allows it; see
    /// `TrailerPreviewGate`. `isHeroInView` is the page's own condition (its
    /// hero is scrolled into view, and on the show page the viewer has not
    /// started browsing episodes).
    func trailerPreview(
        _ controller: TrailerPreviewController,
        trailer: PlexItem?,
        isHeroInView: Bool
    ) -> some View {
        modifier(TrailerPreviewGate(controller: controller, trailer: trailer, isHeroInView: isHeroInView))
    }
}
#endif
