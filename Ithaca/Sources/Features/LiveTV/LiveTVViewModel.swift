import Foundation

@MainActor
@Observable
final class LiveTVViewModel {
    private let plexService: PlexService

    private(set) var provider: PlexLiveTVProvider?
    private(set) var channels: [PlexLiveChannel] = []
    private(set) var lineup: PlexLiveTVLineup?
    private(set) var nowPlayingLineup: PlexLiveTVLineup?
    private(set) var selectedDate = Calendar.current.startOfDay(for: .now)
    /// The guide's load. Home's now-playing load has its own flag, so opening
    /// the tab while the Home shelf loads still loads the guide.
    private(set) var isLoading = false
    private var isLoadingNowPlaying = false
    private(set) var isAvailable = false
    private(set) var error: String?

    private var loadedDate: Date?
    private var followsToday = true
    private var discoveryCompleted = false
    /// The server discovery last got an answer from, DVR or not.
    private var discoveredServerID: String?
    /// What a server change emptied that may be on screen. The guide and the
    /// Home shelf only load when they appear, so these are refilled once the
    /// new server is discovered and no load of that kind is running.
    private var refillsGuide = false
    private var refillsNowPlaying = false
    /// A date picked or a refresh pulled while the guide was loading.
    private var reloadsGuide = false

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func discover() async {
        resetIfServerChanged()
        guard !discoveryCompleted else { return }
        do {
            provider = try await fetchProvider()
            isAvailable = provider != nil
            discoveryCompleted = true
        } catch {
            // Live TV is optional. A discovery failure must not block the rest
            // of Ithaca, but opening the destination can retry and show details.
            isAvailable = false
        }
        await runRefills()
    }

    func load(force: Bool = false) async {
        guard !isLoading else {
            reloadsGuide = reloadsGuide || force
            return
        }
        await loadGuide(force: force)
        while reloadsGuide {
            reloadsGuide = false
            await loadGuide(force: true)
        }
        await runRefills()
    }

    func loadNowPlaying(force: Bool = false) async {
        guard !isLoadingNowPlaying else { return }
        await loadNowPlayingLineup(force: force)
        await runRefills()
    }

    private func loadGuide(force: Bool) async {
        resetIfServerChanged()
        // A guide left open past midnight should move to the new day.
        if followsToday {
            selectedDate = Calendar.current.startOfDay(for: .now)
        }
        if !force, lineup != nil, Calendar.current.isDate(loadedDate ?? .distantPast, inSameDayAs: selectedDate) {
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }
        let date = selectedDate

        do {
            if provider == nil {
                provider = try await fetchProvider()
            }
            guard let provider else {
                isAvailable = false
                discoveryCompleted = true
                lineup = nil
                return
            }

            isAvailable = true
            discoveryCompleted = true
            if channels.isEmpty || force {
                let fetched = try await plexService.getLiveTVChannels(provider: provider)
                guard self.provider == provider else { return }
                channels = fetched
            }
            let fetchedLineup = try await plexService.getLiveTVGuide(
                provider: provider,
                channels: channels,
                date: date
            )
            guard self.provider == provider else { return }
            lineup = fetchedLineup
            loadedDate = date
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadNowPlayingLineup(force: Bool) async {
        resetIfServerChanged()
        guard force || nowPlayingLineup == nil else { return }
        isLoadingNowPlaying = true
        defer { isLoadingNowPlaying = false }

        do {
            if provider == nil {
                provider = try await fetchProvider()
            }
            guard let provider else {
                isAvailable = false
                discoveryCompleted = true
                return
            }
            isAvailable = true
            discoveryCompleted = true
            if channels.isEmpty {
                let fetched = try await plexService.getLiveTVChannels(provider: provider)
                guard self.provider == provider else { return }
                channels = fetched
            }
            let fetchedLineup = try await plexService.getLiveTVNowPlaying(
                provider: provider,
                channels: channels
            )
            guard self.provider == provider else { return }
            nowPlayingLineup = fetchedLineup
        } catch {
            self.error = error.localizedDescription
        }
    }

    func selectDate(_ date: Date) async {
        selectedDate = Calendar.current.startOfDay(for: date)
        followsToday = Calendar.current.isDateInToday(selectedDate)
        await load(force: true)
    }

    func imageURL(for path: String?, width: Int, height: Int) -> URL? {
        // Channel and program art paths belong to the provider's server, which
        // is not necessarily the primary `imageURL` would fall back to.
        plexService.imageURL(
            for: path,
            serverID: provider?.serverID ?? plexService.liveTVServerID,
            width: width,
            height: height
        )
    }

    /// Asks the current Live TV server for its DVR, and remembers which
    /// server answered even when it has none.
    private func fetchProvider() async throws -> PlexLiveTVProvider? {
        let serverID = plexService.liveTVServerID
        let provider = try await plexService.getLiveTVProvider(serverID: serverID)
        discoveredServerID = provider?.serverID ?? serverID
        return provider
    }

    /// Live TV follows the highest-priority connected server. When that is a
    /// different server than the one discovered (a higher one connected late,
    /// or this one dropped), its lineup and DVR mean nothing there, and its
    /// "no DVR" answer means nothing either: forget them and discover again.
    /// Not while no server is connected, so a network blip does not take the
    /// Live TV tab away.
    private func resetIfServerChanged() {
        guard discoveryCompleted, let serverID = plexService.liveTVServerID,
              serverID != discoveredServerID else { return }
        // A load in flight is for the old provider and its result is dropped.
        refillsGuide = refillsGuide || lineup != nil || isLoading
        refillsNowPlaying = refillsNowPlaying || nowPlayingLineup != nil || isLoadingNowPlaying
        provider = nil
        channels = []
        lineup = nil
        nowPlayingLineup = nil
        loadedDate = nil
        error = nil
        discoveryCompleted = false
    }

    /// Kept while the new server has no DVR, for when one comes back. A load
    /// of the same kind still running refills when it finishes.
    private func runRefills() async {
        guard discoveryCompleted, provider != nil else { return }
        if refillsGuide, !isLoading {
            refillsGuide = false
            await load()
        }
        if refillsNowPlaying, !isLoadingNowPlaying {
            refillsNowPlaying = false
            await loadNowPlaying()
        }
    }

    var dateOptions: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (-1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }
}
