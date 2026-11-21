import SwiftUI

/// The tvOS Discover tab, shown while Seerr is connected.
struct DiscoverView: View {
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            DiscoverRootContent()
                .ithacaAppNavigationDestinations()
        }
    }
}

/// Seerr's trending, popular and upcoming lists as poster rows. The tvOS tab
/// root, and a pushed page on iPhone and iPad (`AppNavigationRoute.discover`).
struct DiscoverRootContent: View {
    @Environment(PlexService.self) private var plexService
    @Environment(SeerrService.self) private var seerrService
    @Environment(TasteRecommender.self) private var tasteRecommender
    @State private var viewModel: DiscoverViewModel?

    var body: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()

            if let viewModel {
                content(viewModel)
            } else {
                FeatureLoadingView()
            }
        }
        .ithacaNavigationTitle("Discover")
        .ithacaNavigationBarTitleDisplayModeLarge()
        .task(id: seerrService.isAvailableForCurrentContext) {
            let model = viewModel ?? DiscoverViewModel(
                seerrService: seerrService,
                plexService: plexService,
                tasteRecommender: tasteRecommender
            )
            viewModel = model
            // Runs again on every reappear (Back from a title), which only
            // loads when nothing is loaded yet; staleness is handled below.
            await model.load()
        }
        .onAppear {
            Task { await viewModel?.reloadIfStale() }
        }
    }

    @ViewBuilder
    private func content(_ viewModel: DiscoverViewModel) -> some View {
        if !viewModel.rows.isEmpty {
            rows(viewModel)
        } else if viewModel.isLoading {
            FeatureLoadingView()
        } else if let error = viewModel.error {
            FeatureErrorView(message: error) {
                Task { await viewModel.load(force: true) }
            }
        } else if !seerrService.isAvailableForCurrentContext {
            FeatureEmptyStateView(
                systemImage: "sparkles",
                title: "Seerr Isn't Connected",
                message: "Connect Seerr in Settings to discover and request movies and shows."
            )
        } else {
            FeatureLoadingView()
        }
    }

    private func rows(_ viewModel: DiscoverViewModel) -> some View {
        let width = IthacaPosterMetrics.carouselPosterWidth
        let aspectRatio = 2.0 / 3.0
        let imageSize = PlexItemPosterCarouselSection<EmptyView>.imagePixelSize(
            posterWidth: width,
            imageAspectRatio: aspectRatio
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: IthacaPosterMetrics.pageSectionSpacing) {
                ForEach(viewModel.rows) { row in
                    MediaCarousel(title: row.title) {
                        ForEach(row.items, id: \.discoverKey) { item in
                            PosterNavigationCard(
                                route: viewModel.route(for: item),
                                imageURL: viewModel.posterURL(for: item, width: imageSize.width),
                                title: item.displayTitle,
                                subtitle: item.year.map(String.init),
                                width: width,
                                imageAspectRatio: aspectRatio,
                                availabilityBadge: viewModel.badge(for: item)
                            )
                        }
                    }
                }
            }
            .padding(.top, IthacaPosterMetrics.pageSectionSpacing)
            .padding(.bottom, IthacaPosterMetrics.pageBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .focusSection()
            #endif
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .scrollIndicators(.hidden)
        #if os(iOS)
        .refreshable { await viewModel.load(force: true, refreshesRecommendations: true) }
        #endif
    }
}

/// The destination for `AppNavigationRoute.seerrInPlex`: the title's Plex page
/// once its Plex copy is found, otherwise the Seerr page.
struct DiscoverPlexTitleView: View {
    @Environment(PlexService.self) private var plexService
    let type: SeerrMediaType
    let tmdbID: Int
    let title: String
    @State private var resolver: DiscoverPlexTitleResolver?

    var body: some View {
        Group {
            switch resolver?.state ?? .resolving {
            case .resolving:
                ZStack {
                    Color.ithacaBackground.ignoresSafeArea()
                    FeatureLoadingView()
                }
            case .found(let item):
                AppNavigationDestinationView(route: AppNavigationRoute.destination(for: item))
            case .notFound:
                AppNavigationDestinationView(route: .seerrMedia(type: type, id: tmdbID))
            }
        }
        .task {
            guard resolver == nil else { return }
            let resolver = DiscoverPlexTitleResolver(plexService: plexService)
            self.resolver = resolver
            await resolver.resolve(type: type, tmdbID: tmdbID, title: title)
        }
    }
}

#if os(iOS)
/// Opens Discover from Home's toolbar while Seerr is connected.
struct DiscoverToolbarLink: View {
    var body: some View {
        NavigationLink(value: AppNavigationRoute.discover) {
            Image(systemName: "sparkles")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary)
        }
        .tint(Color.primary)
        .accessibilityLabel("Discover")
    }
}
#endif
