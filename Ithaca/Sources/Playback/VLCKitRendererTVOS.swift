#if os(tvOS)
import TVVLCKit
import UIKit

final class TVOSVLCKitRenderingHost: NSObject, VLCKitRenderingHost, @unchecked Sendable {
    let playerView: UIView

    @MainActor
    override init() {
        self.playerView = UIView()
        super.init()
        playerView.backgroundColor = .black
        playerView.clipsToBounds = true
    }

    func attach(to player: VLCMediaPlayer, engine: VLCKitEngine) {
        player.drawable = playerView
    }

    func detach(from player: VLCMediaPlayer) {
        player.drawable = nil
    }

    func updatePlaybackState(
        currentTimeMs: Int64,
        durationMs: Int64,
        isPlaying: Bool,
        isSeekable: Bool
    ) {}

    func invalidatePlaybackState() {}

    // The zoom-to-fill control is iOS/iPadOS only.
    func setVideoFillEnabled(_ enabled: Bool) {}

    /// libvlc's GL view (`modules/video_output/ios.m`, added straight into
    /// the drawable) rebuilds its render buffers only after `layoutSubviews`
    /// or a window move. If a rebuild fails, for instance while the layer has
    /// no usable surface during an HDMI mode switch, the flag that asked for
    /// it is already cleared and the view keeps drawing into the incomplete
    /// buffer until something lays it out again.
    func relayoutVideoOutput() {
        MainActor.assumeIsolated {
            for subview in playerView.subviews {
                subview.setNeedsLayout()
                subview.layoutIfNeeded()
            }
        }
    }
}
#endif
