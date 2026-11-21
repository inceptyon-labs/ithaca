import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Ithaca

@Suite("Automatic playback recovery presentation")
@MainActor
struct PlaybackFallbackTests {
    @Test func remuxErrorsStayLoadingUntilRecoveryIsExhausted() {
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.startDirectPlayFallbackWatch()
        defer { playback.cancelDirectPlayFallbackWatch() }

        // Remuxes arm this watch too; no direct-play-only presentation gate.
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
        playback.isAutomaticDirectPlayFallbackAvailable = false
        playback.isAutomaticDirectPlayFallbackActive = true
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
        playback.cancelDirectPlayFallbackWatch()
        #expect(!playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .hidden)
    }

    @Test func exhaustedFallbackRevealsTerminalError() async {
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.isAutomaticDirectPlayFallbackAvailable = true
        playback.isAutomaticDirectPlayFallbackActive = true
        // No active item means no replacement can be prepared.
        await playback.performDirectPlayServerStreamFallback()
        #expect(!playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .hidden)
    }

    @Test func dv7RetryKeepsTheReplacementFallbackArmed() async throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let media = try JSONDecoder().decode(PlexMedia.self, from: Data(#"""
            {"id":1,"container":"mkv","Part":[{"id":2,"key":"/clip.mkv","Stream":[
              {"id":3,"streamType":1,"codec":"hevc","DOVIProfile":7,"DOVILevel":6,"DOVIBLCompatID":6}
            ]}]}
            """#.utf8))
        let url = try #require(URL(string: "https://example.invalid/clip.m3u8"))
        let conversion = try #require(StreamResolver.dolbyVision7ConversionTarget(in: media))
        let attemptID = UUID()
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.debugInfo = PlaybackDebugInfo(
            title: "DV7", engine: .avPlayer, decision: .spatialAudio,
            media: media, part: media.parts[0], attemptID: attemptID,
            resolverReason: "DV7 remux", sanitizedPlaybackURL: url.absoluteString
        )
        playback.playbackSource = PlaybackSource(
            url: url, startPosition: nil,
            context: PlaybackAttemptContext(
                attemptID: attemptID, title: "DV7", ratingKey: "1",
                engine: .avPlayer, resolverReason: "DV7 remux", mediaID: 1,
                partID: 2, sanitizedPlaybackURL: url.absoluteString
            ),
            dolbyVision7Conversion: conversion
        )
        playback.isAutomaticDirectPlayFallbackAvailable = true
        playback.isAutomaticDirectPlayFallbackActive = true

        // A queued track rebuild replaces the failed engine while the DV7
        // retry waits for it. Exercise the real retry/cleanup across that await
        // without loading media or contacting Plex.
        playback.spatialAudioTransitionTask = Task { @MainActor in
            playback.engine = FailedPlaybackEngine()
            playback.playerPresentationID = UUID()
            playback.startDirectPlayFallbackWatch()
        }
        defer { playback.cancelDirectPlayFallbackWatch() }
        await playback.performDirectPlayServerStreamFallback()
        #expect(playback.isDolbyVision7ConversionSuppressed)
        #expect(playback.isAutomaticDirectPlayFallbackAvailable)
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
    }

    /// SwiftUI builds a throwaway view model on every parent redraw; one that
    /// is never shown must not run a second sync loop (and stall recovery).
    @Test func playerViewModelSyncsOnlyOnceStarted() {
        let viewModel = PlayerViewModel(engine: FailedPlaybackEngine())
        #expect(viewModel.syncTimer == nil)
        viewModel.startSync()
        let timer = viewModel.syncTimer
        viewModel.startSync()
        #expect(timer != nil)
        #expect(viewModel.syncTimer === timer)
        viewModel.cleanup()
        #expect(viewModel.syncTimer == nil)
    }

    /// The failed remux returns to direct play with a fresh player view model,
    /// whose undecodable-audio rescue would start the same remux again.
    @Test(arguments: [true, false])
    func failedConvertedAudioRemuxIsNotRetriedForTheItem(convertsAudio: Bool) async throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let media = try JSONDecoder().decode(PlexMedia.self, from: Data(#"""
            {"id":1,"container":"mkv","Part":[{"id":2,"key":"/clip.mkv","Stream":[
              {"id":3,"streamType":1,"codec":"hevc"},
              {"id":4,"streamType":2,"codec":"truehd","channels":8}
            ]}]}
            """#.utf8))
        let url = try #require(URL(string: "https://example.invalid/clip.m3u8"))
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.debugInfo = PlaybackDebugInfo(
            title: "TrueHD", engine: .avPlayer, decision: .spatialAudio,
            media: media, part: media.parts[0], attemptID: UUID(),
            resolverReason: "remux", sanitizedPlaybackURL: url.absoluteString
        )
        playback.remuxAudioConversion = convertsAudio ? RemuxAudioConversion(audioStreamID: 4) : nil
        defer { playback.cancelDirectPlayFallbackWatch() }

        await playback.performDirectPlayServerStreamFallback()
        #expect(playback.isAudioConversionRemuxSuppressed == convertsAudio)
    }
}

@MainActor
private final class FailedPlaybackEngine: PlaybackEngine {
    let state: PlaybackState = .error
    let error: PlaybackError? = .unknown("The decoder failed.")
    let currentTime: TimeInterval = 0
    let duration: TimeInterval = 0
    let isBuffering = false
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }
    private let player = AVPlayer()

    func load(source: PlaybackSource) {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
