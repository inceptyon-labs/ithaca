import Foundation

/// Another Plex Home member's server tokens, borrowed so Pick Something can
/// read what they have watched. Held in memory by the screen that asked for
/// it and never written anywhere: no Keychain, no UserDefaults, no logs.
struct PlexHomeViewerAccess: Sendable {
    let user: PlexHomeUser
    /// Server access tokens by server ID. A server missing here is one this
    /// member has no access to.
    let serverTokens: [String: String]
}

/// What one member sees of one item: their own watch state, under their own
/// library restrictions.
struct PlexViewerItemState: Sendable, Equatable {
    let viewCount: Int
    let viewOffset: Int
    let viewedLeafCount: Int
}

extension PlexService {
    /// Gets a Home member's own server tokens: the switch endpoint for their
    /// account token (the PIN, if any, goes only into that request), then
    /// their server list. The active session is untouched.
    func homeViewerAccess(for user: PlexHomeUser, pin: String?) async throws -> PlexHomeViewerAccess {
        let accountToken = try await homeUserAccountToken(for: user, pin: pin)
        let data = try await rawPlexTVRequest(
            path: "/api/v2/resources",
            queryItems: [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1"),
            ],
            accountToken: accountToken,
            retriesFreshAuthentication: false
        )

        guard let resources = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PlexServiceError.decodingError("Expected JSON array from resources endpoint")
        }

        var serverTokens: [String: String] = [:]
        for resource in resources {
            guard (resource["provides"] as? String)?.contains("server") == true,
                  let serverID = (resource["clientIdentifier"] as? String)?.nilIfEmpty,
                  let token = (resource["accessToken"] as? String)?.nilIfEmpty else { continue }
            serverTokens[serverID] = token
        }
        return PlexHomeViewerAccess(user: user, serverTokens: serverTokens)
    }

    /// The member's state for each of `ratingKeys` on one server, keyed by
    /// rating key. A key missing from the result is an item they cannot see
    /// (no access to the server or library, or a content restriction).
    ///
    /// Reads through the active session's connection with the member's token.
    /// It deliberately skips `fetchMetadata`: that reports watch states to the
    /// offline sync and fills the metadata caches, which both belong to the
    /// active profile.
    func viewerItemStates(
        ratingKeys: [String],
        serverID: String,
        access: PlexHomeViewerAccess
    ) async throws -> [String: PlexViewerItemState] {
        guard !ratingKeys.isEmpty, let token = access.serverTokens[serverID] else { return [:] }
        guard let connection = pool.connection(for: serverID) else {
            throw PlexServiceError.noServerConnected
        }

        var states: [String: PlexViewerItemState] = [:]
        // Plex reads a comma-separated key list in one request; chunked so the
        // URL stays short.
        for chunk in stride(from: 0, to: ratingKeys.count, by: 40).map({
            ratingKeys[$0..<min($0 + 40, ratingKeys.count)]
        }) {
            guard let url = buildURL(
                base: connection.baseURL.absoluteString,
                path: "/library/metadata/\(chunk.joined(separator: ","))"
            ) else { throw PlexServiceError.invalidURL }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            applyHeaders(to: &request, token: token)

            let data: Data
            do {
                data = try await executeRequest(request, retriesFreshAuthentication: false)
            } catch let error as PlexServiceError
                where error == .unauthorized || error == .httpError(statusCode: 403) || error == .httpError(statusCode: 404) {
                // The member cannot see any of these.
                continue
            }

            let response = try await decodeJSONInBackground(
                MetadataResponse<PlexItem>.self,
                from: data,
                serverID: serverID
            )
            for item in response.MediaContainer.Metadata ?? [] {
                states[item.ratingKey] = PlexViewerItemState(
                    viewCount: item.viewCount ?? 0,
                    viewOffset: item.viewOffset ?? 0,
                    viewedLeafCount: item.viewedLeafCount ?? 0
                )
            }
        }
        return states
    }
}
