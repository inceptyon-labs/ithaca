import SwiftUI

/// Settings › Hide Spoilers: an episode this profile hasn't started shows a
/// blurred picture and no summary, wherever Ithaca would show either. A
/// started episode shows normally: its viewer has already seen how it opens.
extension UserPreferences {
    func hidesSpoilers(viewCount: Int?, viewOffset: Int?) -> Bool {
        hidesEpisodeSpoilers && (viewCount ?? 0) == 0 && (viewOffset ?? 0) == 0
    }

    /// For a screen that knows the episode's state better than Plex's listing
    /// does: watched or started offline on a download.
    func hidesSpoilers(isStarted: Bool) -> Bool {
        hidesEpisodeSpoilers && !isStarted
    }

    func hidesSpoilers(for episode: PlexEpisode) -> Bool {
        hidesSpoilers(viewCount: episode.viewCount, viewOffset: episode.viewOffset)
    }

    /// Only for episodes; any other item shows normally.
    func hidesSpoilers(for item: PlexItem) -> Bool {
        item.type == .episode && hidesSpoilers(viewCount: item.viewCount, viewOffset: item.viewOffset)
    }

    func hidesSpoilers(for details: PlexMediaDetails) -> Bool {
        details.type == .episode && hidesSpoilers(viewCount: details.viewCount, viewOffset: details.viewOffset)
    }
}

enum EpisodeSpoilers {
    /// Shown in place of a hidden summary.
    static let hiddenSummary = "Summary hidden until you start this episode."
}

extension View {
    /// Blurs an episode still past making anything out. Opaque, so the edges
    /// stay sharp inside the artwork's frame.
    func spoilerBlurred(_ isActive: Bool) -> some View {
        blur(radius: isActive ? 28 : 0, opaque: true)
    }
}
