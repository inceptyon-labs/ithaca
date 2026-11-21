import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Which concrete engine to use for playback.
enum PlaybackEngineType: Sendable {
    case avPlayer
    case vlcKit
}

/// Where a playback source's bytes actually come from, resolved by the
/// coordinator when the source is built. Drives how much protective buffering
/// the engine needs: a downloaded file has no jitter at all, a LAN Plex
/// server very little, and only a remote/relay stream needs real headroom.
enum PlaybackSourceLocality: Sendable {
    case localFile
    case localNetwork
    case remoteNetwork
}

enum PlaybackBufferPolicy {
    static let avPlayerForwardBufferDuration: TimeInterval = 20

    /// libvlc caching is NOT just a network buffer: it becomes the input's
    /// pts_delay, which scales every clock window in the pipeline — the
    /// initial dejitter offset, the audio output's start deferral after
    /// open/seek/flush, and the late/early drift thresholds. In practice the
    /// caching value IS the stretch of silent video that opens every session
    /// and follows every seek: the first picture renders right away while the
    /// audio output sits in its deferred start for ~the caching duration (at
    /// the old flat 1500 ms, every start played ~1.5 s of video before any
    /// sound; at the pre-migration 8000 ms it was many seconds). So the value
    /// is tiered by how much jitter the transport can actually produce, and
    /// each tier sits as low as that transport safely allows: a downloaded
    /// file has none (300 ms is VLC's own file-access default), a LAN server
    /// very little, and only remote/relay streams keep the protective
    /// headroom (VLC-iOS ships 999 ms as its blanket network default).
    static func vlcCachingMilliseconds(for locality: PlaybackSourceLocality) -> Int {
        switch locality {
        case .localFile: 300
        case .localNetwork: 600
        case .remoteNetwork: 1_500
        }
    }

    /// How far libvlc's prefetch filter reads ahead of playback on an http(s)
    /// source, in KiB (`:prefetch-buffer-size`). The default 16 MiB is about
    /// 25 s of a 5 Mbps episode; on 2026-10-29 a Plex server whose array disk
    /// was busy with camera recordings stopped sending for longer than that and
    /// a LAN session buffered. Unlike the caching above, this adds no start or
    /// seek delay: the filter fills it in the background. LAN only, where
    /// filling it is cheap; nil keeps libvlc's default. The buffer is held in
    /// RAM, so the 2 GB Apple TV HD gets a smaller one (still three times
    /// libvlc's default).
    static func vlcPrefetchBufferKiB(
        for locality: PlaybackSourceLocality,
        memory: DeviceMemoryClass = .current
    ) -> Int? {
        switch locality {
        case .localNetwork: (memory == .small ? 48 : 128) * 1_024
        case .localFile, .remoteNetwork: nil
        }
    }
}

struct PlaybackEngineDiagnostic: Sendable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Receives Picture in Picture lifecycle events from a `PlaybackEngine` so the
/// owner (the coordinator) can keep the session alive while the floating window
/// is shown and restore the player UI when the user returns from it.
@MainActor
protocol PlaybackPictureInPictureDelegate: AnyObject {
    /// The floating window started (`true`) or stopped (`false`).
    func pictureInPictureActiveDidChange(_ isActive: Bool)

    /// The user asked to return to the full app UI from the PiP window. Call
    /// `completion(true)` once the player UI is back on screen so the system can
    /// animate the video back into place.
    func pictureInPictureRestorePlayerUI(completion: @escaping (Bool) -> Void)
}

/// Unified interface for media playback. Concrete implementations wrap
/// AVPlayer (`AVPlayerEngine`) or VLCKit (`VLCKitEngine`).
///
/// Implementations must be `@Observable` so SwiftUI views can react
/// to state changes (currentTime, playback state, track lists, etc.).
@MainActor
protocol PlaybackEngine: AnyObject {
    // MARK: - Lifecycle

    /// Begin loading media from the given URL. If `startPosition` is non-nil,
    /// seek to that offset once loaded (resume playback).
    func load(source: PlaybackSource)
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)
    /// Changes the rate of active playback without changing the paused/playing
    /// state. The player UI uses this for its temporary iOS/iPadOS hold-to-2x
    /// interaction and restores the normal `1` rate when the hold ends.
    func setPlaybackRate(_ rate: Float)

    // MARK: - Coordinated playback

    /// Apple's transport coordinator for this engine. AVPlayer supplies one
    /// natively; VLCKit is adapted through AVDelegatingPlaybackCoordinator.
    var playbackCoordinator: AVPlaybackCoordinator { get }

    /// Sets the stable server-scoped identity used to match this item with the
    /// copies loaded by other SharePlay participants. Nil detaches local custom
    /// playback behavior after leaving the group.
    func configureCoordinatedPlayback(itemIdentifier: String?)

    /// Seek with a precision hint. `precise: false` lets the engine trade
    /// frame accuracy for speed (e.g. AVPlayer snapping to a nearby keyframe
    /// instead of decoding up to the exact frame) — meant for transient jumps
    /// like double-tap/remote skips where the position is approximate anyway.
    /// `precise: true` behaves like `seek(to:)`. Engines that don't
    /// distinguish keep the default, which forwards to `seek(to:)`.
    func seek(to position: TimeInterval, precise: Bool)
    func recoverFromStall()

    /// Called when the app returns to foreground after being backgrounded.
    /// Engines should restore their video rendering pipeline here.
    func handleReturnToForeground()

    /// Toggles how the video fills its container. `false` letterboxes the video
    /// to fit (aspect fit); `true` zooms it to fill the container, cropping the
    /// overflow (aspect fill). Driven by the iOS/iPadOS player zoom control;
    /// tvOS does not call this.
    func setVideoFillEnabled(_ enabled: Bool)

    /// Applies the user's subtitle style. The coordinator calls this once with
    /// the stored preferences right after building the engine (before
    /// `load(source:)`); the in-player size picker calls it again for a live
    /// size change. A change made in Settings reaches the engine on the next
    /// session, since Settings is not reachable while the player is up.
    func applySubtitleStyle(_ style: SubtitleStyle)

    // MARK: - State

    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    /// The currently seekable media-time window. Live HLS commonly starts
    /// above zero and advances at its upper edge as Plex appends segments.
    var seekableTimeRange: ClosedRange<TimeInterval>? { get }
    var isBuffering: Bool { get }
    var error: PlaybackError? { get }
    var onPlaybackEnded: (@MainActor () -> Void)? { get set }
    var playbackDiagnostics: [PlaybackEngineDiagnostic] { get }

    // MARK: - Track Selection

    var availableSubtitleTracks: [SubtitleTrack] { get }
    var availableAudioTracks: [AudioTrack] { get }
    var selectedSubtitleTrackID: Int? { get }
    var selectedAudioTrackID: Int? { get }
    func selectSubtitleTrack(_ track: SubtitleTrack?)
    func selectAudioTrack(_ track: AudioTrack)

    /// Whether the engine can mount an external (sidecar) subtitle file on the
    /// media it is already playing. VLCKit adds one as a libvlc playback slave;
    /// AVPlayer cannot attach a sidecar to a live item at all (it would need an
    /// AVComposition rebuild), so a Plex sidecar there requires restarting the
    /// session on VLCKit.
    var supportsExternalSubtitles: Bool { get }

    /// Mounts a sidecar subtitle file (a Plex `/library/streams/{id}` URL) on
    /// the current media, optionally making it the active subtitle track.
    ///
    /// The track appears in `availableSubtitleTracks` asynchronously, carrying
    /// `externalURL == url` so the caller can map it back to the Plex stream it
    /// came from. Returns whether the engine accepted the request, not whether
    /// the file parsed. Engines must remember their mounted slaves and re-add
    /// them whenever they reopen the media in place (slaves live on the input,
    /// not on the media).
    @discardableResult
    func attachExternalSubtitle(_ url: URL, select: Bool) -> Bool

    /// Whether automatic (app-driven) audio track selection may run right now.
    /// VLCKit defers it until playback is steadily rendering: switching the
    /// audio ES restarts libvlc's audio output (input format change), and doing
    /// that inside the startup window — output bring-up, audio session
    /// activation, resume seek — can leave the restarted output dead until a
    /// manual pause/resume. Steady-state switches are safe.
    var isReadyForAutomaticAudioSelection: Bool { get }

    /// An audio track whose decoder turned out not to work during this load
    /// (VLCKit: libvlc reported that it could not open the TrueHD decoder).
    /// The view model hands it to the server audio-conversion fallback once.
    var failedAudioDecoderTrackID: Int? { get }

    // MARK: - Audio session

    /// Whether this engine wants the rich `.moviePlayback` audio session, which
    /// lets iOS spatialize audio for AirPods. AVPlayer feeds that spatializer
    /// natively and smoothly; VLCKit's raw audio output does not, and on a
    /// Bluetooth route it underruns and stutters, so it opts out for a plain,
    /// unprocessed session. iOS only — consumed by `PlaybackNowPlayingController`.
    var prefersSpatializedAudioSession: Bool { get }

    // MARK: - External playback

    /// Whether the engine can hand video to a system external-playback route.
    /// AVPlayer supports native AirPlay; VLCKit's renderer remains local.
    var supportsExternalPlayback: Bool { get }

    /// Whether the engine is currently rendering video on an external route.
    var isExternalPlaybackActive: Bool { get }

    // MARK: - Rendering

    /// Returns a platform-specific view that renders the video content.
    func makePlayerView() -> AnyView

    /// Bumped when the engine replaces its rendering view mid-session (VLCKit
    /// entering Picture in Picture support mode); `PlayerViewModel` re-calls
    /// `makePlayerView()` when it changes. Engines with a stable view keep the
    /// default 0.
    var playerViewGeneration: Int { get }

    // MARK: - Picture in Picture

    /// Whether Picture in Picture can be started (or, for VLCKit's on-demand
    /// support mode, prepared) right now. iOS only.
    var isPictureInPicturePossible: Bool { get }

    /// Whether a Picture in Picture window is currently active.
    var isPictureInPictureActive: Bool { get }

    /// Routes PiP lifecycle events back to the owner. Held weakly.
    func setPictureInPictureDelegate(_ delegate: (any PlaybackPictureInPictureDelegate)?)

    func startPictureInPicture()
    func stopPictureInPicture()

}

extension PlaybackEngine {
    var seekableTimeRange: ClosedRange<TimeInterval>? {
        duration > 0 ? 0...duration : nil
    }

    var playbackDiagnostics: [PlaybackEngineDiagnostic] { [] }
    func setVideoFillEnabled(_ enabled: Bool) {}

    // Default: subtitle styling is engine-specific; engines that render text
    // subtitles themselves override this.
    func applySubtitleStyle(_ style: SubtitleStyle) {}

    // Bumped when the engine replaces its rendering view mid-session (VLCKit
    // entering Picture in Picture support mode); `PlayerViewModel` re-calls
    // `makePlayerView()` when it changes. Engines with a stable view keep 0.
    var playerViewGeneration: Int { 0 }

    // Default: the precision hint is ignored — only AVPlayer distinguishes
    // tolerant (keyframe) seeks from frame-accurate ones.
    func seek(to position: TimeInterval, precise: Bool) {
        seek(to: position)
    }

    // Default: no startup fragility — only VLCKit defers automatic selection.
    var isReadyForAutomaticAudioSelection: Bool { true }

    // Default: decoders are the platform's own. Only VLCKit watches its
    // TrueHD decoder.
    var failedAudioDecoderTrackID: Int? { nil }

    // Default: sidecar subtitles cannot be mounted. Only VLCKit opts in.
    var supportsExternalSubtitles: Bool { false }
    @discardableResult
    func attachExternalSubtitle(_ url: URL, select: Bool) -> Bool { false }

    // Default: keep the rich movie-playback session. Only VLCKit opts out.
    var prefersSpatializedAudioSession: Bool { true }

    // Native external video playback is AVPlayer-only. Engines opt in.
    var supportsExternalPlayback: Bool { false }
    var isExternalPlaybackActive: Bool { false }

    // Picture in Picture is iOS-only and opt-in per engine; tvOS engines fall
    // back to these no-ops.
    var isPictureInPicturePossible: Bool { false }
    var isPictureInPictureActive: Bool { false }
    func setPictureInPictureDelegate(_ delegate: (any PlaybackPictureInPictureDelegate)?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
}

/// How locally rendered subtitles look. Both engines draw them
/// (`applySubtitleStyle`); text burned into the video by a transcode can't be
/// styled.
struct SubtitleStyle: Equatable, Sendable {
    var size: SubtitleFontSize = .default
    var background: SubtitleBackground = .default
    var color: SubtitleColor = .default
    var position: SubtitlePosition = .default
}

enum SubtitleBackground: String, CaseIterable, Identifiable, Sendable {
    /// A see-through dark box behind each line.
    case box
    /// An opaque black box.
    case solid
    /// No box, a drop shadow only.
    case none

    static let `default`: SubtitleBackground = .box

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .box: "See-Through Box"
        case .solid: "Solid Box"
        case .none: "None"
        }
    }

    /// The box's opacity in AVPlayer, 0 to 1.
    var opacity: Double {
        switch self {
        case .box: 0.68
        case .solid: 1
        case .none: 0
        }
    }

    /// The same in libvlc, 0 to 255. The see-through box keeps the value
    /// VLCKit playback was tuned with.
    var vlcOpacity: Int {
        switch self {
        case .box: 110
        case .solid: 255
        case .none: 0
        }
    }
}

enum SubtitleColor: String, CaseIterable, Identifiable, Sendable {
    case white
    case yellow
    case cyan

    static let `default`: SubtitleColor = .white

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .white: "White"
        case .yellow: "Yellow"
        case .cyan: "Cyan"
        }
    }

    /// Red, green and blue, 0 to 1.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white: (1, 1, 1)
        case .yellow: (1, 0.9, 0)
        case .cyan: (0, 0.9, 1)
        }
    }

    /// "#RRGGBB", as libvlc takes it.
    var hex: String {
        let (red, green, blue) = rgb
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

enum SubtitlePosition: String, CaseIterable, Identifiable, Sendable {
    case bottom
    /// A tenth of the picture higher: clear of burned-in text and TV
    /// overscan.
    case raised

    static let `default`: SubtitlePosition = .bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottom: "Bottom"
        case .raised: "Raised"
        }
    }

    /// How far above the usual spot, as a fraction of the picture's height.
    var lift: Double {
        switch self {
        case .bottom: 0
        case .raised: 0.1
        }
    }
}

/// User-facing subtitle size preference. `medium` is the historical default
/// and reproduces the platform baseline exactly; the other cases scale it.
enum SubtitleFontSize: String, CaseIterable, Identifiable, Sendable {
    case extraSmall
    case small
    case medium
    case large

    static let `default`: SubtitleFontSize = .medium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .extraSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Multiplier applied to the platform baseline in `PlaybackSubtitleStyle`.
    var scale: Float {
        switch self {
        case .extraSmall: 0.6
        case .small: 0.8
        case .medium: 1.0
        case .large: 1.25
        }
    }

    /// Secondary label for the player pickers.
    var detailTitle: String? {
        self == .medium ? "Default" : nil
    }
}

@MainActor
enum PlaybackSubtitleStyle {
    /// The Medium baseline, in percent of the renderer's default size.
    static var baseAVPlayerRelativeFontSize: Int {
        switch userInterfaceIdiom {
        case .pad, .mac:
            return 75
        default:
            return 100
        }
    }

    static func avPlayerRelativeFontSize(for size: SubtitleFontSize) -> Int {
        Int((Float(baseAVPlayerRelativeFontSize) * size.scale).rounded())
    }

    /// AVPlayer's text style: colour, the box behind each line, a drop shadow,
    /// size, and for Raised the line's position, as a percentage of the
    /// picture's height from the top.
    static func avPlayerTextMarkupAttributes(for style: SubtitleStyle) -> [String: Any] {
        let (red, green, blue) = style.color.rgb
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0, red, green, blue],
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [style.background.opacity, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: kCMTextMarkupCharacterEdgeStyle_DropShadow,
            kCMTextMarkupAttribute_RelativeFontSize as String: avPlayerRelativeFontSize(for: style.size),
        ]
        if style.position.lift > 0 {
            // AVPlayer's own bottom line sits near 90%.
            attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] =
                (0.9 - style.position.lift) * 100
        }
        return attributes
    }

    /// libvlc options for everything but size, given when the library starts.
    /// VLC 3's text renderer and subtitle unit read these by inheritance from
    /// the library (`var_Inherit`); per-media options never reach them, since
    /// they hang off the player, not the input. `sub-margin` lifts subtitles
    /// by that many pixels of the canvas they're drawn on (`canvasSize`).
    static func vlcLibraryOptions(for style: SubtitleStyle, canvasSize: CGSize?) -> [String] {
        let (red, green, blue) = style.color.rgb
        let color = Int(red * 255) << 16 | Int(green * 255) << 8 | Int(blue * 255)
        var options = [
            "--freetype-color=\(color)",
            "--freetype-background-color=0",
            "--freetype-background-opacity=\(style.background.vlcOpacity)",
        ]
        if style.position.lift > 0, let canvasSize {
            let height = min(canvasSize.width, canvasSize.height)
            options.append("--sub-margin=\(Int((height * style.position.lift).rounded()))")
        }
        return options
    }

    /// libvlc's `freetype-rel-fontsize`: the font height is the video height
    /// divided by this value, so a smaller number draws larger text. 16 is
    /// libvlc's default and maps to 100%.
    static func vlcRelativeFontSize(for size: SubtitleFontSize) -> Int {
        let scale = Float(avPlayerRelativeFontSize(for: size)) / 100
        return max(1, Int((16 / scale).rounded()))
    }

    private static var userInterfaceIdiom: UIUserInterfaceIdiom {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom
        #else
        .unspecified
        #endif
    }
}
