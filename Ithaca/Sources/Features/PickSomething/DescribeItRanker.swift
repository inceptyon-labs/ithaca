import Foundation

/// Ranks titles against a `DescribeItQuery` on the device: the library for
/// picks, Seerr's recent list for titles to request. Answers in Athena's
/// shape, so Pick Something treats the two the same.
struct DescribeItRanker: Sendable {
    let query: DescribeItQuery
    /// Genre concept → how much the viewer likes it, -1...1, from what they
    /// loved, liked, disliked and finished.
    private let taste: [String: Double]
    /// The titles `query.similar` names.
    private let references: [PlexItem]

    init(query: DescribeItQuery, catalog: TasteCatalog) {
        self.query = query
        var weights: [String: Double] = [:]
        for seed in catalog.seeds {
            guard let item = catalog.library.item(for: seed.key) else { continue }
            for concept in Self.concepts(item.genres?.map(\.tag) ?? []) {
                weights[concept, default: 0] += seed.weight
            }
        }
        let peak = weights.values.map(abs).max() ?? 0
        taste = peak > 0 ? weights.mapValues { $0 / peak } : [:]
        references = query.similar.compactMap { catalog.library.item(for: $0) }
    }

    func answer(
        _ request: AthenaPickRequest,
        options: PickSomethingAthenaOptions,
        feed: PickSomethingRequestFeed?
    ) -> AthenaAnswer {
        var answer = AthenaAnswer(minimums: query.minimums)
        if request.count > 0 {
            answer.picks = picks(request, options: options)
        }
        if request.suggest > 0, let feed {
            answer.suggestions = suggestions(from: feed.entries, count: request.suggest)
        }
        return answer
    }

    // MARK: Library

    private func picks(_ request: AthenaPickRequest, options: PickSomethingAthenaOptions) -> [AthenaPick] {
        let excluded = Set(request.exclude)
        let wanted = Self.concepts(query.genres)
        let strict = query.hasSubject
        var scored: [(id: String, score: Double, reason: String, isLooseHit: Bool)] = []

        for title in request.titles where !excluded.contains(title.id) {
            guard let entry = options.entry(for: title.id), passes(entry) else { continue }
            let item = entry.item
            let genres = item.genres?.map(\.tag) ?? []
            let concepts = Self.concepts(genres)
            var score = 0.0
            var isSubject = false
            var reasons: [String] = []

            let matched = query.genres.map { Self.concepts([$0]) }.filter { !$0.isDisjoint(with: concepts) }
            if !matched.isEmpty {
                isSubject = true
                score += 2 * Double(wanted.intersection(concepts).count)
                if let first = query.genres.first, !Self.concepts([first]).isDisjoint(with: concepts) { score += 0.5 }
            }

            let titleWords = DescribeItText.words(item.title)
            let summary = " " + DescribeItText.normalized(item.summary ?? "") + " "
            let summaryWords = DescribeItText.words(item.summary)
            for keyword in query.keywords {
                let hit = Self.contains(keyword, words: titleWords, text: " " + DescribeItText.normalized(item.title) + " ")
                    ? 3.0
                    : Self.contains(keyword, words: summaryWords, text: summary) ? 2.0 : 0
                if hit > 0 {
                    isSubject = true
                    score += hit
                }
            }
            var isLooseHit = false
            for keyword in query.looseKeywords where Self.contains(keyword, words: titleWords.union(summaryWords), text: summary) {
                score += 1.5
                isLooseHit = true
            }

            let directors = Set((item.directors ?? []).map(\.tag))
            let cast = Set((item.roles ?? []).map(\.tag))
            for person in query.people {
                if directors.contains(person) {
                    isSubject = true
                    score += 5
                    reasons.append("Directed by \(person)")
                } else if cast.contains(person) {
                    isSubject = true
                    score += 4
                    reasons.append("With \(person)")
                }
            }

            for reference in references {
                let referenceConcepts = Self.concepts(reference.genres?.map(\.tag) ?? [])
                let union = concepts.union(referenceConcepts)
                let overlap = union.isEmpty ? 0 : Double(concepts.intersection(referenceConcepts).count) / Double(union.count)
                let sharedDirectors = directors.intersection((reference.directors ?? []).map(\.tag)).count
                let sharedCast = min(2, cast.intersection((reference.roles ?? []).map(\.tag)).count)
                var similarity = 3 * overlap + 2 * Double(sharedDirectors) + Double(sharedCast)
                if let year = item.year, let referenceYear = reference.year, abs(year - referenceYear) <= 10 {
                    similarity += 0.5
                }
                if overlap >= 0.34 || sharedDirectors > 0 || sharedCast > 0 {
                    isSubject = true
                    score += similarity
                    if similarity >= 2 { reasons.append("Like \(reference.title)") }
                }
            }

            if strict, !isSubject { continue }
            score += (query.acclaimed ? 3 : 1) * Self.quality(ReviewScores(item: item))
            score += affinity(concepts)
            score += Double.random(in: 0..<0.35)
            scored.append((title.id, score, reasons.prefix(2).joined(separator: " · "), isLooseHit))
        }
        // With nothing else to go on, the words the phrase list didn't know
        // decide, when any title has them ("documentary about sharks").
        if !strict, scored.contains(where: \.isLooseHit) {
            scored.removeAll { !$0.isLooseHit }
        }

        return scored.sorted { $0.score > $1.score }
            .prefix(request.count)
            .map { AthenaPick(id: $0.id, reason: $0.reason) }
    }

    /// The query's hard limits: ruled-out genres, years, length, ratings for
    /// children, and minimum reviews. A minimum needs a known score: unlike
    /// Claude, Ithaca can't judge a title it has no score for.
    private func passes(_ entry: PickSomethingAthenaOptions.Entry) -> Bool {
        let item = entry.item
        if query.similar.contains(entry.key) { return false }
        let genres = item.genres?.map(\.tag) ?? []
        if !Self.concepts(query.excludedGenres).isDisjoint(with: Self.concepts(genres)) { return false }
        if query.family, !Self.suitsChildren(rating: item.contentRating, genres: genres) { return false }
        if query.adult, Self.concepts(genres).contains("family") || Self.isChildrensRating(item.contentRating) {
            return false
        }
        if let years = query.years {
            guard let year = item.year, years.contains(year) else { return false }
        }
        let minutes = (item.duration ?? 0) / 60_000
        if let maxMinutes = query.maxMinutes, !(1...maxMinutes).contains(minutes) { return false }
        if let minMinutes = query.minMinutes, minutes < minMinutes { return false }
        let scores = ReviewScores(item: item)
        if let minimum = query.minimums.critics, Double(scores.critics ?? -1) < minimum { return false }
        if let minimum = query.minimums.audience, Double(scores.audience ?? -1) < minimum { return false }
        if let minimum = query.minimums.imdb, (scores.imdb ?? -1) < minimum { return false }
        return true
    }

    // MARK: To Request

    private func suggestions(from entries: [AthenaPickRequest.Outside], count: Int) -> [AthenaSuggestion] {
        let wanted = Self.concepts(query.genres)
        let strict = query.hasSubject
        let excluded = Self.concepts(query.excludedGenres)
        var scored: [(entry: AthenaPickRequest.Outside, score: Double, isLooseHit: Bool)] = []

        for entry in entries {
            let concepts = Self.concepts(entry.genres ?? [])
            if !excluded.isDisjoint(with: concepts) { continue }
            if let years = query.years {
                guard let year = entry.year, years.contains(year) else { continue }
            }
            if query.family, concepts.isDisjoint(with: ["family", "animation"]) { continue }
            if query.adult, concepts.contains("family") { continue }

            var score = 0.0
            var isSubject = false
            let matched = wanted.intersection(concepts).count
            if matched > 0 {
                isSubject = true
                score += 2 * Double(matched)
            }
            let text = " " + DescribeItText.normalized("\(entry.title) \(entry.overview ?? "")") + " "
            let words = DescribeItText.words("\(entry.title) \(entry.overview ?? "")")
            for keyword in query.keywords where Self.contains(keyword, words: words, text: text) {
                isSubject = true
                score += 2
            }
            var isLooseHit = false
            for keyword in query.looseKeywords where Self.contains(keyword, words: words, text: text) {
                score += 1.5
                isLooseHit = true
            }
            for reference in references {
                let referenceConcepts = Self.concepts(reference.genres?.map(\.tag) ?? [])
                let union = concepts.union(referenceConcepts)
                guard !union.isEmpty else { continue }
                let overlap = Double(concepts.intersection(referenceConcepts).count) / Double(union.count)
                if overlap >= 0.34 {
                    isSubject = true
                    score += 3 * overlap
                }
            }
            if strict, !isSubject { continue }
            score += (query.acclaimed ? 3 : 1) * (entry.tmdb ?? 5) / 10
            score += affinity(concepts)
            score += Double.random(in: 0..<0.35)
            scored.append((entry, score, isLooseHit))
        }
        if !strict, scored.contains(where: \.isLooseHit) {
            scored.removeAll { !$0.isLooseHit }
        }

        return scored.sorted { $0.score > $1.score }
            .prefix(count)
            .map { AthenaSuggestion(title: $0.entry.title, year: $0.entry.year, discoverId: $0.entry.id, reason: "") }
    }

    // MARK: Helpers

    /// A genre's canonical keys, or its own name when it has none, so "Sci-Fi
    /// & Fantasy" and "Science Fiction" meet.
    private static func concepts(_ genres: [String]) -> Set<String> {
        var concepts = Set<String>()
        for genre in genres {
            let keys = DescribeItGenres.keys(forGenreName: genre)
            if keys.isEmpty {
                concepts.insert(DescribeItText.normalized(genre))
            } else {
                concepts.formUnion(keys)
            }
        }
        return concepts
    }

    /// A one-word keyword against the singular words, a phrase against the
    /// normalized text.
    private static func contains(_ keyword: String, words: Set<String>, text: String) -> Bool {
        keyword.contains(" ") ? text.contains(" \(keyword) ") : words.contains(keyword)
    }

    /// The viewer's average liking of the genres, -1...1.
    private func affinity(_ concepts: Set<String>) -> Double {
        let values = concepts.compactMap { taste[$0] }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// The known scores' average, 0...1; 0.5 with none.
    private static func quality(_ scores: ReviewScores) -> Double {
        let values = [
            scores.critics.map { Double($0) / 100 },
            scores.audience.map { Double($0) / 100 },
            scores.imdb.map { $0 / 10 },
            scores.tmdb.map { $0 / 10 },
        ].compactMap { $0 }
        return values.isEmpty ? 0.5 : values.reduce(0, +) / Double(values.count)
    }

    private static let familyRatings: Set<String> = [
        "g", "pg", "tv y", "tv y7", "tv y7 fv", "tv g", "tv pg", "u", "uc", "0", "6", "7", "all", "approved",
        "passed", "gb/u", "gb/pg", "de/0", "de/6",
    ]

    private static let unratedRatings: Set<String> = ["", "not rated", "nr", "unrated", "none"]

    /// A family rating, or no rating on an animated or family title (most
    /// shorts have none).
    private static func suitsChildren(rating: String?, genres: [String]) -> Bool {
        let normalized = DescribeItText.normalized(rating ?? "")
        if familyRatings.contains(normalized) || familyRatings.contains((rating ?? "").lowercased()) { return true }
        guard unratedRatings.contains(normalized) else { return false }
        return !concepts(genres).isDisjoint(with: ["family", "animation"])
    }

    private static func isChildrensRating(_ rating: String?) -> Bool {
        guard let rating else { return false }
        return ["g", "tv y", "tv y7", "tv g", "u"].contains(DescribeItText.normalized(rating))
    }
}
