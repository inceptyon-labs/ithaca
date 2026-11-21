import Foundation

/// What Pick Something picks from: a movie or a show.
enum PickSomethingKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case movie
    case show

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movie: "Movies"
        case .show: "TV Shows"
        }
    }

    var libraryType: PlexLibraryType {
        switch self {
        case .movie: .movie
        case .show: .show
        }
    }

    var mediaType: PlexMediaType {
        switch self {
        case .movie: .movie
        case .show: .show
        }
    }

    var seerrType: SeerrMediaType {
        switch self {
        case .movie: .movie
        case .show: .tv
        }
    }
}

/// "How long have you got": a movie's running time, or a show's typical
/// episode length (Plex reports that as the show's `duration`).
struct PickSomethingRuntime: Hashable, Identifiable, Sendable {
    let maxMinutes: Int?

    static let any = PickSomethingRuntime(maxMinutes: nil)

    var id: Int { maxMinutes ?? 0 }

    var title: String {
        guard let maxMinutes else { return "Any Length" }
        let hours = maxMinutes / 60
        let minutes = maxMinutes % 60
        switch (hours, minutes) {
        case (0, _): return "Under \(minutes)m"
        case (_, 0): return "Under \(hours)h"
        default: return "Under \(hours)h \(minutes)m"
        }
    }

    static func options(for kind: PickSomethingKind) -> [PickSomethingRuntime] {
        let limits = kind == .movie ? [90, 120, 150] : [30, 60]
        return [.any] + limits.map { PickSomethingRuntime(maxMinutes: $0) }
    }
}

/// The filters on the Pick Something screen.
struct PickSomethingCriteria: Hashable, Sendable {
    var kind: PickSomethingKind
    var runtime: PickSomethingRuntime = .any
    /// A genre title from any of the kind's libraries; nil is any genre.
    /// Matched per library by normalized title, because genre filter values
    /// are per-library ids.
    var genreTitle: String?
    /// Only titles nobody watching has seen.
    var unwatchedOnly = true

    /// The Plex query for one library. `genreValue` is that library's own id
    /// for `genreTitle`. Each filter narrows the server's answer only;
    /// `matches(_:)` is still the final check.
    func serverFilters(genreValue: String?) -> [String: String] {
        var filters: [String: String] = [:]
        if unwatchedOnly {
            filters[LibraryUnwatchedFilter.parameterName(for: kind.libraryType)] = "1"
        }
        if let genreValue {
            filters["genre"] = genreValue
        }
        // Movies only: a show section's duration filter applies to episodes.
        // `duration<<=` is Plex's "less than"; `<=` would mean "begins with".
        if kind == .movie, let maxMinutes = runtime.maxMinutes {
            filters["duration<<"] = String(maxMinutes * 60_000)
        }
        return filters
    }

    /// Whether the active profile's copy of an item fits. Plex ignores a filter
    /// it does not know, and a show's unwatched filter keeps shows that are
    /// part watched, so every candidate is checked here.
    func matches(_ item: PlexItem) -> Bool {
        guard item.type == kind.mediaType, !item.isClip, !item.isPlaceholder else { return false }
        if let maxMinutes = runtime.maxMinutes {
            guard let duration = item.duration, duration > 0, duration < maxMinutes * 60_000 else {
                return false
            }
        }
        if unwatchedOnly {
            let state = PlexViewerItemState(
                viewCount: item.viewCount ?? 0,
                viewOffset: item.viewOffset ?? 0,
                viewedLeafCount: item.viewedLeafCount ?? 0
            )
            return isUnseen(state)
        }
        return true
    }

    /// Whether another member watching can be offered an item, given what
    /// they see of it. nil means they cannot see that copy (no access, or a
    /// content restriction); `PickSomethingEngine.roomCheck` then tries the
    /// title's copies on other servers.
    func allows(_ state: PlexViewerItemState?) -> Bool {
        guard let state else { return false }
        return !unwatchedOnly || isUnseen(state)
    }

    /// Never started: a movie with no plays and no position, a show with no
    /// watched episode. Half-watched titles are Continue Watching's job.
    func isUnseen(_ state: PlexViewerItemState) -> Bool {
        switch kind {
        case .movie:
            state.viewCount == 0 && state.viewOffset == 0
        case .show:
            state.viewCount == 0 && state.viewedLeafCount == 0
        }
    }
}
