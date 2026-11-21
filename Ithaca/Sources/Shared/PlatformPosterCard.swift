import SwiftUI

struct PosterNavigationCard<ContextMenuContent: View>: View {
    let route: AppNavigationRoute
    let imageURL: URL?
    let title: String
    var subtitle: String?
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay = false
    var availabilityBadge: String? = nil
    var isDimmed = false
    var isWatched = false
    /// Hide Spoilers: an unstarted episode's still, blurred.
    var hidesImage = false
    @ViewBuilder let contextMenuContent: () -> ContextMenuContent
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let artworkShape = RoundedRectangle(
            cornerRadius: PosterArtwork.cornerRadius,
            style: .continuous
        )

        VStack(alignment: .leading, spacing: IthacaPosterMetrics.cardSpacing) {
            NavigationLink(value: route) {
                PosterArtwork(
                    imageURL: imageURL,
                    progress: progress,
                    width: width,
                    imageAspectRatio: imageAspectRatio,
                    showsPlayOverlay: showsPlayOverlay,
                    availabilityBadge: availabilityBadge,
                    isDimmed: isDimmed,
                    hidesImage: hidesImage
                )
                .contentShape(.contextMenuPreview, artworkShape)
            }
            .ithacaSuppressTVOSButtonChrome()
            .focused($isFocused)
            .carouselLeadingFocusTarget($isFocused)
            .ithacaTVOSFocusEffectShape(artworkShape, scales: false)
            .contextMenu {
                contextMenuContent()
            }

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width,
                isWatched: isWatched
            )
        }
        .frame(width: width, alignment: .topLeading)
        .ithacaTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        #else
        NavigationLink(value: route) {
            PosterCard(
                imageURL: imageURL,
                title: title,
                subtitle: subtitle,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio,
                showsPlayOverlay: showsPlayOverlay,
                availabilityBadge: availabilityBadge,
                isDimmed: isDimmed,
                isWatched: isWatched,
                hidesImage: hidesImage
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .ithacaSuppressTVOSButtonChrome()
        .contextMenu {
            contextMenuContent()
        }
        #endif
    }
}

extension PosterNavigationCard where ContextMenuContent == EmptyView {
    init(
        route: AppNavigationRoute,
        imageURL: URL?,
        title: String,
        subtitle: String? = nil,
        progress: Double? = nil,
        width: CGFloat = 130,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        showsPlayOverlay: Bool = false,
        availabilityBadge: String? = nil,
        isDimmed: Bool = false,
        isWatched: Bool = false,
        hidesImage: Bool = false
    ) {
        self.route = route
        self.imageURL = imageURL
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.width = width
        self.imageAspectRatio = imageAspectRatio
        self.showsPlayOverlay = showsPlayOverlay
        self.availabilityBadge = availabilityBadge
        self.isDimmed = isDimmed
        self.isWatched = isWatched
        self.hidesImage = hidesImage
        self.contextMenuContent = { EmptyView() }
    }
}

struct PosterActionCard<ContextMenuContent: View>: View {
    let action: () -> Void
    let imageURL: URL?
    let title: String
    var subtitle: String?
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay = false
    var availabilityBadge: String? = nil
    var isDimmed = false
    @ViewBuilder let contextMenuContent: () -> ContextMenuContent
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let artworkShape = RoundedRectangle(
            cornerRadius: PosterArtwork.cornerRadius,
            style: .continuous
        )

        VStack(alignment: .leading, spacing: IthacaPosterMetrics.cardSpacing) {
            Button(action: action) {
                PosterArtwork(
                    imageURL: imageURL,
                    progress: progress,
                    width: width,
                    imageAspectRatio: imageAspectRatio,
                    showsPlayOverlay: showsPlayOverlay,
                    availabilityBadge: availabilityBadge,
                    isDimmed: isDimmed
                )
                .contentShape(.contextMenuPreview, artworkShape)
            }
            .ithacaSuppressTVOSButtonChrome()
            .focused($isFocused)
            .carouselLeadingFocusTarget($isFocused)
            .ithacaTVOSFocusEffectShape(artworkShape, scales: false)
            .contextMenu {
                contextMenuContent()
            }

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width
            )
        }
        .frame(width: width, alignment: .topLeading)
        .ithacaTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        #else
        Button(action: action) {
            PosterCard(
                imageURL: imageURL,
                title: title,
                subtitle: subtitle,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio,
                showsPlayOverlay: showsPlayOverlay,
                availabilityBadge: availabilityBadge,
                isDimmed: isDimmed
            )
        }
        .buttonStyle(.plain)
        .ithacaSuppressTVOSButtonChrome()
        .contextMenu {
            contextMenuContent()
        }
        #endif
    }
}

extension PosterActionCard where ContextMenuContent == EmptyView {
    init(
        action: @escaping () -> Void,
        imageURL: URL?,
        title: String,
        subtitle: String? = nil,
        progress: Double? = nil,
        width: CGFloat = 130,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        showsPlayOverlay: Bool = false,
        availabilityBadge: String? = nil,
        isDimmed: Bool = false
    ) {
        self.action = action
        self.imageURL = imageURL
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.width = width
        self.imageAspectRatio = imageAspectRatio
        self.showsPlayOverlay = showsPlayOverlay
        self.availabilityBadge = availabilityBadge
        self.isDimmed = isDimmed
        self.contextMenuContent = { EmptyView() }
    }
}
