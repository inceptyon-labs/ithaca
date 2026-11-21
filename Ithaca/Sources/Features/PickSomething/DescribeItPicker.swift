import Foundation

/// Who answers Describe It: Athena, when one is set in Settings or found
/// beside Plex and the viewer agreed to send it requests, otherwise Ithaca on
/// the device.
enum DescribeItEngine: Sendable {
    case athena(AthenaClient, plexToken: String?)
    case onDevice
}

/// Answers Describe It in Athena's shape, from Athena or on the device. On
/// the device, Apple's model (where there is one) and the phrase list read the
/// request once per text, then `DescribeItRanker` ranks the titles.
@MainActor
final class DescribeItPicker {
    private var queries: [String: Task<DescribeItQuery, Never>] = [:]
    private var vocabulary: (readAt: Date, value: DescribeItVocabulary)?

    func answer(
        _ request: AthenaPickRequest,
        engine: DescribeItEngine,
        kind: PickSomethingKind,
        options: PickSomethingAthenaOptions,
        catalog: TasteCatalog,
        feed: PickSomethingRequestFeed? = nil
    ) async throws -> AthenaAnswer {
        switch engine {
        case .athena(let client, let plexToken):
            return try await client.pick(request, plexToken: plexToken)
        case .onDevice:
            let query = await query(for: request.request, kind: kind, catalog: catalog)
            try Task.checkCancellation()
            return await Task.detached(priority: .userInitiated) {
                DescribeItRanker(query: query, catalog: catalog).answer(request, options: options, feed: feed)
            }.value
        }
    }

    /// Picks and To Request ask at once: both wait on one reading.
    private func query(for text: String, kind: PickSomethingKind, catalog: TasteCatalog) async -> DescribeItQuery {
        let key = "\(kind.rawValue)\n\(catalog.readAt.timeIntervalSinceReferenceDate)\n\(text)"
        if let task = queries[key] { return await task.value }
        let vocabulary = await vocabulary(for: catalog)
        if let task = queries[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            let phrases = DescribeItPhrases(vocabulary: vocabulary, kind: kind).parse(text)
            guard let model = await DescribeItAppleModel.interpret(text, kind: kind, vocabulary: vocabulary) else {
                return phrases
            }
            return model.merged(withPhrases: phrases)
        }
        queries[key] = task
        return await task.value
    }

    private func vocabulary(for catalog: TasteCatalog) async -> DescribeItVocabulary {
        if let vocabulary, vocabulary.readAt == catalog.readAt { return vocabulary.value }
        let library = catalog.library
        let value = await Task.detached(priority: .userInitiated) { DescribeItVocabulary(library: library) }.value
        vocabulary = (catalog.readAt, value)
        return value
    }
}
