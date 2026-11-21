import Foundation
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// Apple's on-device model (Apple Intelligence, iOS 26 and later) reading a
/// Describe It request into a `DescribeItQuery`. It runs on the device, so
/// what the viewer types stays there. tvOS has no Foundation Models.
enum DescribeItAppleModel {
    /// nil when the model isn't on this device, isn't ready, or doesn't
    /// answer: the phrase list reads the request then.
    static func interpret(
        _ request: String,
        kind: PickSomethingKind,
        vocabulary: DescribeItVocabulary
    ) async -> DescribeItQuery? {
        #if canImport(FoundationModels) && !os(tvOS)
        guard #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable else { return nil }
        return await DescribeItModelReader.read(request, kind: kind, vocabulary: vocabulary)
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels) && !os(tvOS)
@available(iOS 26.0, *)
@Generable
private struct DescribeItRequestReading {
    @Guide(description: "Genres from the given list that fit the request, best first. Moods count: cozy is Comedy or Family, tense is Thriller. Empty when no genre fits.")
    var genres: [String]

    @Guide(description: "Genres from the given list the request rules out, like Horror for \"nothing scary\".")
    var excludedGenres: [String]

    @Guide(description: "Up to four specific subjects, settings or plot elements asked for, each a lowercase word likely to appear in a plot summary, like heist, shark, christmas or space. Not moods, genres or names.")
    var subjects: [String]

    @Guide(description: "Actors or directors the request names, as full names.")
    var people: [String]

    @Guide(description: "Titles of movies or shows the request says it should be like.")
    var similarTitles: [String]

    @Guide(description: "The earliest release year asked for, or 0 for none. The 80s start in 1980.")
    var earliestYear: Int

    @Guide(description: "The latest release year asked for, or 0 for none. The 80s end in 1989.")
    var latestYear: Int

    @Guide(description: "The longest running time asked for, in minutes, or 0 for none. Under two hours is 120.")
    var maxMinutes: Int

    @Guide(description: "The shortest running time asked for, in minutes, or 0 for none.")
    var minMinutes: Int

    @Guide(description: "True when it has to suit children.")
    var forChildren: Bool

    @Guide(description: "True when the request asks for something highly rated, acclaimed or among the best.")
    var acclaimed: Bool
}

@available(iOS 26.0, *)
private enum DescribeItModelReader {
    static func read(_ request: String, kind: PickSomethingKind, vocabulary: DescribeItVocabulary) async -> DescribeItQuery? {
        let year = Calendar.current.component(.year, from: .now)
        let library = kind == .movie ? "movie" : "TV show"
        let session = LanguageModelSession(instructions: """
            You read what someone feels like watching and turn it into search filters for their own \(library) library. \
            Use only these genres: \(vocabulary.genres.prefix(80).joined(separator: ", ")). \
            Fill in only what the request says or clearly means, and leave the rest empty, 0 or false. It is \(year).
            """)
        do {
            let reading = try await session.respond(to: request, generating: DescribeItRequestReading.self).content
            return query(from: reading, vocabulary: vocabulary, year: year)
        } catch {
            return nil
        }
    }

    /// Only what the library has: its genre names, its people, its titles.
    private static func query(from reading: DescribeItRequestReading, vocabulary: DescribeItVocabulary, year: Int) -> DescribeItQuery {
        var query = DescribeItQuery()
        query.genres = unique(reading.genres.flatMap { vocabulary.libraryGenres(for: $0) })
        query.excludedGenres = unique(reading.excludedGenres.flatMap { vocabulary.libraryGenres(for: $0) })
        query.genres.removeAll { query.excludedGenres.contains($0) }
        query.keywords = Array(unique(reading.subjects.compactMap { subject -> String? in
            let normalized = DescribeItText.normalized(subject)
            guard normalized.count >= 3, !DescribeItText.stopwords.contains(normalized),
                  vocabulary.libraryGenres(for: normalized).isEmpty else { return nil }
            return normalized.contains(" ") ? normalized : DescribeItText.singular(normalized)
        }).prefix(4))
        query.people = unique(reading.people.compactMap { name in
            let normalized = DescribeItText.normalized(name)
            if let person = vocabulary.people[normalized] { return person }
            guard let last = normalized.split(separator: " ").last,
                  let names = vocabulary.lastNames[String(last)], names.count == 1,
                  let full = names.first else { return nil }
            return vocabulary.people[full]
        })
        for title in reading.similarTitles {
            let words = DescribeItText.normalized(title).split(separator: " ").map(String.init)
            guard let found = vocabulary.title(atStartOf: words[...]), found.length == words.count else { continue }
            query.similar += found.keys.filter { !query.similar.contains($0) }
        }
        let validYears = 1900...(year + 1)
        let earliest = validYears.contains(reading.earliestYear) ? reading.earliestYear : nil
        let latest = validYears.contains(reading.latestYear) ? reading.latestYear : nil
        if earliest != nil || latest != nil {
            let lower = earliest ?? 1900
            let upper = latest ?? year
            if lower <= upper { query.years = lower...upper }
        }
        if (1...600).contains(reading.maxMinutes) { query.maxMinutes = reading.maxMinutes }
        if (1...600).contains(reading.minMinutes) { query.minMinutes = reading.minMinutes }
        query.family = reading.forChildren
        query.acclaimed = reading.acclaimed
        return query
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
#endif

extension DescribeItQuery {
    /// The model's reading with the phrase list's: the phrase list's numbers
    /// win (it reads "under 90 minutes" exactly), names and genres add up,
    /// and its unknown words stay loose.
    func merged(withPhrases phrases: DescribeItQuery) -> DescribeItQuery {
        var merged = self
        func add(_ values: [String], to list: inout [String]) {
            for value in values where !list.contains(value) { list.append(value) }
        }
        add(phrases.excludedGenres, to: &merged.excludedGenres)
        add(phrases.genres, to: &merged.genres)
        merged.genres.removeAll { merged.excludedGenres.contains($0) }
        add(phrases.keywords, to: &merged.keywords)
        add(phrases.people, to: &merged.people)
        merged.similar += phrases.similar.filter { !merged.similar.contains($0) }
        merged.looseKeywords = phrases.looseKeywords.filter { !merged.keywords.contains($0) }
        merged.years = phrases.years ?? years
        merged.maxMinutes = phrases.maxMinutes ?? maxMinutes
        merged.minMinutes = phrases.minMinutes ?? minMinutes
        merged.minimums.critics = phrases.minimums.critics ?? minimums.critics
        merged.minimums.audience = phrases.minimums.audience ?? minimums.audience
        merged.minimums.imdb = phrases.minimums.imdb ?? minimums.imdb
        merged.acclaimed = acclaimed || phrases.acclaimed
        merged.adult = adult || phrases.adult
        merged.family = (family || phrases.family) && !merged.adult
        return merged
    }
}
