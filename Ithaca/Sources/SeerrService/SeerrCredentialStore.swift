import Foundation

struct SeerrStoredSession: Codable, Sendable, Hashable {
    let baseURL: String
    let profileID: String
    let serverID: String
    var cookies: [String: String]
}

enum SeerrCredentialStore {
    private static let keychainKey = "SeerrSessions"

    /// nil while the Keychain is locked (before the first unlock after a
    /// restart), when the stored sessions can't be read and must not be saved
    /// over.
    static func load() -> [SeerrStoredSession]? {
        switch KeychainHelper.read(key: keychainKey) {
        case .locked:
            return nil
        case .missing:
            return []
        case let .found(data):
            return (try? JSONDecoder().decode([SeerrStoredSession].self, from: data)) ?? []
        }
    }

    static func save(_ sessions: [SeerrStoredSession]) {
        guard !sessions.isEmpty else {
            KeychainHelper.delete(key: keychainKey)
            return
        }

        guard let data = try? JSONEncoder().encode(sessions) else { return }
        KeychainHelper.save(key: keychainKey, data: data)
    }

    static func removeAll() {
        KeychainHelper.delete(key: keychainKey)
    }
}

