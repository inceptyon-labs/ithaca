import SwiftUI

// MARK: - Detail Hero Section

@MainActor
func usesFullWidthDetailActionButtons(for sizeClass: UserInterfaceSizeClass?) -> Bool {
    #if os(iOS)
    sizeClass == .compact && UIDevice.current.userInterfaceIdiom == .phone
    #else
    false
    #endif
}

var detailHeroActionSpacing: CGFloat {
    #if os(tvOS)
    22
    #else
    12
    #endif
}

/// Minimum height of a detail-hero action label. tvOS sits a touch lower than iOS
/// because its label is the 27pt `buttonLabel` token rather than a 38pt semantic
/// style; iOS keeps the value it has always had.
var detailHeroActionLabelMinHeight: CGFloat {
    #if os(tvOS)
    30
    #else
    34
    #endif
}

#if os(tvOS)
/// Contained width for the left-aligned tvOS primary action, so "Play" / "Resume"
/// doesn't hug its own label. Scaled down with the label type.
let detailHeroTVActionLabelMinWidth: CGFloat = 220
#endif

/// Horizontal alignment for the detail hero's text/action blocks. iPhone centers
/// the whole hero (no poster); iPad and tvOS stay leading-aligned.
@MainActor
func detailHeroContentAlignment(for sizeClass: UserInterfaceSizeClass?) -> HorizontalAlignment {
    usesFullWidthDetailActionButtons(for: sizeClass) ? .center : .leading
}

/// Text alignment counterpart to `detailHeroContentAlignment(for:)`.
@MainActor
func detailHeroTextAlignment(for sizeClass: UserInterfaceSizeClass?) -> TextAlignment {
    usesFullWidthDetailActionButtons(for: sizeClass) ? .center : .leading
}

/// Whether the synopsis should render as its own section below the hero. The iPad
/// (regular) hero shows the description in its right column, so it is suppressed
/// below there; iPhone and tvOS keep the separate section.
@MainActor
func detailShowsSynopsisBelowHero(for sizeClass: UserInterfaceSizeClass?) -> Bool {
    #if os(tvOS)
    true
    #else
    sizeClass != .regular
    #endif
}

struct OfflineMetadataBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(IthacaFont.glyphSmall(ios: .caption.weight(.semibold)))
                .foregroundStyle(Color.ithacaTextSecondary)

            Text(message)
                .font(IthacaFont.caption(ios: .caption.weight(.medium)))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.ithacaSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// The show-title header shown in the season and episode detail heroes: the
/// show's clear-logo art (centered) when Plex provides it, falling back to the
/// show name, and wrapped in a link to the show so it doubles as navigation.
/// tvOS keeps the plain text — the image treatment is iOS-only.
struct DetailHeroShowTitleLink: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let title: String
    let logoURL: URL?
    let showRoute: AppNavigationRoute?

    // This is the show logo in its subordinate *supertitle* role (above a
    // season/episode text title), so it stays intentionally smaller than the
    // hero's main title artwork (`DetailHeroSection.titleArtworkHeight`).
    private var logoHeight: CGFloat {
        sizeClass == .regular ? 68 : 60
    }

    var body: some View {
        #if os(tvOS)
        titleText
        #else
        if let showRoute {
            NavigationLink(value: showRoute) {
                content
            }
            .buttonStyle(.plain)
            .ithacaSuppressTVOSButtonChrome()
        } else {
            content
        }
        #endif
    }

    // Centered on iPhone (the hero is a single centered column); leading on iPad,
    // where the artwork heads the left column of the two-column hero and is capped
    // to the same width as the Play button beneath it.
    #if !os(tvOS)
    private var contentAlignment: Alignment {
        sizeClass == .regular ? .leading : .center
    }

    @ViewBuilder
    private var content: some View {
        if let logoURL {
            IthacaAsyncImage(url: logoURL) { phase in
                switch phase {
                case let .success(image):
                    let art = image
                        .resizable()
                        .scaledToFit()
                    if sizeClass == .regular {
                        // iPad: fill the column width so it matches the Play button.
                        art.frame(width: detailHeroRegularPrimaryWidth, alignment: contentAlignment)
                    } else {
                        art
                            .frame(maxHeight: logoHeight)
                            .frame(maxWidth: .infinity, alignment: contentAlignment)
                    }
                case .empty:
                    Color.clear
                        .frame(height: logoHeight)
                case .failure:
                    alignedTitleText
                }
            }
        } else {
            alignedTitleText
        }
    }

    private var alignedTitleText: some View {
        titleText
            .frame(maxWidth: .infinity, alignment: contentAlignment)
    }
    #endif

    private var titleText: some View {
        Text(title)
            .font(IthacaFont.metadata(ios: .subheadline.weight(.medium)))
            .foregroundStyle(Color.primary.opacity(0.78))
    }
}

/// Pins the iPad hero's right-column synopsis to the top of the Play button in
/// the left column, so anything above the synopsis (a season/episode title and
/// marker) sits above the button rather than level with the metadata.
private extension VerticalAlignment {
    enum HeroDescriptionTop: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[.top]
        }
    }

    static let heroDescriptionTop = VerticalAlignment(HeroDescriptionTop.self)
}

struct DetailHeroSection<Supertitle: View, Subtitle: View, Actions: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    let backdropURL: URL?
    let titleArtworkURL: URL?
    let title: String
    var descriptionText: String? = nil
    let topInset: CGFloat
    let containerWidth: CGFloat
    var backgroundLeadingInset: CGFloat = 0
    var heroBaseHeight: CGFloat = 380
    var keepsPreviousBackdropWhileLoading = false
    var titleLineLimit: Int = 2
    /// Optional small view shown directly under the title (e.g. an episode's
    /// season·episode marker). Kept as `AnyView` so callers can opt in without
    /// adding another generic parameter to every hero.
    var titleAccessory: AnyView? = nil
    /// Drawn over the backdrop image and under its scrim, so the title block
    /// stays readable over it. tvOS puts the muted trailer preview here.
    var backdropAccessory: AnyView? = nil
    /// See `backdropHidden(_:)`.
    private var hidesBackdrop = false
    @ViewBuilder var supertitle: Supertitle
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions

    init(
        backdropURL: URL?,
        titleArtworkURL: URL? = nil,
        title: String,
        descriptionText: String? = nil,
        topInset: CGFloat,
        containerWidth: CGFloat,
        backgroundLeadingInset: CGFloat = 0,
        heroBaseHeight: CGFloat = 380,
        keepsPreviousBackdropWhileLoading: Bool = false,
        titleLineLimit: Int = 2,
        titleAccessory: AnyView? = nil,
        backdropAccessory: AnyView? = nil,
        @ViewBuilder supertitle: () -> Supertitle,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
        self.titleArtworkURL = titleArtworkURL
        self.title = title
        self.descriptionText = descriptionText
        self.topInset = topInset
        self.containerWidth = containerWidth
        self.backgroundLeadingInset = backgroundLeadingInset
        self.heroBaseHeight = heroBaseHeight
        self.keepsPreviousBackdropWhileLoading = keepsPreviousBackdropWhileLoading
        self.titleLineLimit = titleLineLimit
        self.titleAccessory = titleAccessory
        self.backdropAccessory = backdropAccessory
        self.supertitle = supertitle()
        self.subtitle = subtitle()
        self.actions = actions()
    }

    private var heroHeight: CGFloat { heroBaseHeight + topInset }

    /// Stops drawing the backdrop image while the accessory covers it (a
    /// playing trailer preview). On tvOS the backdrop group is masked, and
    /// moving video makes Core Animation redo that mask every frame, so a
    /// hidden image is one full-size layer less in each pass.
    func backdropHidden(_ isHidden: Bool) -> Self {
        var copy = self
        copy.hidesBackdrop = isHidden
        return copy
    }

    var body: some View {
        let horizontalPadding: CGFloat = {
            #if os(tvOS)
            IthacaPosterMetrics.detailHorizontalPadding
            #else
            20
            #endif
        }()
        let contentTopPadding: CGFloat = {
            #if os(tvOS)
            topInset + 80
            #else
            topInset + 64
            #endif
        }()
        let contentBottomPadding: CGFloat = {
            #if os(tvOS)
            40
            #else
            // Sit the title block lower so it reads over the background fade
            // rather than the busier middle of the artwork — easier to read,
            // especially the dark text in Light mode.
            14
            #endif
        }()
        let titleArtworkHeight: CGFloat = {
            // Match the home cinematic hero's title-logo size so the clear-logo
            // reads at the same scale on detail pages as in the home carousel
            // (HomeCinematicHeroLayout.titleLogoMaxHeight: 124 tvOS / 108 iOS).
            #if os(tvOS)
            124
            #else
            108
            #endif
        }()

        ZStack(alignment: .bottomLeading) {
            ZStack {
                DetailHeroBackdrop(
                    imageURL: backdropURL,
                    height: heroHeight,
                    keepsPreviousImageWhileLoading: keepsPreviousBackdropWhileLoading
                )
                .opacity(hidesBackdrop ? 0 : 1)

                if let backdropAccessory { backdropAccessory }

                IthacaHeroBackdropOverlay(style: .soft)
            }
            .frame(width: containerWidth, height: heroHeight, alignment: .leading)
            .ithacaHeroBackdropBottomFade()
            .offset(x: -backgroundLeadingInset)
            .allowsHitTesting(false)

            heroContent(titleArtworkHeight: titleArtworkHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, contentBottomPadding)
                .padding(.top, contentTopPadding)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func heroContent(titleArtworkHeight: CGFloat) -> some View {
        #if os(tvOS)
        tvOSHeroContent(titleArtworkHeight: titleArtworkHeight)
        #else
        if sizeClass == .regular {
            twoColumnHeroContent(titleArtworkHeight: titleArtworkHeight)
        } else {
            centeredHeroContent(titleArtworkHeight: titleArtworkHeight)
        }
        #endif
    }

    #if os(tvOS)
    // tvOS now drops the poster too: a left-aligned column (title, metadata) over
    // the backdrop with a single action row beneath it.
    @ViewBuilder
    private func tvOSHeroContent(titleArtworkHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                supertitle
                titleView(height: titleArtworkHeight, alignment: .leading)
                if let titleAccessory { titleAccessory }
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
    }
    #else
    // iPhone: one centered column over the backdrop, no poster. The logo, title
    // and metadata are a single tightly-spaced text group; the actions sit a
    // step further down as their own group (same grouping tvOS uses).
    @ViewBuilder
    private func centeredHeroContent(titleArtworkHeight: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 16) {
            VStack(alignment: .center, spacing: 8) {
                supertitle
                titleView(height: titleArtworkHeight, alignment: .center)
                if let titleAccessory { titleAccessory }
                subtitle
            }

            actions
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    // iPad: a two-column hero. The name artwork leads the top of the column at the
    // same width as the Play button. Below it the left column holds the metadata
    // then the Play button + secondary actions; the right column holds the synopsis
    // (for season/episode, preceded by the title + marker). The synopsis lines up
    // with the top of the Play button, so the title/marker sit above the button.
    //
    // Show/movie heroes use the clear-logo as their title (so it leads the left
    // column); season/episode heroes have a text title, so they lead with the show
    // logo and put the title + marker at the head of the right column.
    @ViewBuilder
    private func twoColumnHeroContent(titleArtworkHeight: CGFloat) -> some View {
        let columnWidth = detailHeroRegularPrimaryWidth

        if titleArtworkURL != nil {
            // Show / Movie: the clear-logo is the title and leads the left column;
            // the synopsis sits on the right, level with the metadata under it.
            VStack(alignment: .leading, spacing: 18) {
                titleView(height: titleArtworkHeight, alignment: .leading, width: columnWidth)

                HStack(alignment: .top, spacing: 36) {
                    VStack(alignment: .leading, spacing: 16) {
                        subtitle
                        actions
                    }
                    .frame(width: columnWidth, alignment: .leading)

                    descriptionColumn
                }
            }
        } else {
            // Season / Episode: the show logo leads; the title + marker head the
            // right column, and the synopsis below them lines up with the top of
            // the Play button so it doesn't drop too low.
            VStack(alignment: .leading, spacing: 18) {
                supertitle

                HStack(alignment: .heroDescriptionTop, spacing: 36) {
                    VStack(alignment: .leading, spacing: 16) {
                        subtitle
                        actions
                            .alignmentGuide(.heroDescriptionTop) { $0[.top] }
                    }
                    .frame(width: columnWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        titleView(height: titleArtworkHeight, alignment: .leading)
                        if let titleAccessory { titleAccessory }
                        descriptionColumn
                            .alignmentGuide(.heroDescriptionTop) { $0[.top] }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var descriptionColumn: some View {
        if let descriptionText, !descriptionText.isEmpty {
            ExpandableSummaryText(
                text: descriptionText,
                collapsedLineLimit: 8,
                allowsExpansion: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif

    // `width` (iPad) sizes the artwork to a fixed width so it fills to the Play
    // button's width; without it the logo is height-bound and centered/leading.
    @ViewBuilder
    private func titleView(height: CGFloat, alignment: Alignment, width: CGFloat? = nil) -> some View {
        if let titleArtworkURL {
            IthacaAsyncImage(url: titleArtworkURL) { phase in
                switch phase {
                case let .success(image):
                    // Flattened with its shadow into one image, so a trailer
                    // playing behind it doesn't redraw the shadow every frame.
                    // The padding keeps the shadow inside the flattened image.
                    let art = image
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                        .padding(24)
                        .drawingGroup()
                        .padding(-24)
                    if let width {
                        art.frame(width: width, alignment: alignment)
                    } else {
                        art.frame(maxWidth: .infinity, maxHeight: height, alignment: alignment)
                    }
                case .empty:
                    if let width {
                        Color.clear.frame(width: width, height: height)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: alignment)
                    }
                case .failure:
                    titleFallback(alignment: alignment)
                }
            }
        } else {
            titleFallback(alignment: alignment)
        }
    }

    private func titleFallback(alignment: Alignment) -> some View {
        Text(title)
            .font(IthacaFont.heroTitle(ios: .title2.bold()))
            // Soft near-black/near-white instead of pure `Color.primary` so the
            // title reads as a gentler grey, not harsh black, in Light mode.
            .foregroundStyle(Color.ithacaTextPrimary)
            .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .lineLimit(titleLineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment)
            .layoutPriority(1)
    }
}

extension DetailHeroSection where Supertitle == EmptyView {
    init(
        backdropURL: URL?,
        titleArtworkURL: URL? = nil,
        title: String,
        descriptionText: String? = nil,
        topInset: CGFloat,
        containerWidth: CGFloat,
        backgroundLeadingInset: CGFloat = 0,
        heroBaseHeight: CGFloat = 380,
        keepsPreviousBackdropWhileLoading: Bool = false,
        titleLineLimit: Int = 2,
        titleAccessory: AnyView? = nil,
        backdropAccessory: AnyView? = nil,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
        self.titleArtworkURL = titleArtworkURL
        self.title = title
        self.descriptionText = descriptionText
        self.topInset = topInset
        self.containerWidth = containerWidth
        self.backgroundLeadingInset = backgroundLeadingInset
        self.heroBaseHeight = heroBaseHeight
        self.keepsPreviousBackdropWhileLoading = keepsPreviousBackdropWhileLoading
        self.titleLineLimit = titleLineLimit
        self.titleAccessory = titleAccessory
        self.backdropAccessory = backdropAccessory
        self.supertitle = EmptyView()
        self.subtitle = subtitle()
        self.actions = actions()
    }
}

struct PlayVersionContextMenu: View {
    let versions: [PlexMedia]
    let onSelectVersion: (PlexMedia) -> Void

    var body: some View {
        if !playableVersions.isEmpty {
            Menu {
                ForEach(playableVersions) { version in
                    Button {
                        onSelectVersion(version)
                    } label: {
                        Text(MediaTextFormatter.playbackVersionMenuLabel(version))
                    }
                }
            } label: {
                Label("Play Version", systemImage: "play.square")
            }
        }
    }

    private var playableVersions: [PlexMedia] {
        versions.filter { !$0.parts.isEmpty }
    }
}

extension View {
    /// Presents the "Download Subtitles" (OpenSubtitles via Plex) flow the way
    /// each platform expects: a detented sheet on iOS/iPadOS, a full-screen
    /// cover on tvOS where sheets and context menus are awkward.
    func detailSubtitleSearchPresentation(
        isPresented: Binding<Bool>,
        viewModel: @escaping () -> SubtitleSearchViewModel
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented) {
            SubtitleSearchView(viewModel: viewModel()) { isPresented.wrappedValue = false }
        }
        #else
        sheet(isPresented: isPresented) {
            SubtitleSearchView(viewModel: viewModel()) { isPresented.wrappedValue = false }
        }
        #endif
    }
}

/// Icon-only secondary action label for detail heroes. Pairs with
/// `detailHeroNativeSecondaryButtonStyle()` to make a compact glass icon button
/// (a capsule pill on iOS, a circle on tvOS) without crowding the row with text.
struct DetailHeroSecondaryIconLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(IthacaFont.buttonLabel(ios: .subheadline.weight(.semibold)))
            // Square on tvOS so the circular button reads as round; a slimmer pill
            // on iOS where the secondaries sit in a capsule row.
            .frame(minWidth: iconMinWidth, minHeight: iconMinHeight)
            .contentShape(Capsule())
    }

    private var iconMinWidth: CGFloat {
        #if os(tvOS)
        // Kept equal to `iconMinHeight` — the tvOS button is a circle and goes
        // oval the moment these diverge.
        iconMinHeight
        #else
        24
        #endif
    }

    private var iconMinHeight: CGFloat {
        #if os(tvOS)
        30
        #else
        32
        #endif
    }
}

struct DetailHeroPrimaryActionButtonLabel: View {
    let title: String
    let systemImage: String
    var fillsWidth: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(IthacaFont.buttonLabel(ios: .headline.weight(.semibold)))

            Text(title)
                .font(IthacaFont.buttonLabel(ios: .headline))
                .lineLimit(1)
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: detailHeroActionLabelMinHeight)
        #if os(tvOS)
        // tvOS is left-aligned, so give the primary a contained width (space to its
        // right) rather than letting it hug the short "Play" / "Resume" label.
        // No label color: the system glass flips it between light (unfocused) and
        // dark (focused, on the white platter) by itself.
        .frame(minWidth: detailHeroTVActionLabelMinWidth)
        #else
        // The iOS primary fills with a translucent-`primary` prominent glass, so
        // the label uses the inverse color to stay legible on it.
        .foregroundStyle(Color.ithacaPrimaryActionLabel)
        #endif
        .contentShape(Capsule())
    }
}

struct DetailHeroStatusActionLabel: View {
    let title: String
    let systemImage: String
    var fillsWidth: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(IthacaFont.buttonLabel(ios: .headline.weight(.semibold)))

            Text(title)
                .font(IthacaFont.buttonLabel(ios: .headline))
                .lineLimit(1)
        }
        .foregroundStyle(Color.ithacaTextPrimary)
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: detailHeroActionLabelMinHeight)
        #if os(tvOS)
        .frame(minWidth: detailHeroTVActionLabelMinWidth)
        #endif
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .background(Color.ithacaSurface.opacity(0.86), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.ithacaTextSecondary.opacity(0.18), lineWidth: 1)
        }
        #if os(tvOS)
        // On a Seerr page with nothing to request this is the only control;
        // without a focus stop, focus falls to the tab bar.
        .focusable()
        .ithacaTVOSFocusEffectShape(Capsule())
        #endif
    }
}

extension View {
    @ViewBuilder
    func detailHeroNativePrimaryButtonStyle() -> some View {
        #if os(tvOS)
        // Plain system glass, like the TV app: a dark platter that lifts to white
        // with a dark label on focus. No tint: any explicit colour (even
        // `.primary`) recolours the label too and goes white-on-white on focus.
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
        #elseif os(iOS)
        // Prominent glass tinted with a *translucent* `primary`: a contrasting lean
        // (dark in Light mode, light in Dark) that still reads as liquid glass rather
        // than a solid black/white fill. `.regular` height keeps it compact.
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.ithacaPrimaryButtonTint)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func detailHeroNativeSecondaryButtonStyle() -> some View {
        #if os(tvOS)
        // tvOS secondaries are icon-only and sit beside the primary, so make them
        // round — there is no width to match. No tint, same as the primary.
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.circle)
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #else
        self
        #endif
    }

    /// Sizes and aligns the stacked iOS detail hero action block so the primary
    /// button and the secondary row underneath share a single width. iPhone uses
    /// ~60% of the screen, centered; iPad/regular uses a capped width, leading
    /// aligned in the hero text column. No-op on tvOS, which keeps its inline row.
    @ViewBuilder
    func detailHeroActionStackFrame(isCompactPhone: Bool) -> some View {
        #if os(iOS)
        if isCompactPhone {
            self
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(width * detailHeroCompactActionWidthFraction, 0)
                }
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            self
                .frame(maxWidth: detailHeroRegularPrimaryWidth, alignment: .leading)
        }
        #else
        self
        #endif
    }
}

/// Fraction of the hero (screen) width the iPhone primary action button spans.
let detailHeroCompactActionWidthFraction: CGFloat = 0.6

/// Shared width on iPad/regular for the primary action button and the title
/// artwork, so the logo reads at roughly the same width as the Play button
/// beneath it rather than filling the whole column.
let detailHeroRegularPrimaryWidth: CGFloat = 260

// MARK: - Actor Credit Card

struct ActorCreditCard: View {
    let person: PlexPersonReference
    /// The server this credit was read from; the person's page and avatar both
    /// have to be fetched from it, because person ids are per-server tag ids.
    let serverID: String?
    let plexService: PlexService
    #if os(tvOS)
    @State private var isFocused = false
    #endif

    var body: some View {
        #if os(tvOS)
        let avatarSize: CGFloat = 144
        let cardWidth: CGFloat = 156
        let avatarTextSpacing: CGFloat = 14
        let artworkShape = RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: avatarTextSpacing) {
            NavigationLink(value: AppNavigationRoute.person(person, serverID: serverID)) {
                avatarImage(size: avatarSize)
                    .background(FocusMirror(value: $isFocused))
            }
            .ithacaSuppressTVOSButtonChrome()
            .ithacaTVOSFocusEffectShape(artworkShape, scales: false)
            .accessibilityLabel(accessibilityLabel)
            .frame(width: avatarSize, height: avatarSize)

            personDetails(width: avatarSize)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .ithacaTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        #else
        NavigationLink(value: AppNavigationRoute.person(person, serverID: serverID)) {
            VStack(spacing: 8) {
                avatarImage(size: 72)
                personDetails(width: 80)
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
        .ithacaSuppressTVOSButtonChrome()
        #endif
    }

    @ViewBuilder
    private func avatarImage(size: CGFloat) -> some View {
        let imageSize = Int(size.rounded())
        let artworkShape = RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)

        Group {
            if let thumbPath = person.thumb {
                IthacaAsyncImage(url: plexService.imageURL(for: thumbPath, serverID: serverID, width: imageSize, height: imageSize)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholder(size: size)
                    }
                }
            } else {
                placeholder(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(artworkShape)
        .contentShape(artworkShape)
    }

    private func placeholder(size: CGFloat) -> some View {
        ZStack {
            Color.ithacaSurface

            Image(systemName: "person.fill")
                .font(.system(size: size * 0.30, weight: .regular))
                .foregroundStyle(Color.ithacaTextSecondary)
        }
    }

    private func personDetails(width: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(person.name)
                .font(IthacaFont.cardSubtitle(ios: .caption))
                .foregroundStyle(Color.primary)
                .lineLimit(1)

            if let roleName = person.roleName, !roleName.isEmpty {
                Text(roleName)
                    .font(IthacaFont.cardSubtitle(ios: .caption2))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .frame(width: width)
    }

    private var accessibilityLabel: String {
        if let roleName = person.roleName, !roleName.isEmpty {
            return "View \(person.name), \(roleName)"
        }

        return "View \(person.name)"
    }
}

struct DetailCastSection: View {
    let roles: [PlexRole]
    /// The server the item's metadata came from; its cast lives there too.
    let serverID: String?
    let plexService: PlexService
    var title = "Cast"
    var horizontalPadding: CGFloat = IthacaPosterMetrics.detailHorizontalPadding
    var maxVisibleRoles = 20

    var body: some View {
        #if os(tvOS)
        let castSpacing: CGFloat = 24
        let castVerticalPadding: CGFloat = 12
        let headerSpacing: CGFloat = 10
        #else
        let castSpacing: CGFloat = 12
        let castVerticalPadding: CGFloat = 0
        let headerSpacing: CGFloat = 12
        #endif

        VStack(alignment: .leading, spacing: headerSpacing) {
            Text(title)
                .font(IthacaFont.sectionHeader(ios: .headline))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: castSpacing) {
                    ForEach(Array(roles.prefix(maxVisibleRoles).enumerated()), id: \.offset) { _, role in
                        ActorCreditCard(
                            person: PlexPersonReference(role: role),
                            serverID: serverID,
                            plexService: plexService
                        )
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, castVerticalPadding)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

/// A movie's or show's extras as 16:9 cards. Selecting one plays it from the
/// start on its own server; extras have no copies on other servers to fall
/// back to (they share weak content keys, "Trailer" on every title).
struct DetailExtrasSection: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback

    let extras: [PlexItem]

    var body: some View {
        if !extras.isEmpty {
            PlexItemActionCarouselSection(
                title: "Extras",
                items: extras,
                action: play,
                posterWidth: IthacaPosterMetrics.videoCarouselWidth,
                imageAspectRatio: 16.0 / 9.0,
                subtitle: \.extraCardSubtitle,
                posterURL: { item, width, height in
                    item.posterImageURL(plexService: plexService, width: width, height: height)
                }
            ) { _ in
                EmptyView()
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func play(_ extra: PlexItem) {
        Task {
            await playback.playFromStart(
                id: extra.id,
                restrictToItemServer: true,
                placeholder: PlaybackPlaceholder(item: extra)
            )
        }
    }
}

struct ExpandableSummaryText: View {
    /// Default collapsed height of a synopsis block. tvOS fits one extra line in
    /// the same space now that the prose is 27pt rather than 29pt.
    static var defaultCollapsedLineLimit: Int {
        #if os(tvOS)
        10
        #else
        9
        #endif
    }

    let text: String
    var collapsedLineLimit = ExpandableSummaryText.defaultCollapsedLineLimit
    var foregroundStyle = Color.primary.opacity(0.76)
    var allowsExpansion = true

    @State private var isExpanded = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var expandedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                // Must stay identical to `measurementText` below, or the
                // expand/collapse height comparison stops matching the real text.
                .font(IthacaFont.body(ios: .body))
                .foregroundStyle(foregroundStyle)
                .lineSpacing(4)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .truncationMode(.tail)
                .overlay(alignment: .topLeading) {
                    ZStack {
                        measurementText(lineLimit: collapsedLineLimit) { height in
                            collapsedHeight = height
                        }

                        measurementText(lineLimit: nil) { height in
                            expandedHeight = height
                        }
                    }
                    .hidden()
                    .allowsHitTesting(false)
                }

            if allowsExpansion, isExpandable {
                Button(isExpanded ? "Show Less" : "Show More") {
                    isExpanded.toggle()
                }
                .font(IthacaFont.buttonLabel(ios: .subheadline.weight(.semibold)))
                #if os(tvOS)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                #else
                .foregroundStyle(Color.primary)
                .buttonStyle(.plain)
                #endif
            }
        }
    }

    private var isExpandable: Bool {
        expandedHeight > collapsedHeight + 1
    }

    private func measurementText(
        lineLimit: Int?,
        onHeightChange: @escaping (CGFloat) -> Void
    ) -> some View {
        Text(text)
            // Keep in lockstep with the visible text's font above.
            .font(IthacaFont.body(ios: .body))
            .lineSpacing(4)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            onHeightChange(proxy.size.height)
                        }
                        .onChange(of: proxy.size.height) { _, newHeight in
                            onHeightChange(newHeight)
                        }
                }
            }
    }
}

/// A detail page's hero drawn from the card that opened it (`DetailSeeds`)
/// while the page's metadata loads. Laid out like the loaded page's hero, so
/// the artwork requests are the ones the page makes and its images are already
/// cached when it appears.
struct DetailSeedHero: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    let title: String
    var summary: String? = nil
    var tagline: String? = nil
    /// The loaded page's hero height: this share of the screen, clamped.
    var heroHeightFraction: CGFloat = 0.72
    var heroHeightRange: ClosedRange<CGFloat> = 520...760
    var titleLineLimit = 2
    /// The show above a season or episode title, as `DetailHeroShowTitleLink`.
    var showTitle: String? = nil
    var showTitleLogoURL: ((_ width: Int, _ height: Int) -> URL?)? = nil
    let backdropURL: (_ width: Int, _ height: Int) -> URL?
    let titleLogoURL: (_ width: Int, _ height: Int) -> URL?

    var body: some View {
        GeometryReader { geometry in
            let containerWidth: CGFloat = {
                #if os(tvOS)
                geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
                #else
                geometry.size.width
                #endif
            }()
            let leadingInset: CGFloat = {
                #if os(tvOS)
                geometry.safeAreaInsets.leading
                #else
                0
                #endif
            }()
            let topInset = geometry.safeAreaInsets.top
            let heroBase = min(
                max(geometry.size.height * heroHeightFraction, heroHeightRange.lowerBound),
                heroHeightRange.upperBound
            )
            let heroHeight = heroBase + topInset

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeroSection(
                        backdropURL: backdropURL(Int(containerWidth.rounded(.up)), Int(heroHeight.rounded(.up))),
                        titleArtworkURL: titleLogoURL(Int((containerWidth * 0.45).rounded(.up)), 128),
                        title: title,
                        descriptionText: summary,
                        topInset: topInset,
                        containerWidth: containerWidth,
                        backgroundLeadingInset: leadingInset,
                        heroBaseHeight: heroBase,
                        titleLineLimit: titleLineLimit,
                        supertitle: {
                            if let showTitle {
                                DetailHeroShowTitleLink(
                                    title: showTitle,
                                    logoURL: showTitleLogoURL?(Int((containerWidth * 0.5).rounded(.up)), 128),
                                    showRoute: nil
                                )
                            }
                        },
                        subtitle: {
                            if let tagline {
                                Text(tagline)
                                    .font(IthacaFont.metadata(ios: .subheadline.weight(.medium)))
                                    .foregroundStyle(Color.primary.opacity(0.78))
                                    .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
                            }
                        },
                        actions: {
                            ProgressView()
                        }
                    )
                }
                .padding(.top, -topInset)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
            .scrollDisabled(true)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .ithacaTVOSPageBackground()
        }
    }
}

extension PlexItem {
    /// "2019 · PG-13 · 2h 12m", as a detail hero's tagline shows it.
    var detailSeedTagline: String? {
        let parts = [
            year.map(String.init),
            contentRating,
            MediaTextFormatter.playbackDuration(milliseconds: duration),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
