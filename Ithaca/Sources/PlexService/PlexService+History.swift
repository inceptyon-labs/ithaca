import Foundation

extension PlexService {
    func getCurrentUser() async throws -> PlexUser {
        if let currentUser {
            return currentUser
        }

        let session = serverSessionToken
        let user: PlexUser = try await plexTVRequest(path: "/user")
        if session == serverSessionToken {
            currentUser = user
        }
        return user
    }

    func getPlaybackHistory(
        accountId: Int?,
        librarySectionId: String,
        viewedSince: Date,
        limit: Int = 400,
        pageSize: Int = 200,
        serverID: String? = nil
    ) async throws -> [PlexPlaybackHistoryEntry] {
        let epochSeconds = Int(viewedSince.timeIntervalSince1970.rounded(.down))
        let clampedLimit = max(limit, 0)
        let clampedPageSize = max(pageSize, 1)

        // PMS records the server owner's plays under its local account 1, not
        // the plex.tv ID. Owned and unrestricted means the active identity is
        // the owner.
        let isOwner = pool.connection(for: serverID)?.owned == true
            && activeHomeUser?.isRestricted != true
        let historyAccountID = isOwner ? 1 : accountId

        guard clampedLimit > 0 else { return [] }

        var entries: [PlexPlaybackHistoryEntry] = []
        var start = 0

        while entries.count < clampedLimit {
            let currentPageSize = min(clampedPageSize, clampedLimit - entries.count)
            var queryItems = [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(currentPageSize)),
                URLQueryItem(name: "sort", value: "viewedAt:desc"),
                URLQueryItem(name: "librarySectionID", value: librarySectionId),
                URLQueryItem(name: "viewedAt>", value: String(epochSeconds)),
            ]

            if let historyAccountID {
                queryItems.append(URLQueryItem(name: "accountID", value: String(historyAccountID)))
            }

            let page: [PlexPlaybackHistoryEntry]
            do {
                page = try await fetchMetadata(
                    path: "/status/sessions/history/all",
                    queryItems: queryItems,
                    serverID: serverID
                )
            } catch let error as PlexServiceError
                where error == .unauthorized || error.isServerUnauthorized || error == .httpError(statusCode: 403) {
                // History is admin-only on some servers (shared servers,
                // managed Home users). No access just means no history.
                break
            }

            guard !page.isEmpty else { break }

            entries.append(contentsOf: page.filter { historyAccountID == nil || $0.accountID == nil || $0.accountID == historyAccountID })
            start += page.count

            if page.count < currentPageSize {
                break
            }
        }

        return entries
    }
}
