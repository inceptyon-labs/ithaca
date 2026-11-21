import Foundation

/// A title's review scores: Rotten Tomatoes critics (the Tomatometer) and
/// audience in percent, IMDb and TMDB out of 10. Athena reads them as a
/// title's `scores`.
struct ReviewScores: Encodable, Sendable, Equatable {
    var critics: Int?
    var audience: Int?
    var imdb: Double?
    var tmdb: Double?

    var isEmpty: Bool {
        critics == nil && audience == nil && imdb == nil && tmdb == nil
    }

    /// The score a card shows: Rotten Tomatoes critics, else IMDb.
    var label: String? {
        if let critics { return "RT \(critics)%" }
        if let imdb { return "IMDb \(imdb.formatted(.number.precision(.fractionLength(1))))" }
        return nil
    }
}

extension ReviewScores {
    /// Plex's two ratings, each out of 10, with its source named by its image:
    /// `rating` is the critics' ("rottentomatoes://image.rating.ripe"),
    /// `audienceRating` the audience's ("rottentomatoes://image.rating.upright",
    /// "imdb://image.rating", "themoviedb://image.rating"). Which sources a
    /// library has depends on its agent settings.
    init(item: PlexItem) {
        self.init()
        assign(item.rating, source: item.ratingImage, isAudience: false)
        assign(item.audienceRating, source: item.audienceRatingImage, isAudience: true)
    }

    private mutating func assign(_ value: Double?, source: String?, isAudience: Bool) {
        guard let value, value > 0, let scheme = source?.split(separator: ":").first?.lowercased() else { return }
        switch scheme {
        case "rottentomatoes":
            let percent = Int((value * 10).rounded())
            if isAudience { audience = percent } else { critics = percent }
        case "imdb":
            imdb = value
        case "themoviedb":
            tmdb = value
        default:
            break
        }
    }
}
