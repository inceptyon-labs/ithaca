import SwiftUI

struct SeerrSeasonDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: SeerrSeasonDetailViewModel

    init(tvID: Int, seasonNumber: Int, service: SeerrService) {
        _viewModel = State(initialValue: SeerrSeasonDetailViewModel(
            tvID: tvID,
            seasonNumber: seasonNumber,
            service: service
        ))
    }

    var body: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()
            if viewModel.isLoading && viewModel.season == nil {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.season == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else if let season = viewModel.season {
                content(season)
            }
        }
        .ithacaNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await viewModel.load() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, viewModel.season != nil else { return }
            Task { try? await viewModel.refresh() }
        }
        .alert(
            "Couldn’t Send Request",
            isPresented: Binding(
                get: { viewModel.actionError != nil },
                set: { if !$0 { viewModel.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.actionError ?? "")
        }
    }

    private func content(_ season: SeerrSeasonDetails) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeroSection(
                        backdropURL: viewModel.backdropURL(width: Int(geometry.size.width)),
                        title: season.name,
                        descriptionText: season.overview,
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: geometry.size.width,
                        heroBaseHeight: min(max(geometry.size.height * 0.62, 470), 680)
                    ) {
                        VStack(alignment: detailHeroContentAlignment(for: sizeClass), spacing: 6) {
                            if let showName = viewModel.show?.name {
                                Text(showName)
                                    .font(IthacaFont.metadata(ios: .subheadline.weight(.medium)))
                                    .foregroundStyle(Color.primary.opacity(0.84))
                            }
                            Text("\(season.episodes?.count ?? 0) episodes · \(viewModel.requestState.detailTitle)")
                                .font(IthacaFont.caption(ios: .caption))
                                .foregroundStyle(Color.primary.opacity(0.76))
                        }
                    } actions: {
                        if viewModel.canRequest {
                            Button {
                                guard !viewModel.isRequesting else { return }
                                viewModel.showsRequestConfirmation = true
                            } label: {
                                DetailHeroPrimaryActionButtonLabel(
                                    title: viewModel.requestTitle,
                                    systemImage: "paperplane.fill",
                                    fillsWidth: usesFullWidthDetailActionButtons(for: sizeClass)
                                )
                            }
                            .detailHeroNativePrimaryButtonStyle()
                            // tvOS keeps the focused button enabled ("Requesting…"
                            // says what is happening); disabling it would drop
                            // focus to the tab bar.
                            #if !os(tvOS)
                            .disabled(viewModel.isRequesting)
                            #endif
                            .confirmationDialog(
                                "Send this request?",
                                isPresented: $viewModel.showsRequestConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("Request") {
                                    Task { await viewModel.request() }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text(viewModel.requestTitle)
                            }
                        } else {
                            DetailHeroStatusActionLabel(
                                title: viewModel.requestTitle,
                                systemImage: viewModel.requestState.systemImage,
                                fillsWidth: usesFullWidthDetailActionButtons(for: sizeClass)
                            )
                        }
                    }
                    #if os(tvOS)
                    .focusSection()
                    #endif

                    if let overview = season.overview?.nilIfEmpty,
                       detailShowsSynopsisBelowHero(for: sizeClass) {
                        Text(overview)
                            .foregroundStyle(Color.ithacaTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, IthacaPosterMetrics.detailHorizontalPadding)
                            .padding(.top, 28)
                    }

                    LazyVStack(spacing: 12) {
                        ForEach(season.episodes ?? []) { episode in
                            HStack(spacing: 18) {
                                IthacaAsyncImage(
                                    url: viewModel.stillURL(for: episode)
                                ) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    default:
                                        Color.ithacaSurface
                                            .overlay(Image(systemName: "film").foregroundStyle(Color.ithacaTextSecondary))
                                    }
                                }
                                .frame(width: 160, height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(episode.name?.nilIfEmpty ?? "Episode \(episode.episodeNumber ?? 0)")
                                        .font(IthacaFont.rowTitle(ios: .headline))
                                        .foregroundStyle(Color.ithacaTextPrimary)
                                    if let episodeNumber = episode.episodeNumber {
                                        Text("Episode \(episodeNumber)")
                                            .font(IthacaFont.caption(ios: .caption))
                                            .foregroundStyle(Color.ithacaTextSecondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(Color.ithacaSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.horizontal, IthacaPosterMetrics.detailHorizontalPadding)
                    .padding(.top, 36)
                    .padding(.bottom, 56)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                try? await viewModel.refresh()
            }
            .ithacaTVOSPageBackground()
        }
    }
}
