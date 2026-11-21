import Foundation

/// The answers Ithaca offers to "how was it?". They are stored as Plex's own
/// 0–10 user rating, so other Plex apps show them as stars and a rating made
/// there reads back here.
enum PlexTasteRating: String, CaseIterable, Sendable, Hashable {
    case loved
    case liked
    case disliked

    /// What Ithaca writes: five stars, four stars, one star.
    var plexValue: Int {
        switch self {
        case .loved: 10
        case .liked: 8
        case .disliked: 2
        }
    }

    /// Reads any Plex rating, half stars from other apps included. Three stars
    /// (5–6) is neither a like nor a dislike, so it reads as no answer here,
    /// though the title still counts as rated.
    init?(plexValue: Double?) {
        guard let plexValue, plexValue >= 0 else { return nil }
        switch plexValue {
        case 9...: self = .loved
        case 7..<9: self = .liked
        case ..<5: self = .disliked
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .loved: "Loved It"
        case .liked: "Liked It"
        case .disliked: "Not for Me"
        }
    }

    var systemImage: String {
        switch self {
        case .loved: "heart.fill"
        case .liked: "hand.thumbsup.fill"
        case .disliked: "hand.thumbsdown.fill"
        }
    }
}
