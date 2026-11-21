import Foundation
import Observation

/// Where one of the user's requests stands.
enum SeerrRequestPhase: Hashable, Sendable {
    case ready
    case downloading(SeerrDownloadProgress)
    case partiallyAvailable
    case pendingApproval
    case requested
    case failed
    case declined

    /// Nil for a request whose title has since been removed from the library.
    static func resolve(_ request: SeerrListedRequest) -> SeerrRequestPhase? {
        if request.media.status == .deleted { return nil }
        switch request.status {
        case .declined: return .declined
        // A TV request completes when its own seasons are in, even while the
        // show as a whole is only partially available.
        case .completed: return .ready
        default: break
        }
        if request.media.status == .available { return .ready }
        if let progress = SeerrDownloadProgress(request.media.downloadStatus ?? []) {
            return .downloading(progress)
        }
        // The media's own "partially available" describes the whole show, so
        // a request for a new season of a show already in Plex would read as
        // partly here. Only this request's seasons count.
        let seasonStatuses = (request.seasons ?? []).map(\.status)
        if seasonStatuses.contains(.completed), seasonStatuses.contains(where: { $0 != .completed }) {
            return .partiallyAvailable
        }
        switch request.status {
        case .pending: return .pendingApproval
        case .failed: return .failed
        default: return .requested
        }
    }

    /// Row order: what is here first, then what is closest to arriving.
    var rank: Int {
        switch self {
        case .ready: 0
        case .downloading: 1
        case .partiallyAvailable: 2
        case .pendingApproval: 3
        case .requested: 4
        case .failed: 5
        case .declined: 6
        }
    }

    var badgeTitle: String {
        switch self {
        case .ready: "Ready"
        case .downloading: "Downloading"
        case .partiallyAvailable: "Partial"
        case .pendingApproval: "Pending"
        case .requested: "Requested"
        case .failed: "Failed"
        case .declined: "Declined"
        }
    }
}

/// A title's Radarr/Sonarr queue entries summed up. For a show that is every
/// episode in the queue.
struct SeerrDownloadProgress: Hashable, Sendable {
    let fraction: Double
    /// The last entry's finish time, if any is still ahead.
    let estimatedCompletion: Date?

    init(fraction: Double, estimatedCompletion: Date?) {
        self.fraction = fraction
        self.estimatedCompletion = estimatedCompletion
    }

    init?(_ items: [SeerrDownloadItem], now: Date = .now) {
        guard !items.isEmpty else { return nil }
        var size = 0.0
        var left = 0.0
        for item in items {
            let itemSize = max(item.size ?? 0, 0)
            size += itemSize
            left += min(max(item.sizeLeft ?? 0, 0), itemSize)
        }
        fraction = size > 0 ? min(max(1 - left / size, 0), 1) : 0
        estimatedCompletion = items
            .compactMap { SeerrDate.parse($0.estimatedCompletionTime) }
            .filter { $0 > now }
            .max()
    }

    /// "43% · 12 min left", "43%" without an estimate.
    func label(now: Date = .now) -> String {
        let percent = "\(Int((fraction * 100 + 1e-9).rounded(.down)))%"
        guard let estimatedCompletion else { return percent }
        let milliseconds = Int(estimatedCompletion.timeIntervalSince(now) * 1000)
        guard let remaining = MediaTextFormatter.compactDuration(milliseconds: milliseconds) else {
            return percent
        }
        return "\(percent) · \(remaining) left"
    }
}

/// What the app remembers about one user's requests between launches, so an
/// arrival is announced exactly once. Stored in UserDefaults by
/// `SeerrRequestWatchStore`.
struct SeerrRequestWatchRecord: Codable, Equatable, Sendable {
    /// Requests seen on their way, by request id, with the title to announce
    /// them by (empty until it is known).
    var awaiting: [Int: String] = [:]
    /// When each awaited request was seen ready.
    var arrived: [Int: Date] = [:]
    /// The last refresh folded in.
    var checkedAt: Date?

    /// How long a ready request stays in the row unless Settings says
    /// otherwise (`UserPreferences.readyRequestShelfLife`).
    static let readyShelfLife: TimeInterval = ReadyRequestShelfLife.week.timeInterval
    /// Arrival dates are kept this long, the longest choice, so a longer
    /// setting picked later still finds them.
    static let longestShelfLife: TimeInterval = ReadyRequestShelfLife.allCases.map(\.timeInterval).max() ?? readyShelfLife
    /// After a gap this long nobody knows when a request arrived, so it is
    /// listed as ready but not announced: a "ready to watch" for something
    /// that came in last week is noise.
    static let announceWindow: TimeInterval = 2 * 24 * 60 * 60

    struct Arrival: Equatable, Sendable {
        let request: SeerrListedRequest
        let title: String
    }

    /// Folds in a fresh request list and returns the arrivals to announce. A
    /// request that is already ready the first time it is seen is not an
    /// arrival: otherwise the first refresh after connecting Seerr would
    /// announce every request ever filled. An awaited request no longer in
    /// the list is forgotten, since it can no longer be watched.
    mutating func update(
        with requests: [SeerrListedRequest],
        titles: [Int: String],
        now: Date
    ) -> [Arrival] {
        var arrivals: [Arrival] = []
        var stillAwaiting: [Int: String] = [:]
        for request in requests {
            guard let phase = SeerrRequestPhase.resolve(request) else { continue }
            let knownTitle = titles[request.id]?.nilIfEmpty ?? awaiting[request.id]?.nilIfEmpty
            switch phase {
            case .ready:
                if awaiting[request.id] != nil {
                    arrivals.append(Arrival(request: request, title: knownTitle ?? ""))
                    arrived[request.id] = now
                }
            case .declined:
                break
            default:
                stillAwaiting[request.id] = knownTitle ?? ""
            }
        }
        awaiting = stillAwaiting
        let listed = Set(requests.map(\.id))
        arrived = arrived.filter { id, date in
            listed.contains(id) && now.timeIntervalSince(date) < Self.longestShelfLife
        }
        let isCurrent = checkedAt.map { now.timeIntervalSince($0) < Self.announceWindow } ?? true
        checkedAt = now
        return isCurrent ? arrivals : []
    }

    /// Whether a finished request still belongs in the row: it arrived while
    /// the app was watching, or it was requested recently enough that the app
    /// may simply not have looked in between.
    func showsReady(
        _ request: SeerrListedRequest,
        now: Date,
        shelfLife: TimeInterval = readyShelfLife
    ) -> Bool {
        if let date = arrived[request.id], now.timeIntervalSince(date) < shelfLife {
            return true
        }
        return Self.isRecent(request, now: now, shelfLife: shelfLife)
    }

    static func isRecent(
        _ request: SeerrListedRequest,
        now: Date,
        shelfLife: TimeInterval = readyShelfLife
    ) -> Bool {
        guard let created = request.createdDate else { return false }
        return now.timeIntervalSince(created) < shelfLife
    }
}

/// `SeerrRequestWatchRecord`s by `SeerrService.requestOwnerKey`.
enum SeerrRequestWatchStore {
    private static let defaultsKey = "SeerrRequestWatch"

    static func record(for owner: String) -> SeerrRequestWatchRecord {
        all()[owner] ?? SeerrRequestWatchRecord()
    }

    static func save(_ record: SeerrRequestWatchRecord, for owner: String) {
        var records = all()
        if record == SeerrRequestWatchRecord() {
            records.removeValue(forKey: owner)
        } else {
            records[owner] = record
        }
        guard !records.isEmpty, let data = try? JSONEncoder().encode(records) else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func hasAwaitedRequests(withPrefix prefix: String) -> Bool {
        all().contains { $0.key.hasPrefix(prefix) && !$0.value.awaiting.isEmpty }
    }

    /// Every user's record from one Seerr and Plex profile, on disconnect.
    static func removeRecords(withPrefix prefix: String) {
        let records = all().filter { !$0.key.hasPrefix(prefix) }
        guard !records.isEmpty, let data = try? JSONEncoder().encode(records) else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func all() -> [String: SeerrRequestWatchRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([String: SeerrRequestWatchRecord].self, from: data) else {
            return [:]
        }
        return records
    }
}

/// The signed-in user's Seerr requests for Home's Your Requests row: waiting,
/// downloading with Radarr/Sonarr's progress, then ready to play. Announces
/// arrivals with a local notification on iPhone and iPad.
///
/// Home polls it while it is on screen (`pollInterval`); iOS also refreshes
/// it from background app refresh while a request is on its way.
@MainActor
@Observable
final class SeerrRequestTracker {
    struct Item: Identifiable, Equatable {
        let requestID: Int
        let mediaType: SeerrMediaType
        let tmdbID: Int
        let title: String
        /// The requested seasons for a show, the year for a movie.
        let detail: String?
        let posterPath: String?
        let phase: SeerrRequestPhase
        let route: AppNavigationRoute

        var id: Int { requestID }
    }

    private(set) var items: [Item] = []
    /// Whether `items` has anything, for views that only need that: tvOS Home
    /// reads it to pick its landing shelf, and would otherwise re-render on
    /// every progress update.
    private(set) var hasItems = false

    @ObservationIgnored private let seerrService: SeerrService
    @ObservationIgnored private let plexService: PlexService
    @ObservationIgnored private let preferences: UserPreferences
    /// Title, artwork and year by `"movie:<tmdb id>"`/`"tv:<tmdb id>"`. The
    /// request list has none of them; memory only.
    @ObservationIgnored private var titles: [String: TitleInfo] = [:]
    @ObservationIgnored private var lastRefresh: Date?
    /// Bumped by every refresh and context change. A refresh that finds it
    /// moved on after an await drops its result: a newer one has the say.
    @ObservationIgnored private var refreshGeneration = 0
    /// Bumped on a context change, so Home's polling task starts over.
    private var contextRevision = 0
    /// `IthacaApp.seerrContextID` as last seen.
    @ObservationIgnored private var contextKey: String?

    /// How many of the user's newest requests are looked at. An awaited
    /// request older than these can no longer be watched.
    private static let pageSize = 50
    private static let rowLimit = 20
    /// Home reappears often (Back from every page); this keeps that from
    /// asking Seerr again each time.
    private static let minimumRefreshInterval: TimeInterval = 20
    /// After a failed refresh, instead of `pollInterval`.
    private static let retryInterval = Duration.seconds(60)

    private struct TitleInfo {
        let title: String
        let posterPath: String?
        let year: Int?
    }

    init(seerrService: SeerrService, plexService: PlexService, preferences: UserPreferences) {
        self.seerrService = seerrService
        self.plexService = plexService
        self.preferences = preferences
        seerrService.requestCreated = { [weak self] request in
            self?.noteRequestCreated(request)
        }
    }

    /// Changes when the Seerr connection or the Plex profile does, for Home's
    /// polling task.
    var contextID: String {
        [
            seerrService.configuredBaseURL?.absoluteString ?? "none",
            plexService.activeProfileID ?? "none",
            String(seerrService.isAvailableForCurrentContext),
            String(contextRevision),
        ].joined(separator: "|")
    }

    /// Seerr's download sync runs every minute, so polling faster than that
    /// shows nothing new.
    var pollInterval: Duration {
        if items.contains(where: { if case .downloading = $0.phase { true } else { false } }) {
            return .seconds(60)
        }
        if items.contains(where: { $0.phase != .ready && $0.phase != .declined }) {
            return .seconds(5 * 60)
        }
        return .seconds(15 * 60)
    }

    /// Refreshes, then again every `pollInterval`, until cancelled.
    func poll() async {
        while !Task.isCancelled {
            let succeeded = await refresh()
            try? await Task.sleep(for: succeeded ? pollInterval : Self.retryInterval)
        }
    }

    /// Before `SeerrService.contextDidChange()`, so a new profile's Home never
    /// shows the previous profile's requests. Home's polling task restarts on
    /// the new `contextID`.
    func contextDidChange(_ key: String) {
        if !plexService.isAuthenticated {
            SeerrRequestWatchStore.removeAll()
        }
        defer { self.contextKey = key }
        // The first call is the launch: nothing is listed yet, and a
        // background refresh already running belongs to this context.
        guard let contextKey, contextKey != key else { return }
        refreshGeneration += 1
        contextRevision += 1
        setItems([])
        lastRefresh = nil
    }

    /// False when Seerr could not be reached, so polling retries sooner.
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        guard seerrService.isAvailableForCurrentContext else {
            setItems([])
            return true
        }
        if !force, let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < Self.minimumRefreshInterval {
            return true
        }
        refreshGeneration += 1
        let generation = refreshGeneration

        let userID: Int
        let requests: [SeerrListedRequest]
        do {
            (userID, requests) = try await seerrService.myRequests(take: Self.pageSize)
        } catch {
            // Silent, like Search: the row keeps what it had.
            return false
        }
        // The owner comes from the user the list was fetched for, not whoever
        // is signed in by the time it arrives.
        guard generation == refreshGeneration,
              let owner = seerrService.requestOwnerKey(userID: userID) else { return true }

        let now = Date.now
        let shelfLife = preferences.readyRequestShelfLife.timeInterval
        let seen = SeerrRequestWatchStore.record(for: owner)
        let candidates = requests.filter { request in
            guard let phase = SeerrRequestPhase.resolve(request) else { return false }
            switch phase {
            case .ready:
                return seen.awaiting[request.id] != nil || seen.showsReady(request, now: now, shelfLife: shelfLife)
            case .declined:
                return SeerrRequestWatchRecord.isRecent(request, now: now, shelfLife: shelfLife)
            default:
                return true
            }
        }
        await loadTitles(for: candidates)
        // Home went away mid-load: its title fetches were cancelled, and a
        // row built now would be missing them. The next refresh does it.
        guard !Task.isCancelled else { return false }
        // A profile switch while titles loaded, or a newer refresh.
        guard generation == refreshGeneration,
              seerrService.requestOwnerKey(userID: userID) == owner else { return true }

        let requestTitles = requests.reduce(into: [Int: String]()) { result, request in
            if let info = titleInfo(for: request) { result[request.id] = info.title }
        }
        // Read again: a request sent from the app meanwhile is in it now.
        var record = SeerrRequestWatchStore.record(for: owner)
        let arrivals = record.update(with: requests, titles: requestTitles, now: now)
        SeerrRequestWatchStore.save(record, for: owner)

        let previous = Dictionary(items.map { ($0.requestID, $0) }, uniquingKeysWith: { first, _ in first })
        let newItems = candidates
            .compactMap { request -> (SeerrListedRequest, SeerrRequestPhase)? in
                guard let phase = SeerrRequestPhase.resolve(request) else { return nil }
                if phase == .ready, !record.showsReady(request, now: now, shelfLife: shelfLife) { return nil }
                return (request, phase)
            }
            .sorted { lhs, rhs in
                lhs.1.rank != rhs.1.rank ? lhs.1.rank < rhs.1.rank : lhs.0.id > rhs.0.id
            }
            .prefix(Self.rowLimit)
            .compactMap { request, phase in item(for: request, phase: phase, previous: previous[request.id]) }
        setItems(newItems)
        lastRefresh = now
        // Awaited, so a background refresh is not suspended before they are
        // handed to the system.
        await announce(arrivals)
        return true
    }

    private func setItems(_ newItems: [Item]) {
        if newItems != items { items = newItems }
        if hasItems != !newItems.isEmpty { hasItems = !newItems.isEmpty }
    }

    #if os(iOS)
    /// The background app refresh task: one refresh, then the next one is
    /// asked for while anything is still on its way.
    func refreshInBackground() async {
        await refresh(force: true)
        scheduleBackgroundRefreshIfNeeded()
    }

    /// Only while this profile has a request on its way.
    func scheduleBackgroundRefreshIfNeeded() {
        // Background refreshes are only for arrival notifications.
        guard preferences.requestArrivalNotificationsEnabled,
              let prefix = seerrService.requestOwnerPrefix,
              SeerrRequestWatchStore.hasAwaitedRequests(withPrefix: prefix) else { return }
        SeerrRequestNotifications.scheduleRefresh()
    }
    #endif

    /// A request sent from the app is watched from the start, so its arrival
    /// is announced even if it lands before Home looks again.
    private func noteRequestCreated(_ request: SeerrMediaRequest) {
        if let owner = seerrService.requestOwnerKey {
            var record = SeerrRequestWatchStore.record(for: owner)
            if record.awaiting[request.id] == nil {
                record.awaiting[request.id] = ""
                SeerrRequestWatchStore.save(record, for: owner)
            }
        }
        lastRefresh = nil
        #if os(iOS)
        if preferences.requestArrivalNotificationsEnabled {
            Task { await SeerrRequestNotifications.requestAuthorizationIfNeeded() }
        }
        #endif
        Task { await refresh(force: true) }
    }

    private func announce(_ arrivals: [SeerrRequestWatchRecord.Arrival]) async {
        #if os(iOS)
        // Still recorded as announced: turning notifications back on later
        // shouldn't bring a flood of old ones.
        guard preferences.requestArrivalNotificationsEnabled else { return }
        for arrival in arrivals {
            guard let type = arrival.request.mediaType else { continue }
            await SeerrRequestNotifications.announce(
                requestID: arrival.request.id,
                title: arrival.title.nilIfEmpty ?? (type == .tv ? "Your show" : "Your movie"),
                seasons: type == .tv ? Self.seasonsLabel(arrival.request.seasons) : nil,
                type: type,
                tmdbID: arrival.request.media.tmdbId
            )
        }
        #endif
    }

    /// A title that failed to load this time keeps the card it had.
    private func item(
        for request: SeerrListedRequest,
        phase: SeerrRequestPhase,
        previous: Item?
    ) -> Item? {
        guard let type = request.mediaType else { return nil }
        let title: String
        let posterPath: String?
        let detail: String?
        if let info = titleInfo(for: request) {
            title = info.title
            posterPath = info.posterPath
            detail = type == .tv ? Self.seasonsLabel(request.seasons) : info.year.map(String.init)
        } else if let previous {
            title = previous.title
            posterPath = previous.posterPath
            detail = previous.detail
        } else {
            return nil
        }
        return Item(
            requestID: request.id,
            mediaType: type,
            tmdbID: request.media.tmdbId,
            title: title,
            detail: detail,
            posterPath: posterPath,
            phase: phase,
            route: route(for: request, type: type, phase: phase, title: title)
        )
    }

    /// Here, or partly here: the Plex page, which plays it. Otherwise the
    /// Seerr page with the request's status.
    private func route(
        for request: SeerrListedRequest,
        type: SeerrMediaType,
        phase: SeerrRequestPhase,
        title: String
    ) -> AppNavigationRoute {
        let tmdbID = request.media.tmdbId
        guard phase == .ready || phase == .partiallyAvailable else {
            return .seerrMedia(type: type, id: tmdbID)
        }
        if let ratingKey = request.media.ratingKey?.nilIfEmpty,
           let serverID = plexService.seerrBindingServerID {
            return .media(
                type: type == .tv ? .show : .movie,
                id: PlexItemID(serverID: serverID, ratingKey: ratingKey)
            )
        }
        return .seerrInPlex(type: type, id: tmdbID, title: title)
    }

    private func loadTitles(for requests: [SeerrListedRequest]) async {
        var missing: [String: (SeerrMediaType, Int)] = [:]
        for request in requests {
            guard let type = request.mediaType else { continue }
            let key = Self.titleKey(type: type, tmdbID: request.media.tmdbId)
            if titles[key] == nil { missing[key] = (type, request.media.tmdbId) }
        }
        guard !missing.isEmpty else { return }

        let seerrService = seerrService
        let loaded = await withTaskGroup(of: (String, TitleInfo?).self) { group in
            for (key, (type, tmdbID)) in missing {
                group.addTask {
                    switch type {
                    case .movie:
                        let details = try? await seerrService.movieDetails(id: tmdbID)
                        return (key, details.map { TitleInfo(title: $0.title, posterPath: $0.posterPath, year: $0.year) })
                    case .tv:
                        let details = try? await seerrService.tvDetails(id: tmdbID)
                        return (key, details.map { TitleInfo(title: $0.name, posterPath: $0.posterPath, year: $0.year) })
                    }
                }
            }
            var collected: [(String, TitleInfo?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        for (key, info) in loaded {
            if let info { titles[key] = info }
        }
    }

    private func titleInfo(for request: SeerrListedRequest) -> TitleInfo? {
        guard let type = request.mediaType else { return nil }
        return titles[Self.titleKey(type: type, tmdbID: request.media.tmdbId)]
    }

    private static func titleKey(type: SeerrMediaType, tmdbID: Int) -> String {
        "\(type.rawValue):\(tmdbID)"
    }

    /// "Season 2", "Seasons 1–3", "4 Seasons".
    nonisolated static func seasonsLabel(_ seasons: [SeerrSeasonRequest]?) -> String? {
        let numbers = Array(Set((seasons ?? []).map(\.seasonNumber))).sorted()
        guard let first = numbers.first, let last = numbers.last else { return nil }
        if numbers.count == 1 {
            return first == 0 ? "Specials" : "Season \(first)"
        }
        if first > 0, last - first + 1 == numbers.count {
            return "Seasons \(first)–\(last)"
        }
        return "\(numbers.count) Seasons"
    }
}
