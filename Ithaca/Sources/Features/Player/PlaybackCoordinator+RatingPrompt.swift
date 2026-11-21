import Foundation
import OSLog

private let ratingPromptLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Ithaca",
    category: "RatingPrompt"
)

/// The title "How was it?" asks about: the movie, or the show of the episode.
struct PlaybackRatingPrompt: Identifiable, Sendable, Hashable {
    let id: PlexItemID
    let title: String
}

/// A prompt noted when a session ended, waiting for the player to close.
struct PendingPlaybackRatingPrompt: Sendable {
    let prompt: PlaybackRatingPrompt
    /// The episode that ended, when the prompt is about its show: it is only
    /// asked once there is no next episode.
    let endedEpisode: PlexMediaDetails?
    let notedAt: Date
}

extension PlaybackCoordinator {
    /// A prompt noted this long before the player closes is dropped: the
    /// session ended in Picture in Picture and the viewer has moved on.
    private static let ratingPromptMaxAge: TimeInterval = 60

    /// Called while the session is finalized and the item is still known.
    /// Only a session that reached the scrobble point counts as watched; any
    /// other session drops an earlier note, so a later one never asks about it.
    func noteRatingPromptCandidate() {
        pendingRatingPrompt = nil
        guard preferences.asksForRatings,
              hasScrobbled,
              activeLiveTVContext == nil,
              let details = activeItemDetails,
              // "Other Videos" items are movies with a clip subtype.
              !details.isClip,
              let serverID = activePlaybackServerID else {
            return
        }

        switch details.type {
        case .movie:
            pendingRatingPrompt = PendingPlaybackRatingPrompt(
                prompt: PlaybackRatingPrompt(
                    id: PlexItemID(serverID: serverID, ratingKey: details.ratingKey),
                    title: details.title
                ),
                endedEpisode: nil,
                notedAt: .now
            )
        case .episode:
            guard let showKey = details.grandparentRatingKey?.nilIfEmpty,
                  let showTitle = details.grandparentTitle?.nilIfEmpty else {
                return
            }
            pendingRatingPrompt = PendingPlaybackRatingPrompt(
                prompt: PlaybackRatingPrompt(
                    id: PlexItemID(serverID: serverID, ratingKey: showKey),
                    title: showTitle
                ),
                endedEpisode: details,
                notedAt: .now
            )
        default:
            return
        }
    }

    /// Called once the player cover has closed. Asks only about a title the
    /// viewer has not rated, on a server that is still reachable.
    func presentPendingRatingPrompt() {
        guard let pending = pendingRatingPrompt else { return }
        pendingRatingPrompt = nil
        // Ratings only shape recommendations while Seerr is connected.
        guard preferences.asksForRatings,
              tasteRecommender?.isAvailable == true,
              Date.now.timeIntervalSince(pending.notedAt) < Self.ratingPromptMaxAge,
              let serverID = pending.prompt.id.serverID,
              plexService.pool.connection(for: serverID) != nil else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // A show is asked about once the viewer has caught up: with
            // another episode to go, it is not over yet. A failed lookup
            // asks nothing.
            if let episode = pending.endedEpisode {
                do {
                    if try await plexService.getNextEpisode(after: episode) != nil { return }
                } catch {
                    return
                }
            }
            guard let details = try? await plexService.getMediaDetails(
                      ratingKey: pending.prompt.id.ratingKey,
                      serverID: serverID
                  ),
                  details.userRating == nil,
                  !showPlayer,
                  ratingPrompt == nil else {
                return
            }
            ratingPrompt = pending.prompt
        }
    }

    /// The viewer's answer. `nil` is Not Now.
    func answerRatingPrompt(_ prompt: PlaybackRatingPrompt, with rating: PlexTasteRating?) {
        if ratingPrompt == prompt {
            ratingPrompt = nil
        }
        guard let rating else { return }
        Task { @MainActor [plexService] in
            do {
                try await plexService.setRatingAcrossServers(rating, id: prompt.id)
            } catch {
                ratingPromptLogger.notice(
                    "Could not save the rating for \(prompt.id.storageKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
