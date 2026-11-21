import SwiftUI

/// "Pick Something": three titles that fit how long you have, a genre, and
/// who's watching, with a reroll. Describe It (Ithaca Pro) picks from what
/// the viewer types instead, and with Seerr, suggests titles to request: on
/// the device, or with Claude through Athena when one is set up. Opened from
/// the Home row or Siri.
struct PickSomethingView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(SeerrService.self) private var seerrService
    @State private var viewModel: PickSomethingViewModel
    @State private var describeText = ""
    @State private var showsPro = false

    init(
        initialKind: PickSomethingKind,
        plexService: PlexService,
        preferences: UserPreferences,
        tasteRecommender: TasteRecommender,
        seerrService: SeerrService,
        store: IthacaStore
    ) {
        _viewModel = State(initialValue: PickSomethingViewModel(
            initialKind: initialKind,
            plexService: plexService,
            preferences: preferences,
            tasteRecommender: tasteRecommender,
            seerrService: seerrService,
            store: store
        ))
    }

    var body: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    #if os(tvOS)
                    header
                    describeRow
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                    // Each row is a full-width focus section, so Up and Down
                    // reach the next row from anywhere: the chips sit left,
                    // the picks and Pick Again are centred.
                    HStack(alignment: .center, spacing: 40) {
                        filterControls
                        watchingRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                    #else
                    describeRow
                        .padding(.horizontal, horizontalPadding)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) { filterControls }
                            .padding(.horizontal, horizontalPadding)
                    }
                    watchingRow
                        .padding(.horizontal, horizontalPadding)
                    #endif

                    picksArea
                    requestablesArea
                }
                #if os(tvOS)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 24)
                #else
                .padding(.top, 8)
                #endif
                .padding(.bottom, IthacaPosterMetrics.pageBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
        .ithacaNavigationTitle("Pick Something")
        .ithacaNavigationBarTitleDisplayModeLarge()
        // `isConnecting` too: servers that fail to connect change no revision,
        // and a load that was waiting for them has to settle.
        .task(id: PickSomethingLoadTrigger(
            revision: plexService.serverContentRevision,
            isConnecting: plexService.pool.isConnecting
        )) {
            await viewModel.load()
            #if DEBUG
            if let text = ScreenshotMode.consumeDescribeText() {
                describeText = text
                viewModel.describe(text)
            }
            #endif
        }
        .onDisappear { viewModel.stop() }
        .actionErrorAlert(viewModel.actionError) { viewModel.actionError = nil }
        .alert(
            "Send Describe It to Athena?",
            isPresented: athenaConsentShown,
            presenting: viewModel.requestAwaitingConsent
        ) { request in
            Button("Use Athena") { viewModel.answerAthenaConsent(true, for: request) }
            Button("Use This Device") { viewModel.answerAthenaConsent(false, for: request) }
        } message: { _ in
            Text("Athena at \(viewModel.athenaAwaitingConsent ?? "your server") sends what you type, and the titles in your library that fit, to Anthropic's Claude to choose from. On this device, nothing leaves it. You can change this in Settings → Athena.")
        }
        #if os(tvOS)
        .fullScreenCover(item: pinMemberBinding) { member in
            PickSomethingPINEntry(member: member, viewModel: viewModel)
        }
        #else
        .sheet(item: pinMemberBinding) { member in
            PickSomethingPINEntry(member: member, viewModel: viewModel)
        }
        #endif
    }

    private var pinMemberBinding: Binding<PlexHomeUser?> {
        Binding(
            get: { viewModel.pinMember },
            set: { if $0 == nil { viewModel.cancelPIN() } }
        )
    }

    // MARK: Header and filters

    #if os(tvOS)
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick Something")
                .font(IthacaFont.TV.pageTitleRounded)
                .foregroundStyle(Color.ithacaTextPrimary)
            Text("Three picks from your libraries.")
                .font(IthacaFont.TV.pageSubtitle)
                .foregroundStyle(Color.ithacaTextSecondary)
        }
    }
    #endif

    @ViewBuilder
    private var filterControls: some View {
        let criteria = viewModel.criteria

        if viewModel.availableKinds.count > 1 {
            Menu {
                Section("Pick From") {
                    ForEach(viewModel.availableKinds) { kind in
                        Button { viewModel.setKind(kind) } label: {
                            checkmarkLabel(kind.title, isSelected: kind == criteria.kind)
                        }
                    }
                }
            } label: {
                FilterMenuChipLabel(
                    value: criteria.kind.title,
                    systemImage: criteria.kind == .movie ? "film" : "tv",
                    isActive: false,
                    accessibilityLabel: "Movies or TV Shows"
                )
            }
            .ithacaSuppressTVOSButtonChrome()
        }

        Menu {
            Section(criteria.kind == .movie ? "Running Time" : "Episode Length") {
                ForEach(viewModel.runtimeOptions) { runtime in
                    Button { viewModel.setRuntime(runtime) } label: {
                        checkmarkLabel(runtime.title, isSelected: runtime == criteria.runtime)
                    }
                }
            }
        } label: {
            FilterMenuChipLabel(
                value: criteria.runtime.title,
                systemImage: "clock",
                isActive: criteria.runtime != .any,
                accessibilityLabel: "Length"
            )
        }
        .ithacaSuppressTVOSButtonChrome()

        if !viewModel.genreTitles.isEmpty {
            Menu {
                Section("Genre") {
                    Button { viewModel.setGenre(nil) } label: {
                        checkmarkLabel("Any Genre", isSelected: criteria.genreTitle == nil)
                    }
                    ForEach(viewModel.genreTitles, id: \.self) { title in
                        Button { viewModel.setGenre(title) } label: {
                            checkmarkLabel(title, isSelected: title == criteria.genreTitle)
                        }
                    }
                }
            } label: {
                FilterMenuChipLabel(
                    value: criteria.genreTitle ?? "Any Genre",
                    systemImage: "theatermasks",
                    isActive: criteria.genreTitle != nil,
                    accessibilityLabel: "Genre"
                )
            }
            .ithacaSuppressTVOSButtonChrome()
        }

        FilterToggleChip(
            title: "Unwatched",
            isOn: criteria.unwatchedOnly,
            accessibilityLabel: "Only titles nobody watching has seen"
        ) {
            viewModel.setUnwatchedOnly(!criteria.unwatchedOnly)
        }
    }

    @ViewBuilder
    private func checkmarkLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: Describe It

    @ViewBuilder
    private var describeRow: some View {
        if !viewModel.canDescribe {
            lockedDescribeRow
        } else {
            HStack(spacing: 20) {
                describeField

                if viewModel.isPicking, viewModel.request != nil {
                    ProgressView()
                }

                #if os(tvOS)
                if viewModel.request != nil {
                    Button {
                        describeText = ""
                        viewModel.describe("")
                    } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                }
                #endif
            }
        }
    }

    private static let describePrompt = "Describe what you're in the mood for"

    /// Without Ithaca Pro: the field's place, opening Ithaca Pro.
    private var lockedDescribeRow: some View {
        Button {
            showsPro = true
        } label: {
            #if os(tvOS)
            Label("Describe It with Ithaca Pro", systemImage: "sparkles")
            #else
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.ithacaTextSecondary)
                Text(Self.describePrompt)
                    .foregroundStyle(Color.ithacaTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Ithaca Pro")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ithacaTextPrimary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.ithacaSurface, in: Capsule())
            .frame(maxWidth: 720, alignment: .leading)
            .contentShape(Capsule())
            #endif
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
        .sheet(isPresented: $showsPro) {
            ProSheet()
        }
    }

    private var athenaConsentShown: Binding<Bool> {
        Binding(
            get: { viewModel.athenaAwaitingConsent != nil },
            set: { if !$0 { viewModel.cancelAthenaConsent() } }
        )
    }

    @ViewBuilder
    private var describeField: some View {
        #if os(tvOS)
        // Select opens the system keyboard, with dictation on the remote.
        TextField(Self.describePrompt, text: $describeText)
            .onSubmit { viewModel.describe(describeText) }
            .frame(maxWidth: 900)
        #else
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.ithacaTextSecondary)
            TextField(Self.describePrompt, text: $describeText)
                .submitLabel(.go)
                .onSubmit { viewModel.describe(describeText) }
            if !describeText.isEmpty {
                Button {
                    describeText = ""
                    viewModel.describe("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.ithacaTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Color.ithacaSurface, in: Capsule())
        .frame(maxWidth: 720, alignment: .leading)
        #endif
    }

    // MARK: Who's watching

    @ViewBuilder
    private var watchingRow: some View {
        let others = viewModel.otherMembers
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Text("Watching")
                        .font(IthacaFont.groupHeader(ios: .subheadline.weight(.semibold)))
                        .foregroundStyle(Color.ithacaTextSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: memberSpacing) {
                            if let active = viewModel.activeMember {
                                PickSomethingMemberButton(
                                    member: active,
                                    isWatching: true,
                                    isLoading: false,
                                    isFixed: true,
                                    action: {}
                                )
                            }
                            ForEach(others) { member in
                                PickSomethingMemberButton(
                                    member: member,
                                    isWatching: viewModel.isWatching(member),
                                    isLoading: viewModel.loadingMemberID == member.id,
                                    isFixed: false
                                ) {
                                    viewModel.toggle(member)
                                }
                            }
                        }
                        #if os(tvOS)
                        .padding(.vertical, 14)
                        #endif
                    }
                    #if os(tvOS)
                    .scrollClipDisabled()
                    #endif
                }

                if let memberError = viewModel.memberError {
                    Text(memberError)
                        .font(IthacaFont.caption(ios: .footnote))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Picks

    @ViewBuilder
    private var picksArea: some View {
        if let error = viewModel.error, viewModel.picks.isEmpty {
            FeatureErrorView(message: error) { viewModel.retry() }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if viewModel.hasNoMatches {
            FeatureEmptyStateView(
                systemImage: "dice",
                title: viewModel.availableKinds.isEmpty ? "No Movies or TV Shows" : "Nothing Fits",
                message: viewModel.availableKinds.isEmpty
                    ? "Pick Something chooses from your movie and TV libraries."
                    : emptyMessage
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if viewModel.picks.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            VStack(spacing: sectionSpacing) {
                pickCards
                    .opacity(viewModel.isPicking ? 0.5 : 1)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isPicking)

                pickAgainButton

                if viewModel.didWrapAround || viewModel.didRunOut {
                    Text(viewModel.didWrapAround
                        ? "That's everything that fits, so the picks start over."
                        : "That's everything that fits.")
                        .font(IthacaFont.caption(ios: .footnote))
                        .foregroundStyle(Color.ithacaTextSecondary)
                } else if let error = viewModel.error {
                    Text(error)
                        .font(IthacaFont.caption(ios: .footnote))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyMessage: String {
        if viewModel.request != nil {
            return "Nothing in your library fits that. Describe it another way, or change the filters."
        }
        let others = viewModel.watchingMemberIDs.isEmpty ? "" : ", fewer people watching"
        let unwatched = viewModel.criteria.unwatchedOnly ? ", or turn off Unwatched" : ""
        return "Try another genre or length\(others)\(unwatched)."
    }

    @ViewBuilder
    private var pickCards: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: 64) {
            // Keyed by slot so focus stays on the slot when Seen It swaps its card.
            ForEach(Array(viewModel.picks.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 28) {
                    PosterNavigationCard(
                        route: AppNavigationRoute.destination(for: item),
                        imageURL: item.posterImageURL(plexService: plexService, width: 280, height: 420),
                        title: item.title,
                        subtitle: metadataLine(for: item),
                        width: 280
                    ) {
                        markWatchedButton(for: item)
                    }

                    if let reason = viewModel.reason(for: item) {
                        Text(reason)
                            .font(IthacaFont.caption(ios: .footnote))
                            .foregroundStyle(Color.ithacaTextSecondary)
                            .lineLimit(3)
                            .frame(width: 280, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
        #else
        VStack(spacing: 18) {
            ForEach(viewModel.picks) { item in
                NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                    PickSomethingRow(
                        title: item.title,
                        posterURL: item.posterImageURL(plexService: plexService, width: 96, height: 144),
                        metadata: metadataLine(for: item),
                        genres: item.genres?.prefix(3).map(\.tag).joined(separator: ", ").nilIfEmpty,
                        reason: viewModel.reason(for: item),
                        summary: item.summary
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { markWatchedButton(for: item) }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: 720)
        #endif
    }

    private func markWatchedButton(for item: PlexItem) -> some View {
        Button {
            Task { await viewModel.markWatched(item) }
        } label: {
            Label("Seen It", systemImage: "eye")
        }
    }

    private var pickAgainButton: some View {
        Button {
            viewModel.pickAgain()
        } label: {
            HomeHeroActionButtonLabel(title: "Pick Again", systemImage: "dice")
        }
        .homeHeroNativeButtonStyle()
        #if os(tvOS)
        .frame(maxWidth: .infinity)
        .focusSection()
        #endif
    }

    private func metadataLine(for item: PlexItem) -> String? {
        var parts: [String] = []
        if let year = item.year {
            parts.append(String(year))
        }
        if item.type == .show {
            if let seasons = MediaTextFormatter.seasonCount(item.childCount) {
                parts.append(seasons)
            }
        } else if let duration = MediaTextFormatter.playbackDuration(milliseconds: item.duration) {
            parts.append(duration)
        }
        if let rating = item.contentRating?.nilIfEmpty {
            parts.append(rating)
        }
        if let score = ReviewScores(item: item).label {
            parts.append(score)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: To Request

    @ViewBuilder
    private var requestablesArea: some View {
        let requestables = viewModel.requestables
        // A failed Athena request already says so above.
        let requestError = viewModel.error == nil ? viewModel.requestError : nil
        if viewModel.isFindingRequestables || !requestables.isEmpty || requestError != nil {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Text("To Request")
                        .font(IthacaFont.sectionHeader(ios: .title3.bold()))
                        .foregroundStyle(Color.ithacaTextPrimary)
                    if viewModel.isFindingRequestables {
                        ProgressView()
                    }
                }
                if let requestError {
                    Text(requestError)
                        .font(IthacaFont.caption(ios: .footnote))
                        .foregroundStyle(Color.ithacaTextSecondary)
                }
                requestableCards(requestables)
            }
            #if os(tvOS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            #else
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            #endif
        }
    }

    @ViewBuilder
    private func requestableCards(_ requestables: [PickSomethingRequestable]) -> some View {
        #if os(tvOS)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 48) {
                ForEach(requestables) { requestable in
                    VStack(alignment: .leading, spacing: 24) {
                        PosterNavigationCard(
                            route: .seerrMedia(type: requestable.type, id: requestable.media.id),
                            imageURL: posterURL(for: requestable, width: 220),
                            title: requestable.media.displayTitle,
                            subtitle: metadataLine(for: requestable),
                            width: 220
                        )
                        if let reason = requestable.reason ?? requestable.media.overview?.nilIfEmpty {
                            Text(reason)
                                .font(IthacaFont.caption(ios: .footnote))
                                .foregroundStyle(Color.ithacaTextSecondary)
                                .lineLimit(3)
                                .frame(width: 220, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        #else
        ForEach(requestables) { requestable in
            NavigationLink(value: AppNavigationRoute.seerrMedia(type: requestable.type, id: requestable.media.id)) {
                PickSomethingRow(
                    title: requestable.media.displayTitle,
                    posterURL: posterURL(for: requestable, width: 96),
                    metadata: metadataLine(for: requestable),
                    genres: nil,
                    reason: requestable.reason,
                    summary: requestable.media.overview
                )
            }
            .buttonStyle(.plain)
        }
        #endif
    }

    private func posterURL(for requestable: PickSomethingRequestable, width: Int) -> URL? {
        seerrService.posterURL(
            path: requestable.media.posterPath,
            width: plexService.scaledImageDimension(width) ?? width
        )
    }

    private func metadataLine(for requestable: PickSomethingRequestable) -> String? {
        let parts = [requestable.media.year.map(String.init), requestable.scores.label].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Metrics

    private var horizontalPadding: CGFloat {
        IthacaPosterMetrics.carouselHorizontalPadding
    }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        22
        #endif
    }

    private var memberSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        14
        #endif
    }
}

private struct PickSomethingLoadTrigger: Equatable {
    let revision: ServerContentRevision
    let isConnecting: Bool
}

#if !os(tvOS)
/// One pick or title to request on iPhone and iPad: poster, the facts, and
/// Athena's reason or the start of the summary.
private struct PickSomethingRow: View {
    let title: String
    let posterURL: URL?
    let metadata: String?
    let genres: String?
    let reason: String?
    let summary: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterArtwork(imageURL: posterURL, width: 96)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.ithacaTextPrimary)
                    .lineLimit(2)

                if let metadata {
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundStyle(Color.ithacaTextSecondary)
                }

                if let genres {
                    Text(genres)
                        .font(.subheadline)
                        .foregroundStyle(Color.ithacaTextSecondary)
                        .lineLimit(1)
                }

                if let reason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(Color.ithacaTextPrimary)
                        .padding(.top, 2)
                } else if let summary = summary?.nilIfEmpty {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(Color.ithacaTextSecondary)
                        .lineLimit(4)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}
#endif

/// A Home member's avatar that joins or leaves the room. The active profile
/// is always watching and cannot be turned off.
private struct PickSomethingMemberButton: View {
    let member: PlexHomeUser
    let isWatching: Bool
    let isLoading: Bool
    let isFixed: Bool
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    private let avatarSize: CGFloat = 64
    #else
    private let avatarSize: CGFloat = 44
    #endif

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    PlexHomeUserAvatar(user: member, size: avatarSize)
                        .opacity(isWatching ? 1 : 0.4)

                    badge
                }

                Text(member.displayName)
                    .font(IthacaFont.caption(ios: .caption))
                    .foregroundStyle(isWatching ? Color.ithacaTextPrimary : Color.ithacaTextSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: avatarSize + 24)
            }
        }
        .disabled(isFixed)
        .ithacaSuppressTVOSButtonChrome()
        #if os(tvOS)
        .focused($isFocused)
        .ithacaTVOSFocusedScale(isFocused)
        #endif
        .accessibilityLabel(member.displayName)
        .accessibilityValue(isWatching ? "Watching" : "Not watching")
        .accessibilityAddTraits(isWatching ? .isSelected : [])
    }

    @ViewBuilder
    private var badge: some View {
        if isLoading {
            ProgressView()
                .controlSize(.mini)
                .padding(4)
                .background(Color.ithacaSurface, in: Circle())
        } else if isWatching {
            Image(systemName: "checkmark.circle.fill")
                .font(IthacaFont.glyphSmall(ios: .footnote))
                .foregroundStyle(Color.ithacaTextPrimary)
                .background(Color.ithacaBackground, in: Circle())
        } else if member.isProtected {
            Image(systemName: "lock.fill")
                .font(IthacaFont.badge(ios: .caption2.weight(.bold)))
                .foregroundStyle(Color.ithacaTextPrimary)
                .padding(5)
                .background(Color.ithacaSurface, in: Circle())
        }
    }
}

/// The PIN for a protected member joining the room. Like the profile picker,
/// the PIN lives only in this view's state and the one request that checks it.
private struct PickSomethingPINEntry: View {
    let member: PlexHomeUser
    let viewModel: PickSomethingViewModel
    @State private var pin = ""

    var body: some View {
        #if os(tvOS)
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()
            TVHomeUserPINView(
                user: member,
                pin: $pin,
                isSubmitting: viewModel.loadingMemberID == member.id,
                error: viewModel.pinError,
                onSubmit: submit
            )
        }
        .onExitCommand { viewModel.cancelPIN() }
        #else
        NavigationStack {
            IOSHomeUserPINView(
                user: member,
                pin: $pin,
                isSubmitting: viewModel.loadingMemberID == member.id,
                error: viewModel.pinError,
                onSubmit: submit
            )
            .background(Color.ithacaBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancelPIN() }
                }
            }
        }
        #endif
    }

    private func submit() {
        let entered = pin
        guard entered.count == 4 else { return }
        Task {
            await viewModel.submitPIN(entered)
            pin = ""
        }
    }
}
