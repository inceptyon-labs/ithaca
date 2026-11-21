#if canImport(MobileVLCKit)
import MobileVLCKit
#elseif canImport(TVVLCKit)
import TVVLCKit
#endif
import Foundation

/// What the embedded VLCKit build can do beyond VideoLAN's stock binaries.
///
/// Ithaca ships its own MobileVLCKit/TVVLCKit 3.x build
/// (`ci_scripts/build_vlckit.sh`) with ffmpeg's TrueHD/MLP decoders
/// re-enabled. The build script stamps every framework slice's Info.plist, so
/// the app reads the capability from the binary it actually loaded: a stock
/// VideoLAN framework (a stale local `Frameworks/`) keeps the old routing,
/// where TrueHD is undecodable and goes through Plex.
enum VLCKitBuildInfo {
    /// Ithaca build label (e.g. `3.7.4-ithaca1`); nil for a stock VideoLAN build.
    static let ithacaBuild: String? = frameworkInfo["IthacaVLCKitBuild"] as? String

    /// Whether libvlc decodes Dolby TrueHD/MLP (to PCM, up to 7.1; for TrueHD
    /// Atmos that is the 7.1 bed).
    static let decodesTrueHD: Bool = frameworkInfo["IthacaVLCKitTrueHD"] as? Bool ?? false

    /// Whether libvlc keeps discrete multichannel output on tvOS. Stock VLCKit
    /// 3 opts the audio session out of multichannel content right before it
    /// measures the HDMI route, so it folds every surround track to stereo;
    /// Ithaca's build carries the fix (`vlc-patches/0101`).
    static let outputsTVOSMultichannel: Bool = ithacaBuild != nil

    private static var frameworkInfo: [String: Any] {
        #if canImport(MobileVLCKit) || canImport(TVVLCKit)
        Bundle(for: VLCMediaPlayer.self).infoDictionary ?? [:]
        #else
        [:]
        #endif
    }
}
