import Foundation

@MainActor
@Observable
final class PickSomethingViewModel {
    static let pickCount = 3
    /// Picks asked for at once: three screens of Pick Again.
    static let athenaPickCount = 9
    /// Athena's own limit.
    static let maximumRequestLength = 500

    private let plexService: PlexService
    private let engine: PickSomethingEngine
    private let preferences: UserPreferences
    private let tasteRecommender: TasteRecommender
    private let seerrService: SeerrService
    private let store: IthacaStore
    private let picker = DescribeItPicker()

    private(set) var criteria: PickSomethingCriteria
    private(set) var availableKinds: [PickSomethingKind] = []
    /// Genre titles across the current kind's libraries, sorted.
    private(set) var genreTitles: [String] = []
    private(set) var picks: [PlexItem] = []
    private(set) var isPicking = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    /// The criteria matched nothing for the people watching.
    private(set) var hasNoMatches = false
    /// "Pick Again" went through everything that fits and started over.
    private(set) var didWrapAround = false
    /// "Pick Again" found nothing that is not already on screen.
    private(set) var didRunOut = false
    /// A failed action (Mark Watched). Shown as an alert.
    var actionError: String?
    /// What the viewer described (Describe It). nil picks at random.
    private(set) var request: String?
    /// Why each title was picked for `request`, when there is more to say
    /// than the card shows.
    private(set) var reasons: [TasteTitleKey: String] = [:]
    /// Suggestions for `request` that Seerr can request, asked for beside the
    /// picks so the picks don't wait for them.
    private var isSearchingRequestables = false
    private var requestFailure: String?
    private var foundRequestables: [PickSomethingRequestable] = []

    // MARK: Who's watching

    /// The other Plex Home members, who can join the room.
    var otherMembers: [PlexHomeUser] {
        guard plexService.hasPlexHome else { return [] }
        let activeID = plexService.activeHomeUser?.id
        return plexService.homeUsers.filter { $0.id != activeID }
    }
    var activeMember: PlexHomeUser? { plexService.activeHomeUser }
    private(set) var watchingMemberIDs: Set<Int> = []
    private(set) var loadingMemberID: Int?
    /// The protected member whose PIN is being asked for.
    var pinMember: PlexHomeUser?
    private(set) var pinError: String?
    private(set) var memberError: String?

    @ObservationIgnored private var libraries: [PlexLibrary] = []
    @ObservationIgnored private var genresByLibrary: [String: [LibraryGenreOption]] = [:]
    @ObservationIgnored private var viewerAccess: [Int: PlexHomeViewerAccess] = [:]
    /// Vetted for the active profile, not yet shown.
    @ObservationIgnored private var queue: [PlexItem] = []
    /// Everything queued or shown since the criteria last changed.
    @ObservationIgnored private var seen = RecommendationSeenTitles()
    /// Other servers' copies of queued titles, for the room check.
    @ObservationIgnored private var copies: [PlexContentKey: [PlexItem]] = [:]
    @ObservationIgnored private var pickTask: Task<Void, Never>?
    @ObservationIgnored private var replaceTask: Task<Void, Never>?
    @ObservationIgnored private var genreTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadGeneration = 0
    /// The screen closed mid-pick: the next load picks again.
    @ObservationIgnored private var resumesPicking = false
    /// Everything Describe It picked since the criteria or request last
    /// changed, in its order. Pick Again starts over on these instead of
    /// asking again.
    @ObservationIgnored private var athenaPicked: [PlexItem] = []
    /// Every copy in the chosen genre, by genre title. See `genreMemberIDs`.
    @ObservationIgnored private var genreMembers: (genre: String, ids: Set<PlexItemID>)?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var requestGeneration = 0
    /// What the row holds or is finding titles for; nil after a failure, so
    /// the same query asks again.
    @ObservationIgnored private var requestablesQuery: RequestablesQuery?
    /// `SeerrService.requestRevision` when the row was found.
    @ObservationIgnored private var requestablesRevision = 0
    /// The screen closed while suggestions were being found: the next load
    /// finds them again, leaving the picks alone.
    @ObservationIgnored private var resumesRequestables = false
    /// Seerr's recent list per kind, kept for the screen's life: the same list
    /// keeps Athena's cached prompt.
    @ObservationIgnored private var requestFeeds: [SeerrMediaType: PickSomethingRequestFeed] = [:]
    /// A request held back until the viewer answers whether Athena may have
    /// it (`AthenaConsent`).
    private(set) var requestAwaitingConsent: String?

    init(
        initialKind: PickSomethingKind,
        plexService: PlexService,
        preferences: UserPreferences,
        tasteRecommender: TasteRecommender,
        seerrService: SeerrService,
        store: IthacaStore
    ) {
        self.plexService = plexService
        self.engine = PickSomethingEngine(plexService: plexService)
        self.preferences = preferences
        self.tasteRecommender = tasteRecommender
        self.seerrService = seerrService
        self.store = store
        self.criteria = PickSomethingCriteria(kind: initialKind)
    }

    /// Describe It is Ithaca Pro's: during the trial, or bought.
    var canDescribe: Bool {
        store.hasPro
    }

    /// The Athena set in Settings, found or shared, when it can be used from
    /// here: an http:// one only on its home network.
    private var athenaClient: AthenaClient? {
        guard let client = AthenaClient(address: preferences.athenaAddress),
              !client.isPlainHTTP || plexService.pool.isOnHomeNetwork else { return nil }
        return client
    }

    /// Athena when one is usable and the viewer agreed, otherwise the device.
    private var describeEngine: DescribeItEngine {
        guard preferences.athenaConsent == .allowed, let client = athenaClient else { return .onDevice }
        return .athena(client, credentials: athenaCredentials)
    }

    /// The active profile's server tokens, of which Athena gets the one for its
    /// own server (`AthenaCredentials`).
    private var athenaCredentials: AthenaCredentials {
        let pool = plexService.pool
        var credentials = AthenaCredentials()
        for serverID in pool.knownServerIDs {
            guard let token = pool.connection(for: serverID)?.token ?? ServerPool.storedToken(serverID: serverID) else {
                continue
            }
            credentials.serverTokens[serverID] = token
            guard let server = pool.server(for: serverID), server.owned else { continue }
            let hosts = server.connections.flatMap { connection in
                [connection.address.lowercased(), URL(string: connection.uri)?.host(percentEncoded: false)?.lowercased()]
                    .compactMap { $0?.nilIfEmpty }
            }
            credentials.ownedServers[serverID] = AthenaCredentials.OwnedServer(
                hosts: Set(hosts),
                isOnItsNetwork: pool.homeNetworkServerIDs.contains(serverID)
            )
        }
        return credentials
    }

    /// The Athena a request would go to, while the viewer hasn't said whether
    /// it may.
    var athenaAwaitingConsent: String? {
        guard requestAwaitingConsent != nil, let url = athenaClient?.baseURL,
              let host = url.host(percentEncoded: false) else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    var requestables: [PickSomethingRequestable] {
        activeRequest == nil ? [] : foundRequestables
    }

    var isFindingRequestables: Bool {
        activeRequest != nil && isSearchingRequestables
    }

    var requestError: String? {
        activeRequest == nil ? nil : requestFailure
    }

    func reason(for item: PlexItem) -> String? {
        guard activeRequest != nil, let key = TasteTitleKey(item: item) else { return nil }
        return reasons[key]
    }

    /// The request picks follow: none without Ithaca Pro.
    private var activeRequest: String? {
        canDescribe ? request : nil
    }

    var runtimeOptions: [PickSomethingRuntime] {
        PickSomethingRuntime.options(for: criteria.kind)
    }

    /// Runs again whenever the connected servers change: Siri can open the
    /// screen before any server is up, and a server can connect after the first
    /// load. Once loaded, a changed set of libraries is picked up without
    /// touching the picks on screen. A newer or cancelled load wins: this one
    /// then changes nothing.
    func load() async {
        let isRefresh = hasLoaded && !availableKinds.isEmpty
        loadGeneration += 1
        let loadToken = loadGeneration
        if !isRefresh {
            isPicking = true
            error = nil
            hasNoMatches = false
        }

        let loadedLibraries: [PlexLibrary]
        do {
            loadedLibraries = try await engine.libraries()
        } catch {
            guard loadToken == loadGeneration, !Task.isCancelled, !isRefresh else { return }
            self.error = error.localizedDescription
            isPicking = false
            return
        }
        guard loadToken == loadGeneration, !Task.isCancelled else { return }

        let kinds = PickSomethingKind.allCases.filter { kind in
            loadedLibraries.contains { $0.libraryType == kind.libraryType }
        }
        guard !kinds.isEmpty else {
            // With servers still connecting, keep waiting: the view runs this
            // again when they finish.
            if !isRefresh, !plexService.pool.isConnecting {
                isPicking = false
                if plexService.pool.connections.isEmpty {
                    // No server answered: not the same as having no library.
                    error = "Couldn't reach your Plex servers."
                } else {
                    availableKinds = []
                    hasLoaded = true
                    hasNoMatches = true
                }
            }
            return
        }

        if isRefresh, Set(loadedLibraries.map(\.id)) == Set(libraries.map(\.id)) {
            if resumesPicking {
                restart()
            } else if resumesRequestables {
                findRequestables()
            } else {
                recheckRequestables()
            }
            return
        }

        libraries = loadedLibraries
        genreMembers = nil
        let loadedIDs = Set(loadedLibraries.map(\.id))
        genresByLibrary = genresByLibrary.filter { loadedIDs.contains($0.key) }
        availableKinds = kinds
        var kindChanged = false
        if !kinds.contains(criteria.kind), let first = kinds.first {
            criteria.kind = first
            criteria.runtime = .any
            criteria.genreTitle = nil
            kindChanged = true
        }
        hasLoaded = true
        updateGenreTitles()
        loadGenres()
        if !isRefresh || kindChanged || resumesPicking {
            restart()
        } else if resumesRequestables {
            findRequestables()
        } else {
            recheckRequestables()
        }
    }

    /// Genres are only needed for the Genre chip, so the first pick does not
    /// wait for them.
    private func loadGenres() {
        let missing = libraries.filter { genresByLibrary[$0.id] == nil }
        genreTask?.cancel()
        guard !missing.isEmpty else { return }
        let engine = engine
        genreTask = Task { [weak self] in
            let genres = await engine.genres(for: missing)
            guard let self, !Task.isCancelled else { return }
            genresByLibrary.merge(genres) { _, new in new }
            updateGenreTitles()
        }
    }

    /// The screen closed: stop picking and drop in-flight work.
    func stop() {
        resumesPicking = resumesPicking || isPicking
        if isSearchingRequestables {
            resumesRequestables = true
            requestablesQuery = nil
        }
        pickTask?.cancel()
        replaceTask?.cancel()
        genreTask?.cancel()
        requestTask?.cancel()
        generation += 1
        requestGeneration += 1
        isPicking = false
        isSearchingRequestables = false
    }

    func retry() {
        if hasLoaded {
            restart()
        } else {
            Task { await load() }
        }
    }

    // MARK: Filters

    func setKind(_ kind: PickSomethingKind) {
        guard kind != criteria.kind else { return }
        criteria.kind = kind
        criteria.runtime = .any
        criteria.genreTitle = nil
        updateGenreTitles()
        restart()
    }

    func setRuntime(_ runtime: PickSomethingRuntime) {
        guard runtime != criteria.runtime else { return }
        criteria.runtime = runtime
        restart()
    }

    func setGenre(_ title: String?) {
        guard title != criteria.genreTitle else { return }
        criteria.genreTitle = title
        restart()
    }

    func setUnwatchedOnly(_ unwatchedOnly: Bool) {
        guard unwatchedOnly != criteria.unwatchedOnly else { return }
        criteria.unwatchedOnly = unwatchedOnly
        restart()
    }

    // MARK: Describe It

    /// Picks for the text from now on, or at random again for an empty text.
    /// The same text again only retries after an error. With an Athena the
    /// viewer hasn't said yes or no to, the request waits for the answer.
    func describe(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            .map { String($0.prefix(Self.maximumRequestLength)) }
        if let request, preferences.athenaConsent == .undecided, athenaClient != nil {
            requestAwaitingConsent = request
            return
        }
        guard request != self.request || error != nil || requestError != nil else { return }
        if request == self.request, error == nil {
            // Only To Request failed: ask again, leaving the picks alone.
            findRequestables()
            return
        }
        self.request = request
        reasons = [:]
        restart()
    }

    /// The viewer's answer to whether Describe It may use Athena; the held
    /// request goes ahead either way.
    func answerAthenaConsent(_ allowed: Bool, for request: String) {
        preferences.athenaConsent = allowed ? .allowed : .declined
        requestAwaitingConsent = nil
        describe(request)
    }

    /// The question went away unanswered: the request is dropped, and asked
    /// about again next time.
    func cancelAthenaConsent() {
        requestAwaitingConsent = nil
    }

    // MARK: Picks

    /// Ignored while a pick is under way. The button stays enabled, so tvOS
    /// focus stays on it between rerolls.
    func pickAgain() {
        guard hasLoaded, !isPicking else { return }
        startPicking(reset: false)
    }

    /// "We've seen it": marks it watched everywhere and swaps in another pick.
    func markWatched(_ item: PlexItem) async {
        do {
            try await plexService.setWatchedAcrossServers(true, id: item.id)
        } catch {
            actionError = error.localizedDescription
            return
        }
        // A pick already under way replaces every card anyway.
        guard !isPicking, picks.contains(where: { $0.id == item.id }) else { return }
        // One replacement at a time: they share the queue.
        let previous = replaceTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.replace(item)
        }
        replaceTask = task
        await task.value
    }

    private func replace(_ item: PlexItem) async {
        guard !isPicking, !Task.isCancelled, picks.contains(where: { $0.id == item.id }) else { return }
        let token = generation
        do {
            var replacement: PlexItem?
            for _ in 0..<3 {
                guard let candidate = try await nextPicks(count: 1, token: token).first else { break }
                // Never a second card for the same title.
                if !picks.contains(where: { $0.id == candidate.id || $0.contentKey == candidate.contentKey }) {
                    replacement = candidate
                    break
                }
            }
            guard token == generation, let index = picks.firstIndex(where: { $0.id == item.id }) else { return }
            if let replacement {
                picks[index] = replacement
            } else {
                picks.remove(at: index)
                hasNoMatches = picks.isEmpty
            }
        } catch {
            // Superseded by a new pick, or the card stays and says why.
            guard token == generation, !(error is CancellationError) else { return }
            actionError = error.localizedDescription
        }
    }

    // MARK: Who's watching

    func isWatching(_ member: PlexHomeUser) -> Bool {
        watchingMemberIDs.contains(member.id)
    }

    func toggle(_ member: PlexHomeUser) {
        guard loadingMemberID == nil else { return }
        memberError = nil
        if watchingMemberIDs.remove(member.id) != nil {
            restart()
            return
        }
        if viewerAccess[member.id] != nil {
            watchingMemberIDs.insert(member.id)
            restart()
            return
        }
        if member.isProtected {
            pinError = nil
            pinMember = member
            return
        }
        Task { await join(member, pin: nil) }
    }

    func submitPIN(_ pin: String) async {
        guard let member = pinMember else { return }
        await join(member, pin: pin)
    }

    /// A PIN check still in flight finishes: a right PIN still adds the member.
    func cancelPIN() {
        pinMember = nil
        pinError = nil
    }

    private func join(_ member: PlexHomeUser, pin: String?) async {
        loadingMemberID = member.id
        pinError = nil
        defer { loadingMemberID = nil }
        do {
            viewerAccess[member.id] = try await plexService.homeViewerAccess(for: member, pin: pin)
        } catch {
            if pin != nil {
                // Only while the PIN screen is still up.
                if pinMember?.id == member.id {
                    pinError = error.localizedDescription
                }
            } else {
                memberError = "Couldn't check what \(member.displayName) has watched. \(error.localizedDescription)"
            }
            return
        }
        pinMember = nil
        watchingMemberIDs.insert(member.id)
        restart()
    }

    // MARK: Picking

    private func updateGenreTitles() {
        var titlesByKey: [String: String] = [:]
        for library in libraries where library.libraryType == criteria.kind.libraryType {
            for genre in genresByLibrary[library.id] ?? [] {
                let key = LibraryGenreSupport.normalizeGenreTitle(genre.title)
                if !key.isEmpty, titlesByKey[key] == nil {
                    titlesByKey[key] = genre.title
                }
            }
        }
        genreTitles = titlesByKey.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// New criteria or a different room: start from a fresh sample.
    private func restart() {
        startPicking(reset: true)
    }

    private func startPicking(reset: Bool) {
        pickTask?.cancel()
        replaceTask?.cancel()
        generation += 1
        let token = generation
        resumesPicking = false
        if reset {
            queue = []
            copies = [:]
            seen = RecommendationSeenTitles()
            athenaPicked = []
            findRequestables()
        }
        isPicking = true
        error = nil
        hasNoMatches = false
        didWrapAround = false
        didRunOut = false

        pickTask = Task { [weak self] in
            guard let self else { return }
            do {
                var next = try await nextPicks(count: Self.pickCount, token: token)
                // Pick Again ran short: start over for the rest, leaving out
                // what is on screen and what was just found.
                if !reset, next.count < Self.pickCount {
                    queue = []
                    seen = RecommendationSeenTitles()
                    seen.formUnion(picks)
                    seen.formUnion(next)
                    let more: [PlexItem]
                    if activeRequest != nil {
                        // The earlier picks again, rather than the same
                        // question again. Their copies stay for the room check.
                        queue = athenaPicked.filter { !seen.contains($0) }
                        seen.formUnion(queue)
                        more = try await nextPicks(count: Self.pickCount - next.count, token: token, maximumRefills: 0)
                    } else {
                        copies = [:]
                        more = try await nextPicks(count: Self.pickCount - next.count, token: token)
                    }
                    didWrapAround = !more.isEmpty
                    didRunOut = more.isEmpty
                    next += more
                }
                if !next.isEmpty || reset {
                    picks = next
                }
                hasNoMatches = picks.isEmpty
            } catch {
                guard token == generation, !(error is CancellationError) else { return }
                self.error = error.localizedDescription
            }
            isPicking = false
        }
    }

    /// Takes up to `count` picks off the queue, refilling it from the
    /// libraries and running each candidate past the room. Throws
    /// `CancellationError` as soon as a newer pick (`token`) has started, before
    /// touching the queue, so a stale call never mixes old filters into it.
    private func nextPicks(count: Int, token: Int, maximumRefills: Int? = nil) async throws -> [PlexItem] {
        let viewers = watchingMemberIDs.compactMap { viewerAccess[$0] }
        let criteria = criteria
        let request = activeRequest
        var result: [PlexItem] = []
        var refills = 0

        func ensureCurrent() throws {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
        }

        while result.count < count {
            try ensureCurrent()
            if queue.isEmpty {
                // Each Describe It refill is an Athena (Claude) request or a
                // ranking of the library: two at most.
                guard refills < (maximumRefills ?? (request == nil ? 6 : 2)) else { break }
                refills += 1
                let batch = if let request {
                    try await athenaCandidates(request: request, criteria: criteria, token: token)
                } else {
                    try await engine.candidates(
                        criteria: criteria,
                        libraries: libraries,
                        genres: genresByLibrary,
                        excluding: seen
                    )
                }
                try ensureCurrent()
                if batch.items.isEmpty {
                    // Read whole, nothing is left. Sampled, another random
                    // window may still find something.
                    if batch.isExhaustive { break }
                    continue
                }
                seen.formUnion(batch.items)
                copies.merge(batch.copies) { _, new in new }
                queue = batch.items
            }

            let needed = count - result.count
            // With others watching, check a few extra at once: some will drop out.
            let slice = Array(queue.prefix(viewers.isEmpty ? needed : max(needed * 4, 40)))
            queue.removeFirst(slice.count)
            let allowed = try await engine.roomCheck(
                slice, viewers: viewers, copies: copies, criteria: criteria
            )
            try ensureCurrent()
            result += allowed.prefix(needed)
            queue.insert(contentsOf: allowed.dropFirst(needed), at: 0)
        }
        return result
    }

    /// Describe It's picks for `request` among the titles that fit the
    /// filters, leaving out what is already queued or shown. Best fit first,
    /// not shuffled.
    private func athenaCandidates(
        request: String,
        criteria: PickSomethingCriteria,
        token: Int
    ) async throws -> PickSomethingBatch {
        guard let catalog = await tasteRecommender.catalog(), !catalog.library.copies.isEmpty else {
            throw AthenaError.noLibrary
        }
        guard token == generation else { throw CancellationError() }
        let genreIDs = try await genreMemberIDs(criteria: criteria)
        guard token == generation else { throw CancellationError() }
        let options = PickSomethingAthenaOptions(library: catalog.library, criteria: criteria, genreMemberIDs: genreIDs)
        guard !options.titles.isEmpty else { return PickSomethingBatch(items: [], isExhaustive: true) }

        let seen = seen
        let answer = try await picker.answer(
            AthenaPickRequest(
                request: request,
                kind: criteria.kind.rawValue,
                count: Self.athenaPickCount,
                titles: options.titles,
                taste: AthenaPickRequest.Taste(catalog: catalog),
                exclude: options.ids { seen.contains($0) }
            ),
            engine: describeEngine,
            kind: criteria.kind,
            options: options,
            catalog: catalog
        )
        guard token == generation else { throw CancellationError() }

        var items: [PlexItem] = []
        var copies: [PlexContentKey: [PlexItem]] = [:]
        var alternates: [PlexItem] = []
        for pick in answer.picks {
            guard let entry = options.entry(for: pick.id), !seen.contains(entry.item) else { continue }
            // Claude sometimes fills the count with a title listed below the
            // minimum it read.
            guard ReviewScores(item: entry.item).meets(answer.minimums) else { continue }
            items.append(entry.item)
            // Jev's picks come without one.
            reasons[entry.key] = pick.reason.nilIfEmpty
            alternates += entry.copies
            if entry.copies.count > 1, entry.item.contentKey.isStrong {
                copies[entry.item.contentKey] = entry.copies
            }
        }
        // Seen It and playback fallback reach every server's copy.
        plexService.registerAlternates(PlexItemMerge.alternates(in: [alternates]))
        athenaPicked += items
        return PickSomethingBatch(items: items, isExhaustive: true, copies: copies)
    }

    // MARK: To Request

    /// What a To Request search depends on. Who's watching and Unwatched
    /// don't change it.
    private struct RequestablesQuery: Equatable {
        let request: String
        let kind: PickSomethingKind
        let maxMinutes: Int?
        let genre: String?
    }

    /// Finds titles to request for the current request and filters, unless
    /// the row already holds or is finding them. Clears them without a
    /// request, Seerr, or permission to request this kind.
    private func findRequestables() {
        let criteria = criteria
        let query = activeRequest.map {
            RequestablesQuery(
                request: $0,
                kind: criteria.kind,
                maxMinutes: criteria.runtime.maxMinutes,
                genre: criteria.genreTitle
            )
        }
        if let query, query == requestablesQuery { return }

        requestTask?.cancel()
        requestGeneration += 1
        let token = requestGeneration
        resumesRequestables = false
        requestablesQuery = nil
        foundRequestables = []
        requestFailure = nil
        let type = criteria.kind.seerrType
        let engine = describeEngine
        guard let query,
              seerrService.isAvailableForCurrentContext,
              seerrService.currentUser?.canRequest(type) ?? true else {
            isSearchingRequestables = false
            return
        }
        requestablesQuery = query
        isSearchingRequestables = true
        let revision = seerrService.requestRevision
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await requestables(request: query.request, criteria: criteria, engine: engine)
                guard token == requestGeneration else { return }
                foundRequestables = found
                requestablesRevision = revision
            } catch {
                guard token == requestGeneration, !(error is CancellationError) else { return }
                requestFailure = "Couldn't find titles to request. \(error.localizedDescription)"
                requestablesQuery = nil
            }
            isSearchingRequestables = false
        }
    }

    /// Back on the screen after a request was sent (from a card's page, say):
    /// drops the cards that are requested now, leaving the rest in place.
    private func recheckRequestables() {
        guard activeRequest != nil,
              !foundRequestables.isEmpty,
              !isSearchingRequestables,
              requestablesRevision != seerrService.requestRevision else { return }
        let token = requestGeneration
        let revision = seerrService.requestRevision
        let current = foundRequestables
        let finder = PickSomethingRequestFinder(seerrService: seerrService)
        requestTask = Task { [weak self] in
            let kept = await finder.stillRequestable(current)
            guard let self, token == requestGeneration, !Task.isCancelled else { return }
            foundRequestables = kept
            requestablesRevision = revision
        }
    }

    /// Suggestions for `request`, found on Seerr. Athena gets the library
    /// too, so it knows what the household has and likes; on the device, they
    /// come from Seerr's recent list.
    private func requestables(
        request: String,
        criteria: PickSomethingCriteria,
        engine: DescribeItEngine
    ) async throws -> [PickSomethingRequestable] {
        guard let catalog = await tasteRecommender.catalog(), !catalog.library.copies.isEmpty else {
            throw AthenaError.noLibrary
        }
        try Task.checkCancellation()
        let type = criteria.kind.seerrType
        let finder = PickSomethingRequestFinder(seerrService: seerrService)
        async let pendingFeed = requestFeed(type: type, finder: finder, library: catalog.library)
        let genreIDs = try await genreMemberIDs(criteria: criteria)
        let feed = await pendingFeed
        try Task.checkCancellation()

        // Everything the household has, watched or not, so Claude suggests
        // none of it.
        var shape = criteria
        shape.unwatchedOnly = false
        let options = PickSomethingAthenaOptions(library: catalog.library, criteria: shape, genreMemberIDs: genreIDs)
        let answer = try await picker.answer(
            AthenaPickRequest(
                request: request,
                kind: criteria.kind.rawValue,
                count: 0,
                titles: options.titles,
                taste: AthenaPickRequest.Taste(catalog: catalog),
                exclude: [],
                suggest: PickSomethingRequestFinder.askedCount,
                discover: feed.entries.isEmpty ? nil : feed.entries,
                maxMinutes: criteria.runtime.maxMinutes,
                genre: criteria.genreTitle
            ),
            engine: engine,
            kind: criteria.kind,
            options: options,
            catalog: catalog,
            feed: feed
        )
        try Task.checkCancellation()
        return await finder.resolve(
            answer.suggestions,
            feed: feed,
            type: type,
            library: catalog.library,
            minimums: answer.minimums
        )
    }

    private func requestFeed(
        type: SeerrMediaType,
        finder: PickSomethingRequestFinder,
        library: TasteLibrary
    ) async -> PickSomethingRequestFeed {
        // A request sent since makes the list's request states stale.
        if let feed = requestFeeds[type], feed.requestRevision == seerrService.requestRevision {
            return feed
        }
        let feed = await finder.feed(type: type, library: library)
        // A partial list would be sent, byte for byte, for the screen's life.
        if feed.isComplete { requestFeeds[type] = feed }
        return feed
    }

    /// Kept for the screen's life per genre: a chip change back is free.
    private func genreMemberIDs(criteria: PickSomethingCriteria) async throws -> Set<PlexItemID>? {
        guard let genre = criteria.genreTitle else { return nil }
        if let genreMembers, genreMembers.genre == genre { return genreMembers.ids }
        guard let ids = try await engine.genreMemberIDs(
            criteria: criteria,
            libraries: libraries,
            genres: genresByLibrary
        ) else { return nil }
        genreMembers = (genre, ids)
        return ids
    }
}
