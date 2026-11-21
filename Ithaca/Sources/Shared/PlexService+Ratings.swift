import Foundation
import OSLog

private let ratingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Ithaca",
    category: "Ratings"
)

extension PlexService {
    /// Sets this profile's rating of an item on one server, or clears it
    /// (`nil`). Plex keeps a rating per user, so a Plex Home member rates for
    /// themselves.
    func setUserRating(_ rating: PlexTasteRating?, ratingKey: String, serverID: String?) async throws {
        invalidateRecentMetadata()
        defer { invalidateRecentMetadata() }
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/:/rate",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                // -1 removes the rating (and its lastRatedAt).
                URLQueryItem(name: "rating", value: rating.map { String($0.plexValue) } ?? "-1"),
            ],
            serverID: serverID
        )
    }

    /// Rates every connected copy of the item, like `setWatchedAcrossServers`:
    /// recommendations read ratings from whichever server holds the title. The
    /// requested copy decides the outcome; the others are best effort.
    func setRatingAcrossServers(_ rating: PlexTasteRating?, id: PlexItemID) async throws {
        try await setUserRating(rating, ratingKey: id.ratingKey, serverID: id.serverID)
        // Bumped once every copy is written, so a rebuild cannot read a copy
        // that still has the old rating.
        defer { tasteRevision += 1 }

        for instance in alternates.instances(of: id) {
            guard let serverID = instance.serverID,
                  serverID != id.serverID,
                  pool.connection(for: serverID) != nil else {
                continue
            }

            do {
                try await setUserRating(rating, ratingKey: instance.ratingKey, serverID: serverID)
            } catch {
                ratingLogger.notice(
                    "Could not rate \(instance.storageKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Every title in a movie or TV library with what taste recommendations
    /// read and a poster card shows: ids and guids, this profile's watch state
    /// and rating, title, year, genres and artwork. Cast, media and summaries
    /// are left out, which halves the payload. Pick Something's Describe It
    /// sends the genres to Athena.
    ///
    /// Plex lists at most two genres per title here, so a genre filter has to
    /// be the server's own (`filters`, e.g. `genre` to a library's genre id).
    func getTasteLibraryItems(
        sectionId: String,
        serverID: String?,
        filters: [String: String] = [:]
    ) async throws -> [PlexItem] {
        try await fetchMetadata(
            path: "/library/sections/\(sectionId)/all",
            queryItems: [
                URLQueryItem(name: "includeGuids", value: "1"),
                // Summary, directors and the top three cast are what Describe
                // It matches on the device; about a quarter more to read.
                URLQueryItem(name: "excludeElements", value: "Media,Writer,Country,Collection"),
                URLQueryItem(name: "excludeFields", value: "tagline"),
            ] + filters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) },
            serverID: serverID
        )
    }
}
