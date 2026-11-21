import Foundation

/// One round of candidates.
struct PickSomethingBatch {
    let items: [PlexItem]
    /// Every library was read whole, so an empty batch means nothing is left.
    /// A sampled library can still turn up new titles in another window.
    let isExhaustive: Bool
    /// Every matching copy of a title found on two or more servers, by
    /// content key (strong keys only). `roomCheck` retries from these.
    var copies: [PlexContentKey: [PlexItem]] = [:]
}

/// Finds Pick Something candidates: random windows of each library that fit
/// the criteria, then the room check against everyone else watching.
@MainActor
struct PickSomethingEngine {
    let plexService: PlexService

    /// Libraries at or under this size are read whole; larger ones are
    /// sampled at random offsets.
    private let pageSize = 50
    private let wholeLibraryLimit = 150
    private let windowsPerLibrary = 2

    /// Every connected server's movie and show sections, in the account's order.
    func libraries() async throws -> [PlexLibrary] {
        try await plexService.ensureLibraryOrderLoaded()
            .filter { $0.libraryType == .movie || $0.libraryType == .show }
    }

    /// Each library's genres, keyed by `PlexLibrary.id` (section keys alias
    /// across servers). A library whose genres fail to load is left out, so
    /// a genre pick simply skips it.
    func genres(for libraries: [PlexLibrary]) async -> [String: [LibraryGenreOption]] {
        let plexService = plexService
        let options = await RecommendationGenreScoring.concurrentMap(libraries) { library in
            (try? await LibraryGenreSupport.loadGenreOptions(
                sectionId: library.key,
                serverID: library.serverID,
                plexService: plexService
            )) ?? []
        }
        var result: [String: [LibraryGenreOption]] = [:]
        for (library, genres) in zip(libraries, options) {
            result[library.id] = genres.filter { $0.value != nil }
        }
        return result
    }

    /// Every copy, on any server, that Plex files under the criteria's genre,
    /// or nil without a genre. Asked of each library with the server's own
    /// genre filter, because listings carry only two genres per title. One
    /// library failing leaves its titles out; all failing throws.
    func genreMemberIDs(
        criteria: PickSomethingCriteria,
        libraries: [PlexLibrary],
        genres: [String: [LibraryGenreOption]]
    ) async throws -> Set<PlexItemID>? {
        guard let genreTitle = criteria.genreTitle else { return nil }
        let wanted = LibraryGenreSupport.normalizeGenreTitle(genreTitle)
        let targets: [(library: PlexLibrary, value: String)] = libraries.compactMap { library in
            guard library.libraryType == criteria.kind.libraryType,
                  let value = genres[library.id]?.first(where: {
                      LibraryGenreSupport.normalizeGenreTitle($0.title) == wanted
                  })?.value else {
                return nil
            }
            return (library, value)
        }
        let plexService = plexService
        let results = await RecommendationGenreScoring.concurrentMap(targets) { target in
            try? await plexService.getTasteLibraryItems(
                sectionId: target.library.key,
                serverID: target.library.serverID,
                filters: ["genre": target.value]
            )
        }
        if !results.isEmpty, results.allSatisfy({ $0 == nil }) {
            throw AthenaError.noLibrary
        }
        return Set(results.flatMap { ($0 ?? []).map(\.id) })
    }

    /// A shuffled batch of new candidates that fit the criteria for the
    /// active profile, leaving out anything in `excluding` (already shown or
    /// queued) and duplicates of one title on several servers.
    func candidates(
        criteria: PickSomethingCriteria,
        libraries: [PlexLibrary],
        genres: [String: [LibraryGenreOption]],
        excluding: RecommendationSeenTitles
    ) async throws -> PickSomethingBatch {
        let targets: [(library: PlexLibrary, filters: [String: String])] = libraries.compactMap { library in
            guard library.libraryType == criteria.kind.libraryType else { return nil }
            var genreValue: String?
            if let genreTitle = criteria.genreTitle {
                let wanted = LibraryGenreSupport.normalizeGenreTitle(genreTitle)
                guard let match = genres[library.id]?.first(where: {
                    LibraryGenreSupport.normalizeGenreTitle($0.title) == wanted
                }) else { return nil }
                genreValue = match.value
            }
            return (library, criteria.serverFilters(genreValue: genreValue))
        }
        guard !targets.isEmpty else { return PickSomethingBatch(items: [], isExhaustive: true) }

        let results = await RecommendationGenreScoring.concurrentMap(targets) { [self] target in
            do {
                return Result<LibrarySample, Error>.success(
                    try await sample(target.library, filters: target.filters)
                )
            } catch {
                return .failure(error)
            }
        }

        var items: [PlexItem] = []
        var isExhaustive = true
        var firstError: Error?
        for result in results {
            switch result {
            case .success(let sample):
                items.append(contentsOf: sample.items)
                isExhaustive = isExhaustive && sample.isWhole
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        // One server failing never sinks the pick; all of them failing does.
        if items.isEmpty, let firstError { throw firstError }

        // Dropped copies on other servers still need registering, so Seen It
        // and playback fallback can reach them.
        plexService.registerAlternates(PlexItemMerge.alternates(in: [items]))

        let matching = items.filter { criteria.matches($0) }
        var seen = excluding
        let fresh = matching.filter { seen.insert($0) }.shuffled()

        var copies: [PlexContentKey: [PlexItem]] = [:]
        for item in matching where item.contentKey.isStrong && item.serverID != nil {
            let key = item.contentKey
            guard !(copies[key] ?? []).contains(where: { $0.serverID == item.serverID }) else { continue }
            copies[key, default: []].append(item)
        }
        copies = copies.filter { $0.value.count > 1 }
        return PickSomethingBatch(items: fresh, isExhaustive: isExhaustive, copies: copies)
    }

    /// What one viewer makes of one copy of a title.
    private enum Verdict: Sendable {
        case fits
        /// They have watched it: ruled out whatever the server.
        case seen
        /// They cannot see it on this server (no token, no library access, a
        /// restriction) or the check failed. Another copy may still work.
        case unavailable
    }

    private struct ViewerChecks {
        var verdicts: [Int: [PlexItemID: Verdict]] = [:]
        var checkCount = 0
        var failures = 0
        var firstError: Error?
    }

    /// Reads each viewer's state of `copies`, one request per server per
    /// viewer, run side by side. `verdicts[viewer index][copy id]`.
    private func viewerChecks(
        _ copies: [PlexItem],
        viewers: [PlexHomeViewerAccess],
        criteria: PickSomethingCriteria
    ) async -> ViewerChecks {
        var keysByServer: [String: [String]] = [:]
        for item in copies {
            guard let serverID = item.serverID else { continue }
            keysByServer[serverID, default: []].append(item.ratingKey)
        }

        struct Check: Sendable {
            let viewerIndex: Int
            let viewer: PlexHomeViewerAccess
            let serverID: String
            let keys: [String]
        }
        let checks = viewers.enumerated().flatMap { index, viewer in
            keysByServer.map { Check(viewerIndex: index, viewer: viewer, serverID: $0.key, keys: $0.value) }
        }
        let plexService = plexService
        let outcomes = await RecommendationGenreScoring.concurrentMap(checks) { check in
            do {
                return Result<[String: PlexViewerItemState], Error>.success(
                    try await plexService.viewerItemStates(
                        ratingKeys: check.keys,
                        serverID: check.serverID,
                        access: check.viewer
                    )
                )
            } catch {
                return .failure(error)
            }
        }

        var result = ViewerChecks()
        result.checkCount = checks.count
        for (check, outcome) in zip(checks, outcomes) {
            switch outcome {
            case .success(let states):
                for key in check.keys {
                    let verdict: Verdict
                    if let state = states[key] {
                        verdict = criteria.allows(state) ? .fits : .seen
                    } else {
                        verdict = .unavailable
                    }
                    result.verdicts[check.viewerIndex, default: [:]][
                        PlexItemID(serverID: check.serverID, ratingKey: key)
                    ] = verdict
                }
            case .failure(let error):
                // Unknown is not unseen: stays `.unavailable`.
                result.failures += 1
                result.firstError = result.firstError ?? error
            }
        }
        return result
    }

    /// Keeps the candidates everyone else watching can be offered, in order.
    /// Each member's state is read with their own token, one request per
    /// server per member. A candidate that only fails because a member cannot
    /// reach or see it on its server is retried on its other copies
    /// (`copies`, from `PickSomethingBatch`), in one more batched round, and
    /// is returned as the copy that works for the room when there is one.
    func roomCheck(
        _ candidates: [PlexItem],
        viewers: [PlexHomeViewerAccess],
        copies: [PlexContentKey: [PlexItem]] = [:],
        criteria: PickSomethingCriteria
    ) async throws -> [PlexItem] {
        guard !viewers.isEmpty, !candidates.isEmpty else { return candidates }

        let first = await viewerChecks(candidates, viewers: viewers, criteria: criteria)
        // Only when every check failed is there nothing to go on.
        if let firstError = first.firstError, first.failures == first.checkCount {
            throw firstError
        }

        func verdict(_ viewer: Int, _ item: PlexItem, in checks: ViewerChecks) -> Verdict {
            checks.verdicts[viewer]?[item.id] ?? .unavailable
        }

        enum Outcome {
            case keep
            case drop
            case retry([PlexItem])
        }
        var outcomes: [Outcome] = []
        var retryCopies: [PlexItem] = []
        for item in candidates {
            guard item.serverID != nil else { outcomes.append(.drop); continue }
            let verdicts = viewers.indices.map { verdict($0, item, in: first) }
            if verdicts.allSatisfy({ $0 == .fits }) {
                outcomes.append(.keep)
            } else if verdicts.contains(.seen) {
                outcomes.append(.drop)
            } else {
                let others = (copies[item.contentKey] ?? []).filter {
                    $0.serverID != nil && $0.serverID != item.serverID
                }
                if others.isEmpty {
                    outcomes.append(.drop)
                } else {
                    outcomes.append(.retry(others))
                    retryCopies += others
                }
            }
        }
        guard !retryCopies.isEmpty else {
            return zip(candidates, outcomes).compactMap { item, outcome in
                if case .keep = outcome { item } else { nil }
            }
        }

        let second = await viewerChecks(retryCopies, viewers: viewers, criteria: criteria)
        var kept: [PlexItem] = []
        for (item, outcome) in zip(candidates, outcomes) {
            switch outcome {
            case .keep:
                kept.append(item)
            case .drop:
                break
            case .retry(let others):
                let verdictsByViewer = viewers.indices.map { viewer in
                    [verdict(viewer, item, in: first)] + others.map { verdict(viewer, $0, in: second) }
                }
                // Watched on any copy rules the title out; otherwise every
                // member needs some copy they can see.
                guard verdictsByViewer.allSatisfy({ !$0.contains(.seen) && $0.contains(.fits) }) else { continue }
                // Present a copy the whole room can see; if members only see
                // different servers, the title stays as it was.
                let all = [item] + others
                let working = all.indices.first { copy in
                    verdictsByViewer.allSatisfy { $0[copy] == .fits }
                }
                kept.append(working.map { all[$0] } ?? item)
            }
        }
        return kept
    }

    private struct LibrarySample: Sendable {
        let items: [PlexItem]
        let isWhole: Bool
    }

    private func sample(_ library: PlexLibrary, filters: [String: String]) async throws -> LibrarySample {
        do {
            return try await sampleWindows(library, filters: filters)
        } catch PlexServiceError.httpError(statusCode: 400) where filters["duration<<"] != nil {
            // A server that rejects the duration filter still gets sampled;
            // `PickSomethingCriteria.matches` applies the length locally.
            var withoutDuration = filters
            withoutDuration["duration<<"] = nil
            return try await sampleWindows(library, filters: withoutDuration)
        }
    }

    private func sampleWindows(_ library: PlexLibrary, filters: [String: String]) async throws -> LibrarySample {
        let count = try await plexService.getLibraryItemCount(
            sectionId: library.key,
            filters: filters,
            serverID: library.serverID
        )
        guard count > 0 else { return LibrarySample(items: [], isWhole: true) }

        let starts: [Int]
        if count <= wholeLibraryLimit {
            starts = Array(stride(from: 0, to: count, by: pageSize))
        } else {
            var picked = Set<Int>()
            while picked.count < windowsPerLibrary {
                picked.insert(Int.random(in: 0...(count - pageSize)))
            }
            starts = picked.sorted()
        }

        var items: [PlexItem] = []
        for start in starts {
            items += try await plexService.getLibraryItems(
                sectionId: library.key,
                start: start,
                size: pageSize,
                sort: "titleSort",
                filters: filters,
                serverID: library.serverID
            )
        }
        return LibrarySample(items: items, isWhole: count <= wholeLibraryLimit)
    }
}
