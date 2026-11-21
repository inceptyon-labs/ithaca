import SwiftUI

/// Home's Your Requests row: the user's Seerr requests from waiting, through
/// Radarr/Sonarr's download progress, to ready to play. Renders nothing while
/// Seerr is not connected, there is nothing to show, or Settings turns it off.
/// Home polls the tracker (`HomeView`) either way, so arrival notifications
/// still come; this only draws it.
struct SeerrRequestsHomeRow: View {
    @Environment(SeerrRequestTracker.self) private var tracker
    @Environment(SeerrService.self) private var seerrService
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences

    /// Whether the row renders. tvOS Home mirrors it to pick the shelf the
    /// hero's down-press lands on.
    static func isShown(in tracker: SeerrRequestTracker, preferences: UserPreferences) -> Bool {
        preferences.showsRequestsOnHome && tracker.hasItems
    }

    var body: some View {
        if Self.isShown(in: tracker, preferences: preferences) {
            let width = IthacaPosterMetrics.carouselPosterWidth
            let aspectRatio = 2.0 / 3.0
            let imageSize = PlexItemPosterCarouselSection<EmptyView>.imagePixelSize(
                posterWidth: width,
                imageAspectRatio: aspectRatio
            )
            let imageWidth = plexService.scaledImageDimension(imageSize.width) ?? imageSize.width

            let leadingID = tracker.items.first?.id

            MediaCarousel(title: "Your Requests") {
                ForEach(tracker.items) { item in
                    PosterNavigationCard(
                        route: item.route,
                        imageURL: seerrService.posterURL(path: item.posterPath, width: imageWidth),
                        title: item.title,
                        subtitle: subtitle(for: item),
                        progress: progress(for: item),
                        width: width,
                        imageAspectRatio: aspectRatio,
                        showsPlayOverlay: item.phase == .ready,
                        availabilityBadge: item.phase.badgeTitle
                    )
                    // On tvOS Home this can be the shelf the hero lands on.
                    .carouselItemFocusLock(isLeadingItem: item.id == leadingID)
                }
            }
        }
    }

    private func subtitle(for item: SeerrRequestTracker.Item) -> String? {
        if case .downloading(let progress) = item.phase {
            return progress.label()
        }
        return item.detail
    }

    private func progress(for item: SeerrRequestTracker.Item) -> Double? {
        if case .downloading(let progress) = item.phase {
            return progress.fraction
        }
        return nil
    }
}
