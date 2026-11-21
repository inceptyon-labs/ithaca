import SwiftUI

/// The detail hero's rating button: Loved It, Liked It or Not for Me, saved as
/// the viewer's Plex rating. The icon shows the current answer; choosing it
/// again, or Clear Rating, removes it.
struct TasteRatingMenu: View {
    let rating: PlexTasteRating?
    var subject: String = ""
    let onSelect: (PlexTasteRating?) -> Void

    var body: some View {
        Menu {
            ForEach(PlexTasteRating.allCases, id: \.self) { option in
                Button {
                    onSelect(option == rating ? nil : option)
                } label: {
                    Label(option.title, systemImage: option == rating ? "checkmark" : option.systemImage)
                }
            }

            if rating != nil {
                Button {
                    onSelect(nil)
                } label: {
                    Label("Clear Rating", systemImage: "xmark")
                }
            }
        } label: {
            DetailHeroSecondaryIconLabel(systemImage: rating?.systemImage ?? "hand.thumbsup")
        }
        .detailHeroNativeSecondaryButtonStyle()
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let base = subject.isEmpty ? "Rate" : "Rate \(subject)"
        guard let rating else { return base }
        return "\(base), \(rating.title)"
    }
}

/// Shared by the movie and show pages: the rating the hero shows, which
/// answers at once while the write is on its way.
struct PendingTasteRating {
    /// `.some(nil)` while clearing a rating.
    private(set) var value: PlexTasteRating??

    func resolved(stored userRating: Double?) -> PlexTasteRating? {
        if let value { return value }
        return PlexTasteRating(plexValue: userRating)
    }

    mutating func begin(_ rating: PlexTasteRating?) {
        value = .some(rating)
    }

    mutating func end() {
        value = nil
    }
}
