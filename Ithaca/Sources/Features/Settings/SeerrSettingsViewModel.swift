import Foundation

@MainActor
@Observable
final class SeerrSettingsViewModel {
    var serverURL = ""
    var showsConnectionConfirmation = false
    /// The Seerr found beside a Plex server, while `serverURL` is still it.
    private var foundURL: String?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private var resolvedServerURL: URL?

    /// The configured address, else a Seerr found beside a Plex server.
    func load(from service: SeerrService, plexService: PlexService) async {
        guard serverURL.isEmpty else { return }
        if let configured = service.configuredBaseURL {
            serverURL = configured.absoluteString
            return
        }
        let hosts = HomeServerFinder.hosts(plexService: plexService)
        guard !hosts.isEmpty, let found = await HomeServerFinder.findSeerr(hosts: hosts),
              serverURL.isEmpty, service.configuredBaseURL == nil else { return }
        serverURL = found.absoluteString
        foundURL = serverURL
    }

    var footer: String {
        serverURL == foundURL
            ? "Found on your Plex server. Connect with Plex to sign in."
            : "Enter the address you use for Seerr."
    }

    func prepareConnection(using service: SeerrService) async {
        isWorking = true
        errorMessage = nil
        resolvedServerURL = nil
        defer { isWorking = false }

        do {
            resolvedServerURL = try await service.resolveServerURL(
                serverURLString: serverURL
            )
            showsConnectionConfirmation = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect(using service: SeerrService) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let destination = resolvedServerURL?.absoluteString ?? serverURL
            try await service.connect(serverURLString: destination)
            serverURL = service.configuredBaseURL?.absoluteString ?? serverURL
            resolvedServerURL = service.configuredBaseURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect(using service: SeerrService) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        await service.disconnect()
        resolvedServerURL = nil
    }

    var confirmationMessage: String {
        let normalized = resolvedServerURL
            ?? (try? SeerrService.normalizedBaseURL(from: serverURL))
        let transportWarning = normalized?.scheme == "http"
            ? " This connection isn’t encrypted, so connect only on your home network."
            : ""
        let target = normalized?.host().map {
            "\(normalized?.scheme ?? "https")://\($0)" + (normalized?.port.map { ":\($0)" } ?? "")
        } ?? "this server"
        return "Ithaca will try to sign in to Seerr at \(target) with your current Plex account.\(transportWarning)"
    }
}
