#if os(tvOS)
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Ithaca

@Suite("Automatic subtitle reporting")
struct AutomaticSubtitleReportingTests {
    @Test @MainActor
    func automaticEmbeddedSelectionReportsTheDiscoveredPlexTrack() throws {
        let media = try subtitleMedia()
        let player = PlayerViewModel(engine: AutomaticSubtitleTestEngine(state: .playing))
        defer { player.cleanup() }
        player.hasConfiguredAutomaticTrackSelection = true
        player.hasAppliedAutomaticAudioSelection = true
        player.subtitleForcedOnly = true
        player.subtitleTracks = media.parts[0].streams.filter { $0.id == 3 }.map(SubtitleTrack.init(stream:))
        player.audioTracks = media.parts[0].streams.filter { $0.id == 11 }.map(AudioTrack.init(stream:))
        player.selectedAudioTrackID = 11
        var reported: ExplicitTrackSelection?
        player.plexTrackSelectionHandler = { audioID, subtitleID in
            reported = ExplicitTrackSelection(audioStreamID: audioID, subtitleStreamID: subtitleID)
        }
        player.applyAutomaticTrackSelectionIfNeeded()
        #expect(reported == ExplicitTrackSelection(audioStreamID: 11, subtitleStreamID: 3))
    }

    private func subtitleMedia() throws -> PlexMedia {
        try JSONDecoder().decode(PlexMedia.self, from: Data("""
            {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[
              {"id":1,"key":"/clip.mp4","Stream":[
                {"id":2,"streamType":1,"codec":"h264","bitDepth":8},
                {"id":10,"streamType":2,"codec":"aac","channels":2,"default":true},
                {"id":11,"streamType":2,"codec":"ac3","channels":6},
                {"id":3,"streamType":3,"codec":"mov_text","selected":true,"default":true,"forced":true},
                {"id":4,"streamType":3,"codec":"srt","key":"/library/streams/4"}
              ]}
            ]}
            """.utf8))
    }
}

@MainActor
private final class AutomaticSubtitleTestEngine: PlaybackEngine {
    let state: PlaybackState
    let currentTime: TimeInterval = 42
    let duration: TimeInterval = 300
    let isBuffering = false
    let error: PlaybackError? = nil
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    var onPlaybackEnded: (@MainActor () -> Void)?
    private let player = AVPlayer()
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }
    private(set) var didStop = false

    init(state: PlaybackState) { self.state = state }
    func load(source: PlaybackSource) {}
    func play() {}
    func pause() {}
    func stop() { didStop = true }
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
#endif
