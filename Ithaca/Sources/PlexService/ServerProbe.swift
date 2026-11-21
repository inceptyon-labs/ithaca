import Foundation

/// One candidate endpoint for reaching a server, in priority order.
struct ConnectionCandidate: Sendable {
    let baseURL: URL
    let probeURL: URL
    let connection: PlexConnection
}

/// Outcome of racing every candidate of a single server.
enum ConnectionResolution: Sendable {
    case connected(URL, PlexConnection)
    case unauthorized
    case failed(String)
}

/// The connection race for one Plex server, with no session state of its own.
///
/// Lifted verbatim out of `PlexService+Servers` so several servers can be
/// probed in parallel without each race reaching into the shared service. The
/// behavior is deliberately unchanged: same ordering, same grace window, same
/// `/identity` + `/library/sections` pair.
enum ServerProbe {
    /// How long, after the first connection succeeds, we keep waiting for a
    /// still-pending higher-priority connection (e.g. the LAN address) to also
    /// come back before committing to the best success we already have. Bounds
    /// the classic "off-network, local address hangs" stall while still letting
    /// a reachable local connection win the race when we're actually home.
    static let connectionPreferenceGrace: Duration = .milliseconds(1500)

    /// How long a confirmed plain-HTTP twin waits for its HTTPS sibling before
    /// sending the token anyway. Shorter than `connectionPreferenceGrace`, so a
    /// LAN reached over HTTP still beats a remote connection when local HTTPS
    /// hangs instead of failing.
    static let httpsHeadStart: Duration = .seconds(1)

    /// A prepared, Sendable unit of work for one candidate probe. The requests
    /// are built by the caller (they need the session's Plex headers) but carry
    /// no actor state, so the actual networking can fan out across a task group.
    struct Plan: Sendable {
        let index: Int
        let baseURL: URL
        let connection: PlexConnection
        /// `/identity`, sent without the token.
        let probeRequest: URLRequest
        /// `/library/sections`, the only probe request that carries the token.
        let validationRequest: URLRequest
        /// The machine identifier the answering server has to report.
        let machineIdentifier: String
        /// For a plain-HTTP twin, the index of the HTTPS plan for the same
        /// connection. The twin only runs once that plan has failed.
        var fallbackFor: Int?

        var isPlainHTTP: Bool {
            baseURL.scheme?.lowercased() == "http"
        }
    }

    static func makePlans(
        candidates: [ConnectionCandidate],
        headers: [String: String],
        token: String,
        machineIdentifier: String
    ) -> [Plan] {
        var validationHeaders = headers
        validationHeaders["X-Plex-Token"] = token

        var plans = candidates.enumerated().compactMap { index, candidate -> Plan? in
            let timeout: TimeInterval = candidate.connection.local ? 20 : 8

            var probeRequest = URLRequest(url: candidate.probeURL)
            probeRequest.httpMethod = "GET"
            probeRequest.timeoutInterval = timeout
            apply(headers, to: &probeRequest)

            guard let validationURL = validationURL(for: candidate.baseURL) else {
                return nil
            }
            var validationRequest = URLRequest(url: validationURL)
            validationRequest.httpMethod = "GET"
            validationRequest.timeoutInterval = timeout
            validationRequest.cachePolicy = .reloadIgnoringLocalCacheData
            apply(validationHeaders, to: &validationRequest)

            return Plan(
                index: index,
                baseURL: candidate.baseURL,
                connection: candidate.connection,
                probeRequest: probeRequest,
                validationRequest: validationRequest,
                machineIdentifier: machineIdentifier
            )
        }
        for position in plans.indices where plans[position].isPlainHTTP {
            let connection = plans[position].connection
            plans[position].fallbackFor = plans.first { !$0.isPlainHTTP && $0.connection == connection }?.index
        }
        return plans
    }

    /// Probes every candidate connection concurrently and returns the working
    /// one with the highest priority (earliest in the sorted candidate list).
    ///
    /// The race is priority-preserving, not first-past-the-post: a candidate is
    /// only committed once no higher-priority candidate can still win — either
    /// because they have all resolved, or because the preference grace elapsed
    /// after the first success. This keeps local playback preferred when we're
    /// home while never blocking on a hung LAN address when we're away.
    static func resolve(
        plans: [Plan],
        serverName: String,
        session: URLSession,
        grace: Duration = connectionPreferenceGrace,
        headStart: Duration = ServerProbe.httpsHeadStart
    ) async -> ConnectionResolution {
        guard !plans.isEmpty else {
            return .failed("Could not connect to \(serverName)")
        }

        let planByIndex = Dictionary(uniqueKeysWithValues: plans.map { ($0.index, $0) })
        // Plain-HTTP twins, keyed by the HTTPS plan they stand in for. A twin
        // confirms the server without the token straight away, but only sends
        // the token once its sibling failed or `headStart` ran out, so the token
        // stays off plain HTTP while HTTPS to that address works.
        let fallbackByPrimary = Dictionary(
            plans.compactMap { plan in plan.fallbackFor.map { ($0, plan) } },
            uniquingKeysWith: { first, _ in first }
        )

        return await withTaskGroup(of: Event.self) { group -> ConnectionResolution in
            for plan in plans {
                if plan.fallbackFor == nil {
                    group.addTask {
                        .probe(index: plan.index, result: await runProbe(session: session, plan: plan))
                    }
                } else {
                    group.addTask {
                        .identity(index: plan.index, result: await confirmIdentity(session: session, plan: plan))
                    }
                }
            }

            var pending = Set(plans.map(\.index))
            var bestIndex: Int?
            var sawUnauthorized = false
            var lastFailure = "Could not connect to \(serverName)"
            var graceStarted = false
            // HTTPS plans that failed for a reason other than a rejected token.
            var failedPrimaries = Set<Int>()
            // Twins whose server is confirmed and that wait for their sibling.
            var waitingTwins = Set<Int>()

            func winner() -> ConnectionResolution? {
                guard let bestIndex, let plan = planByIndex[bestIndex] else { return nil }
                return .connected(plan.baseURL, plan.connection)
            }

            // Once a success exists, we can commit as soon as no still-pending
            // candidate outranks it (nothing better can arrive).
            func bestIsUnbeatable() -> Bool {
                guard let bestIndex else { return false }
                return !pending.contains { $0 < bestIndex }
            }

            for await event in group {
                switch event {
                case let .probe(index, result):
                    pending.remove(index)
                    let fallback = fallbackByPrimary[index]
                    switch result {
                    case .success:
                        // HTTPS works here, so its twin never sends the token.
                        if let fallback {
                            pending.remove(fallback.index)
                            waitingTwins.remove(fallback.index)
                        }
                        if bestIndex == nil || index < bestIndex! {
                            bestIndex = index
                        }
                        if !graceStarted {
                            graceStarted = true
                            group.addTask {
                                try? await Task.sleep(for: grace)
                                return .graceElapsed
                            }
                        }
                    case let .failure(unauthorized, reason):
                        if unauthorized { sawUnauthorized = true }
                        lastFailure = reason
                        guard let fallback else { break }
                        if unauthorized {
                            // A rejected token would be rejected over HTTP too.
                            pending.remove(fallback.index)
                            waitingTwins.remove(fallback.index)
                        } else {
                            failedPrimaries.insert(index)
                            if waitingTwins.remove(fallback.index) != nil {
                                group.addTask {
                                    .probe(index: fallback.index, result: await validate(session: session, plan: fallback))
                                }
                            }
                        }
                    }
                case let .identity(index, result):
                    guard pending.contains(index), let twin = planByIndex[index], let primary = twin.fallbackFor else {
                        break
                    }
                    switch result {
                    case let .failed(reason):
                        pending.remove(index)
                        lastFailure = reason
                    case .confirmed where failedPrimaries.contains(primary):
                        group.addTask {
                            .probe(index: index, result: await validate(session: session, plan: twin))
                        }
                    case .confirmed:
                        waitingTwins.insert(index)
                        group.addTask {
                            try? await Task.sleep(for: headStart)
                            return .headStartElapsed(index: index)
                        }
                    }
                case let .headStartElapsed(index):
                    guard waitingTwins.remove(index) != nil, let twin = planByIndex[index] else { break }
                    group.addTask {
                        .probe(index: index, result: await validate(session: session, plan: twin))
                    }
                case .graceElapsed:
                    // A better candidate was still pending, but we've waited long
                    // enough — go with the best working connection we have.
                    if let resolution = winner() {
                        group.cancelAll()
                        return resolution
                    }
                }

                if bestIsUnbeatable(), let resolution = winner() {
                    group.cancelAll()
                    return resolution
                }
                if pending.isEmpty {
                    break
                }
            }

            if let resolution = winner() {
                group.cancelAll()
                return resolution
            }
            if sawUnauthorized {
                return .unauthorized
            }
            return .failed(lastFailure)
        }
    }

    /// Runs one candidate's reachability probe (`/identity`, no token) and,
    /// once the answering server is confirmed to be this one, an authorization
    /// check (`/library/sections`). Pure networking on Sendable inputs so it is
    /// safe to fan out across a task group off the main actor.
    private static func runProbe(session: URLSession, plan: Plan) async -> ChildResult {
        switch await confirmIdentity(session: session, plan: plan) {
        case let .failed(reason):
            return .failure(unauthorized: false, reason: reason)
        case .confirmed:
            return await validate(session: session, plan: plan)
        }
    }

    /// `/identity` without the token. The answering server has to report this
    /// server's machine identifier; over plain HTTP it also has to report one.
    private static func confirmIdentity(session: URLSession, plan: Plan) async -> IdentityResult {
        do {
            let (identityData, response) = try await session.data(for: plan.probeRequest)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Invalid response")
            }
            // The request has no token, so a 401 says nothing about the token;
            // it only leaves the server's identity unconfirmed.
            let reportedIdentifier: String?
            switch http.statusCode {
            case 200...299:
                reportedIdentifier = machineIdentifier(in: identityData)
            case 401:
                reportedIdentifier = nil
            default:
                return .failed("HTTP \(http.statusCode)")
            }
            if let reportedIdentifier {
                guard reportedIdentifier.caseInsensitiveCompare(plan.machineIdentifier) == .orderedSame else {
                    return .failed("A different server answered at \(plan.baseURL.host ?? "this address")")
                }
            } else if plan.isPlainHTTP {
                // Nothing else proves who answered over plain HTTP, so the token stays home.
                return .failed("Could not confirm the server's identity")
            }
            return .confirmed
        } catch is CancellationError {
            return .failed("Cancelled")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `/library/sections` with the token: the authorization check.
    private static func validate(session: URLSession, plan: Plan) async -> ChildResult {
        do {
            let (_, validationResponse) = try await session.data(for: plan.validationRequest)
            guard let validationHTTP = validationResponse as? HTTPURLResponse else {
                return .failure(unauthorized: false, reason: "Invalid validation response")
            }
            switch validationHTTP.statusCode {
            case 200...299:
                return .success
            case 401:
                return .failure(unauthorized: true, reason: "HTTP 401")
            default:
                return .failure(unauthorized: false, reason: "HTTP \(validationHTTP.statusCode)")
            }
        } catch is CancellationError {
            return .failure(unauthorized: false, reason: "Cancelled")
        } catch {
            return .failure(unauthorized: false, reason: error.localizedDescription)
        }
    }

    /// Reads `machineIdentifier` from an `/identity` body, JSON or XML.
    static func machineIdentifier(in data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let container = object["MediaContainer"] as? [String: Any] {
            return (container["machineIdentifier"] as? String)?.nilIfEmpty
        }
        guard let body = String(data: data, encoding: .utf8),
              let match = body.firstMatch(of: /machineIdentifier="([^"]+)"/) else {
            return nil
        }
        return String(match.1)
    }

    private static func validationURL(for baseURL: URL) -> URL? {
        let base = baseURL.absoluteString
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URLComponents(string: trimmed + "/library/sections")?.url
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private enum ChildResult: Sendable {
        case success
        case failure(unauthorized: Bool, reason: String)
    }

    private enum IdentityResult: Sendable {
        case confirmed
        case failed(String)
    }

    private enum Event: Sendable {
        case probe(index: Int, result: ChildResult)
        case identity(index: Int, result: IdentityResult)
        case headStartElapsed(index: Int)
        case graceElapsed
    }
}
