import Foundation

/// What a Describe It request asks for, as filters Ithaca checks against the
/// library itself. Without Athena, Apple's on-device model fills it in where
/// there is one (`DescribeItAppleModel`), otherwise `DescribeItPhrases` does;
/// `DescribeItRanker` ranks the titles against it.
struct DescribeItQuery: Sendable, Equatable {
    /// Genre names that fit, any of them, best first.
    var genres: [String] = []
    /// Genre names the request rules out.
    var excludedGenres: [String] = []
    /// Subjects to find in a title or summary, lowercased and singular.
    var keywords: [String] = []
    /// Words the phrase list didn't know ("rainy"): they lift a title that
    /// has them, but no title has to.
    var looseKeywords: [String] = []
    /// Cast or director names, as the library spells them.
    var people: [String] = []
    /// Library titles it should be like.
    var similar: [TasteTitleKey] = []
    var years: ClosedRange<Int>?
    var maxMinutes: Int?
    var minMinutes: Int?
    var minimums = AthenaMinimums()
    /// "Highly rated", "the best": reviews weigh more.
    var acclaimed = false
    /// For children: family ratings only.
    var family = false
    /// "Not for kids": no family or children's genres.
    var adult = false

    /// Whether it names anything a title has to be about.
    var hasSubject: Bool {
        !genres.isEmpty || !keywords.isEmpty || !people.isEmpty || !similar.isEmpty
    }
}

/// The library's own genre names, people and titles, which a query's names
/// are checked against.
struct DescribeItVocabulary: Sendable {
    /// Every genre name in the titles, as Plex spells them.
    let genres: [String]
    /// Lowercased, accent-free full name → the library's spelling.
    let people: [String: String]
    /// Lowercased last name → full names, for "by Nolan".
    let lastNames: [String: Set<String>]
    /// Normalized title → keys, for "like Alien".
    let titles: [String: [TasteTitleKey]]

    init(library: TasteLibrary) {
        var genres = Set<String>()
        var people: [String: String] = [:]
        var lastNames: [String: Set<String>] = [:]
        var titles: [String: [TasteTitleKey]] = [:]
        for (key, copies) in library.copies {
            guard let item = copies.first else { continue }
            for genre in item.genres ?? [] { genres.insert(genre.tag) }
            let names = (item.directors ?? []).map(\.tag) + (item.roles ?? []).map(\.tag)
            for name in names {
                let normalized = DescribeItText.normalized(name)
                let parts = normalized.split(separator: " ")
                guard parts.count >= 2 else { continue }
                people[normalized] = name
                if let last = parts.last, last.count >= 4 {
                    lastNames[String(last), default: []].insert(normalized)
                }
            }
            let title = DescribeItText.normalized(item.title)
            if title.count >= 3 { titles[title, default: []].append(key) }
        }
        self.genres = genres.sorted()
        self.people = people
        self.lastNames = lastNames
        self.titles = titles
    }

    /// The library genre names a canonical genre or a free genre name stands
    /// for ("Sci-Fi" is "Science Fiction" and "Sci-Fi & Fantasy").
    func libraryGenres(for name: String) -> [String] {
        let keys = DescribeItGenres.keys(forGenreName: name)
        let normalized = DescribeItText.normalized(name)
        return genres.filter { genre in
            DescribeItText.normalized(genre) == normalized
                || !keys.isDisjoint(with: DescribeItGenres.keys(forGenreName: genre))
        }
    }

    /// The library title some words start with, longest first, and how many
    /// words it takes: "alien but funnier" is Alien.
    func title(atStartOf words: ArraySlice<String>) -> (keys: [TasteTitleKey], length: Int)? {
        for length in stride(from: min(words.count, 8), through: 1, by: -1) {
            let candidate = words.prefix(length).joined(separator: " ")
            if let keys = titles[candidate], !DescribeItText.stopwords.contains(candidate) {
                return (keys, length)
            }
        }
        return nil
    }
}

/// Text helpers shared by the parser and the ranker.
enum DescribeItText {
    /// Lowercased, accent-free, "&" as "and", punctuation as spaces, single
    /// spaces. Keeps digits, "%" and "+".
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "'")
        var result = ""
        result.reserveCapacity(folded.count)
        for character in folded {
            if character.isLetter || character.isNumber || character == "%" || character == "+" {
                result.append(character)
            } else if character == "'" {
                continue
            } else {
                result.append(" ")
            }
        }
        return result.split(separator: " ").joined(separator: " ")
    }

    /// A word's simple singular: "zombies" is "zombie", "stories" is "story".
    static func singular(_ word: String) -> String {
        guard word.count > 4 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ss") || word.hasSuffix("us") { return word }
        if word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    /// The singular words of a title or summary.
    static func words(_ text: String?) -> Set<String> {
        guard let text else { return [] }
        return Set(normalized(text).split(separator: " ").map { singular(String($0)) })
    }

    /// Words that say nothing about what to watch.
    static let stopwords: Set<String> = [
        "a", "about", "after", "again", "all", "almost", "also", "am", "an", "and", "any", "anything", "are",
        "around", "as", "at", "be", "because", "been", "before", "being", "best", "better", "between", "bit",
        "both", "but", "by", "can", "could", "day", "did", "do", "does", "doing", "dont", "each", "either",
        "else", "enough", "even", "evening", "ever", "every", "feel", "feeling", "film", "films", "find", "for",
        "from", "get", "give", "go", "going", "good", "got", "great", "had", "has", "have", "having", "he",
        "her", "here", "hers", "him", "his", "how", "i", "id", "if", "ill", "im", "in", "into", "is", "it",
        "its", "ive", "just", "kind", "kinda", "know", "least", "less", "let", "lets", "like", "liked", "little",
        "lot", "love", "made", "make", "many", "maybe", "me", "mood", "more", "most", "movie", "movies", "much",
        "must", "my", "need", "new", "nice", "night", "no", "not", "nothing", "now", "of", "off", "on", "one",
        "only", "or", "other", "our", "out", "over", "pick", "please", "pretty", "quite", "rather", "really",
        "recommend", "right", "season", "seasons", "see", "seen", "series", "she", "should", "show", "shows",
        "so", "some", "something", "sort", "still", "suggest", "sure", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "thing", "think", "this", "those", "time", "to", "today", "tonight",
        "too", "tv", "type", "under", "up", "us", "very", "wanna", "want", "was", "watch", "watching", "way",
        "we", "weekend", "were", "what", "when", "where", "which", "while", "who", "whole", "why", "will",
        "with", "within", "without", "would", "year", "years", "yet", "you", "your", "episode", "episodes",
        "rated", "rating", "ratings", "minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs", "long",
        "short", "old", "older", "newer", "recent", "classic", "classics", "watched", "enjoy", "enjoyed",
        "fun", "light", "easy", "people", "guy", "guys", "lady", "man", "woman", "family", "kids", "kid",
        "highly", "higher", "lower", "early", "late", "mid", "silent", "rotten", "tomatoes", "tomato", "imdb",
        "rt", "critic", "critics", "audience", "audiences", "score", "scores", "review", "reviews", "reviewed",
        "acclaimed", "award", "awards", "winning", "oscar", "oscars", "masterpiece", "black", "white",
        "vintage", "golden", "age", "modern", "latest", "came", "between", "flick", "flicks", "starring",
        "featuring", "directed", "director", "actor", "actress", "cast", "top", "must", "worth", "stuff",
    ]
}

/// The genres a phrase can name, by a canonical key, and how a library or
/// TMDB genre name is told apart.
enum DescribeItGenres {
    struct Genre: Sendable {
        let key: String
        /// Substrings of a normalized genre name that make it this genre.
        let names: [String]
        /// Words and phrases in a request that ask for it.
        let triggers: [String]
        /// Triggers specific enough to look for in summaries too.
        let subjects: [String]
    }

    static let all: [Genre] = [
        Genre(key: "comedy", names: ["comedy"],
              triggers: ["comedy", "comedies", "funny", "hilarious", "laugh", "laughs", "lighthearted",
                         "light hearted", "silly", "goofy", "humor", "humour", "sitcom", "funnier", "comedic"],
              subjects: []),
        Genre(key: "horror", names: ["horror"],
              triggers: ["horror", "scary", "spooky", "creepy", "frightening", "terrifying", "scare", "scares",
                         "slasher", "haunted", "zombie", "zombies", "vampire", "vampires", "ghost", "ghosts",
                         "scarier"],
              subjects: ["zombie", "zombies", "vampire", "vampires", "ghost", "ghosts", "haunted", "slasher"]),
        Genre(key: "thriller", names: ["thriller", "suspense"],
              triggers: ["thriller", "thrillers", "suspense", "suspenseful", "tense", "gripping", "nail biter",
                         "edge of my seat", "edge of your seat", "intense"],
              subjects: []),
        Genre(key: "action", names: ["action"],
              triggers: ["action", "explosions", "explosive", "fight", "fights", "fighting", "martial arts",
                         "kung fu", "shootout", "adrenaline", "superhero", "superheroes", "car chase"],
              subjects: ["superhero", "superheroes", "martial arts", "kung fu"]),
        Genre(key: "adventure", names: ["adventure"],
              triggers: ["adventure", "adventures", "quest", "treasure", "swashbuckling", "pirate", "pirates",
                         "jungle", "expedition"],
              subjects: ["treasure", "pirate", "pirates", "jungle", "expedition", "quest"]),
        Genre(key: "scifi", names: ["science fiction", "sci fi", "scifi"],
              triggers: ["sci fi", "scifi", "science fiction", "space", "outer space", "alien", "aliens",
                         "future", "futuristic", "robot", "robots", "dystopian", "dystopia", "time travel",
                         "cyberpunk", "spaceship", "planet"],
              subjects: ["space", "alien", "aliens", "robot", "robots", "time travel", "spaceship", "planet",
                         "dystopian", "future"]),
        Genre(key: "fantasy", names: ["fantasy"],
              triggers: ["fantasy", "magic", "magical", "dragon", "dragons", "wizard", "wizards", "fairy tale",
                         "fairytale", "mythical", "witch", "witches"],
              subjects: ["dragon", "dragons", "wizard", "wizards", "witch", "witches", "magic"]),
        Genre(key: "romance", names: ["romance"],
              triggers: ["romance", "romantic", "love story"],
              subjects: []),
        Genre(key: "drama", names: ["drama"],
              triggers: ["drama", "dramas", "dramatic", "serious", "emotional", "tearjerker", "moving",
                         "heartfelt", "sad", "cry"],
              subjects: []),
        Genre(key: "mystery", names: ["mystery"],
              triggers: ["mystery", "mysteries", "whodunit", "whodunnit", "detective", "puzzle", "twist",
                         "twists", "twisty"],
              subjects: ["detective"]),
        Genre(key: "crime", names: ["crime"],
              triggers: ["crime", "heist", "heists", "gangster", "gangsters", "mob", "mafia", "cop", "cops",
                         "police", "criminal", "noir", "robbery", "dark", "gritty"],
              subjects: ["heist", "heists", "gangster", "gangsters", "mafia", "robbery", "mob"]),
        Genre(key: "animation", names: ["animation", "anime"],
              triggers: ["animated", "animation", "cartoon", "cartoons", "anime", "pixar"],
              subjects: []),
        Genre(key: "documentary", names: ["documentary"],
              triggers: ["documentary", "documentaries", "docuseries", "doc", "docs", "nonfiction",
                         "non fiction"],
              subjects: []),
        Genre(key: "family", names: ["family", "kids", "children"],
              triggers: ["family", "families", "kids", "kid", "children", "child", "all ages", "kid friendly",
                         "family friendly", "toddler", "toddlers"],
              subjects: []),
        Genre(key: "war", names: ["war"],
              triggers: ["war", "wwii", "ww2", "world war", "military", "soldier", "soldiers", "battle"],
              subjects: ["world war", "soldier", "soldiers", "battle"]),
        Genre(key: "western", names: ["western"],
              triggers: ["western", "westerns", "cowboy", "cowboys", "wild west"],
              subjects: ["cowboy", "cowboys"]),
        Genre(key: "music", names: ["music"],
              triggers: ["musical", "musicals", "music", "concert", "band", "singing", "singer"],
              subjects: ["band", "singer", "concert"]),
        Genre(key: "history", names: ["history"],
              triggers: ["history", "historical", "period piece", "period drama"],
              subjects: []),
        Genre(key: "biography", names: ["biography"],
              triggers: ["biography", "biopic", "biopics", "true story", "based on a true story"],
              subjects: []),
        Genre(key: "sport", names: ["sport"],
              triggers: ["sports", "sport", "football", "baseball", "basketball", "boxing", "soccer", "hockey",
                         "boxer"],
              subjects: ["football", "baseball", "basketball", "boxing", "soccer", "hockey", "boxer"]),
        Genre(key: "reality", names: ["reality"],
              triggers: ["reality", "reality show", "competition"],
              subjects: []),
    ]

    /// Moods that stand for several genres.
    static let moods: [(triggers: [String], keys: [String])] = [
        (["feel good", "feelgood", "uplifting", "cozy", "cosy", "comfort", "wholesome", "heartwarming",
          "happy", "cheerful", "easy watch", "lighthearted"], ["comedy", "family", "romance"]),
        (["mind bending", "mindbending", "trippy", "cerebral", "thought provoking"], ["scifi", "mystery", "thriller"]),
        (["date night", "rom com", "romcom"], ["romance", "comedy"]),
        (["brain off", "mindless", "dumb fun", "popcorn"], ["action", "comedy"]),
        (["epic"], ["adventure", "war", "fantasy"]),
        (["rainy day", "lazy", "chill", "relaxing", "laid back"], ["comedy", "drama", "family"]),
    ]

    /// Moods that rule a genre out ("feel good" is not horror).
    static let moodExclusions: [(triggers: [String], keys: [String])] = [
        (["feel good", "feelgood", "uplifting", "cozy", "cosy", "comfort", "wholesome", "heartwarming",
          "happy", "cheerful"], ["horror"]),
    ]

    static func genre(_ key: String) -> Genre? {
        all.first { $0.key == key }
    }

    /// The canonical keys a library or TMDB genre name falls under.
    static func keys(forGenreName name: String) -> Set<String> {
        let normalized = DescribeItText.normalized(name)
        if let genre = all.first(where: { $0.key == normalized }) { return [genre.key] }
        return Set(all.filter { genre in genre.names.contains { normalized.contains($0) } }.map(\.key))
    }

    /// Whether a title's genre name meets one a query asked for.
    static func matches(_ wanted: String, _ candidate: String) -> Bool {
        let wantedName = DescribeItText.normalized(wanted)
        let candidateName = DescribeItText.normalized(candidate)
        if wantedName == candidateName { return true }
        return !keys(forGenreName: wanted).isDisjoint(with: keys(forGenreName: candidate))
    }
}

/// Reads a request with a fixed list of words and phrases: no model, the same
/// answer every time. Used where Apple's model isn't (Apple TV, devices
/// without Apple Intelligence), and for numbers the model can miss.
struct DescribeItPhrases {
    let vocabulary: DescribeItVocabulary
    let kind: PickSomethingKind
    var currentYear = Calendar.current.component(.year, from: .now)

    func parse(_ request: String) -> DescribeItQuery {
        var query = DescribeItQuery()
        // Clauses apart, so "nothing too long, funny" doesn't rule funny out.
        var words = request.split(whereSeparator: { ",.;:!?()".contains($0) })
            .map { DescribeItText.normalized(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
            .split(separator: " ")
            .map(String.init)

        // "Like Alien": the title's words are no subject of their own.
        let markers: [[String]] = [["similar", "to"], ["in", "the", "vein", "of"], ["reminds", "me", "of"], ["same", "vibe", "as"], ["like"]]
        var index = 0
        while index < words.count {
            let marker = markers.first { marker in
                index + marker.count <= words.count && Array(words[index..<(index + marker.count)]) == marker
            }
            if let marker, let found = vocabulary.title(atStartOf: words[(index + marker.count)...]) {
                query.similar += found.keys.filter { !query.similar.contains($0) }
                words.removeSubrange(index..<(index + marker.count + found.length))
                continue
            }
            index += 1
        }

        var consumed = Set<Int>()

        // People: full names, and a last name after "by", "with" or "starring".
        for length in stride(from: 4, through: 2, by: -1) where words.count >= length {
            for start in 0...(words.count - length) {
                let range = start..<(start + length)
                guard consumed.isDisjoint(with: range) else { continue }
                let phrase = words[range].joined(separator: " ")
                if let name = vocabulary.people[phrase] {
                    if !query.people.contains(name) { query.people.append(name) }
                    consumed.formUnion(range)
                }
            }
        }
        // "by Nolan", "a Nolan movie", "Nolan's films".
        for (index, word) in words.enumerated() where !consumed.contains(index) {
            let before = index > 0 ? words[index - 1] : ""
            let after = index + 1 < words.count ? words[index + 1] : ""
            guard ["by", "with", "starring", "from", "featuring"].contains(before)
                    || ["movie", "movies", "film", "films", "show", "shows", "flick", "flicks"].contains(after) else { continue }
            let names = vocabulary.lastNames[word] ?? vocabulary.lastNames[DescribeItText.singular(word)]
            guard let names, names.count == 1, let full = names.first, let name = vocabulary.people[full] else { continue }
            if !query.people.contains(name) { query.people.append(name) }
            consumed.insert(index)
        }

        // Numbers first: "under 2 hours", "over 8 on imdb", "80s".
        parseRuntime(words, into: &query, consumed: &consumed)
        parseScores(words, into: &query, consumed: &consumed)
        parseYears(words, into: &query, consumed: &consumed)

        // Genres and moods, with "not", "no" or "nothing" just before ruling out.
        var genreKeys: [String] = []
        var excludedKeys: [String] = []
        // Up to three words back, stopping at a clause, "and" or "but".
        func negated(_ start: Int) -> Bool {
            for index in stride(from: start - 1, through: max(0, start - 3), by: -1) {
                let word = words[index]
                if ["|", "and", "but", "just", "only", "yet"].contains(word) { return false }
                if ["not", "no", "nothing", "without", "never", "isnt", "non", "except", "avoid", "skip", "hate"].contains(word) {
                    return true
                }
            }
            return false
        }
        func scan(_ triggers: [String], _ handle: (Bool, Range<Int>) -> Void) {
            for trigger in triggers {
                let parts = trigger.split(separator: " ").map(String.init)
                guard words.count >= parts.count else { continue }
                for start in 0...(words.count - parts.count) {
                    let range = start..<(start + parts.count)
                    guard consumed.isDisjoint(with: range), Array(words[range]) == parts else { continue }
                    handle(negated(start), range)
                }
            }
        }
        for mood in DescribeItGenres.moods {
            scan(mood.triggers) { isNegated, range in
                if !isNegated { genreKeys += mood.keys }
                consumed.formUnion(range)
            }
        }
        for exclusion in DescribeItGenres.moodExclusions {
            scan(exclusion.triggers) { isNegated, _ in
                if !isNegated { excludedKeys += exclusion.keys }
            }
        }
        for genre in DescribeItGenres.all {
            scan(genre.triggers) { isNegated, range in
                let trigger = words[range].joined(separator: " ")
                if isNegated {
                    excludedKeys.append(genre.key)
                    if genre.key == "family" { query.adult = true }
                } else {
                    genreKeys.append(genre.key)
                    if genre.key == "family" { query.family = true }
                    if genre.subjects.contains(trigger) {
                        query.keywords.append(DescribeItText.singular(trigger))
                    }
                }
                consumed.formUnion(range)
            }
        }
        for key in excludedKeys { genreKeys.removeAll { $0 == key } }
        query.genres = unique(genreKeys.flatMap { vocabulary.libraryGenres(for: $0) })
        query.excludedGenres = unique(excludedKeys.flatMap { vocabulary.libraryGenres(for: $0) })

        // "For kids" and "PG" without a family genre in the library.
        let joined = " " + words.joined(separator: " ") + " "
        if !joined.contains(" pg 13 "),
           [" pg ", " g rated ", " rated g ", " rated pg ", " for my kids ", " with the kids "].contains(where: joined.contains) {
            query.family = true
        }
        if [" not for kids ", " adult ", " adults ", " grown up ", " grownup "].contains(where: joined.contains) {
            query.family = false
            query.adult = true
        }

        let acclaim = [" highly rated ", " well reviewed ", " acclaimed ", " top rated ", " award winning ",
                       " oscar ", " oscars ", " masterpiece ", " must see ", " best ", " great ", " good reviews ",
                       " classic ", " classics "]
        if acclaim.contains(where: joined.contains) { query.acclaimed = true }

        // What's left that isn't a stopword is a subject: "shark", "christmas".
        for (index, word) in words.enumerated() where !consumed.contains(index) {
            guard word.count >= 3, word.allSatisfy(\.isLetter), !DescribeItText.stopwords.contains(word) else { continue }
            if index > 0, ["no", "not", "without", "nothing"].contains(words[index - 1]) { continue }
            query.looseKeywords.append(DescribeItText.singular(word))
        }
        query.keywords = Array(unique(query.keywords).prefix(6))
        query.looseKeywords = Array(unique(query.looseKeywords).filter { !query.keywords.contains($0) }.prefix(6))
        return query
    }

    // MARK: Runtime

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "half": 0.5, "ninety": 90, "forty": 40, "fifty": 50, "sixty": 60,
        "thirty": 30, "twenty": 20,
    ]

    /// Minutes in a duration starting at `index` ("2 hours", "an hour and a
    /// half", "90 minutes", "90 min"), and how many words it took.
    private func duration(_ words: [String], at index: Int) -> (minutes: Int, length: Int)? {
        guard index < words.count else { return nil }
        var word = words[index]
        var value: Double?
        var length = 1
        // "2h", "90m", "90min"
        if let match = word.firstMatch(of: /^(\d+(?:\.\d+)?)(h|hr|hrs|m|min|mins)$/) {
            let number = Double(match.1) ?? 0
            return (Int(match.2.hasPrefix("h") ? number * 60 : number), 1)
        }
        if word == "half", index + 2 < words.count, words[index + 1] == "an", words[index + 2] == "hour" {
            return (30, 3)
        }
        value = Double(word) ?? Self.numberWords[word]
        guard var number = value else { return nil }
        guard index + 1 < words.count else { return nil }
        word = words[index + 1]
        length = 2
        let isHours = ["hour", "hours", "hr", "hrs", "h"].contains(word)
        let isMinutes = ["minute", "minutes", "min", "mins", "m"].contains(word)
        guard isHours || isMinutes else { return nil }
        // "an hour and a half"
        if isHours, index + 4 < words.count, words[index + 2] == "and", words[index + 3] == "a", words[index + 4] == "half" {
            number += 0.5
            length = 5
        }
        return (Int(isHours ? number * 60 : number), length)
    }

    private func parseRuntime(_ words: [String], into query: inout DescribeItQuery, consumed: inout Set<Int>) {
        let below: Set<String> = ["under", "below", "shorter", "max", "most", "within", "less", "lesser", "up"]
        let above: Set<String> = ["over", "above", "longer", "least", "more"]
        for index in words.indices where !consumed.contains(index) {
            var start = index + 1
            // "less than", "more than", "at most", "at least", "up to"
            if start < words.count, ["than", "to"].contains(words[start]) { start += 1 }
            guard let found = duration(words, at: start) else { continue }
            if below.contains(words[index]) {
                query.maxMinutes = found.minutes
            } else if above.contains(words[index]) {
                query.minMinutes = found.minutes
            } else {
                continue
            }
            consumed.formUnion(index..<(start + found.length))
        }
        // "a 90 minute movie": about that long.
        for index in words.indices where !consumed.contains(index) {
            guard let found = duration(words, at: index), Double(words[index]) != nil else { continue }
            query.maxMinutes = query.maxMinutes ?? found.minutes + 10
            consumed.formUnion(index..<(index + found.length))
        }
        let joined = " " + words.joined(separator: " ") + " "
        let movie = kind == .movie
        let tooLong = joined.contains(" too long ") || joined.contains(" not long ")
        if query.maxMinutes == nil {
            if tooLong {
                query.maxMinutes = movie ? 120 : 45
            } else if [" short ", " quick ", " brief "].contains(where: joined.contains) {
                query.maxMinutes = movie ? 95 : 30
            }
        }
        if query.minMinutes == nil, !tooLong, [" long ", " lengthy "].contains(where: joined.contains) {
            query.minMinutes = movie ? 140 : 50
        }
    }

    // MARK: Scores

    private func parseScores(_ words: [String], into query: inout DescribeItQuery, consumed: inout Set<Int>) {
        let sources: [String: String] = [
            "imdb": "imdb", "rt": "critics", "rotten": "critics", "tomatoes": "critics", "tomatometer": "critics",
            "critics": "critics", "critic": "critics", "audience": "audience", "audiences": "audience",
        ]
        for index in words.indices where !consumed.contains(index) {
            guard let number = Self.score(words[index]) else { continue }
            // The nearest source within four words: "8 on imdb", "imdb 7+",
            // "90% rt", "rated 8 or higher on imdb".
            let window = max(0, index - 4)...min(words.count - 1, index + 4)
            guard let sourceIndex = window.filter({ sources[words[$0]] != nil })
                .min(by: { abs($0 - index) < abs($1 - index) }),
                  let source = sources[words[sourceIndex]] else { continue }
            switch source {
            case "imdb":
                guard number <= 10 else { continue }
                query.minimums.imdb = number
            case "audience":
                query.minimums.audience = number <= 10 ? number * 10 : number
            default:
                query.minimums.critics = number <= 10 ? number * 10 : number
            }
            consumed.formUnion(min(index, sourceIndex)...max(index, sourceIndex))
            consumed.formUnion(window.filter { sources[words[$0]] != nil })
            var back = index - 1
            while back >= 0, ["over", "above", "at", "least", "more", "than", "higher", "better", "rated"].contains(words[back]) {
                consumed.insert(back)
                back -= 1
            }
        }
    }

    /// "8", "8.5", "7+", "90%".
    private static func score(_ word: String) -> Double? {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "%+"))
        guard let value = Double(trimmed), value > 0, value <= 100 else { return nil }
        return value
    }

    // MARK: Years

    private func parseYears(_ words: [String], into query: inout DescribeItQuery, consumed: inout Set<Int>) {
        let decadeWords: [String: Int] = [
            "twenties": 1920, "thirties": 1930, "forties": 1940, "fifties": 1950, "sixties": 1960,
            "seventies": 1970, "eighties": 1980, "nineties": 1990, "2000s": 2000, "2010s": 2010, "2020s": 2020,
        ]
        for (index, word) in words.enumerated() where !consumed.contains(index) {
            var decade: Int?
            if let start = decadeWords[word] {
                decade = start
            } else if let match = word.firstMatch(of: /^(19|20)?(\d)0s$/) {
                let digit = Int(match.2) ?? 0
                // "20s" and earlier is this century, "30s" on the last one.
                let century = match.1.flatMap { Int($0) } ?? (digit <= 2 ? 20 : 19)
                decade = century * 100 + digit * 10
            }
            if let decade {
                var range = decade...(decade + 9)
                if index > 0 {
                    switch words[index - 1] {
                    case "early": range = decade...(decade + 3)
                    case "mid": range = (decade + 3)...(decade + 6)
                    case "late": range = (decade + 6)...(decade + 9)
                    default: break
                    }
                }
                query.years = query.years.map { min($0.lowerBound, range.lowerBound)...max($0.upperBound, range.upperBound) } ?? range
                consumed.insert(index)
                continue
            }
            guard word.count == 4, let year = Int(word), (1900...currentYear + 1).contains(year) else { continue }
            let previous = index > 0 ? words[index - 1] : ""
            switch previous {
            case "before", "pre", "until":
                query.years = 1900...(year - 1)
            case "after", "post":
                query.years = (year + 1)...currentYear
            case "since":
                query.years = year...currentYear
            default:
                if index + 2 < words.count, words[index + 1] == "and" || words[index + 1] == "to",
                   let end = Int(words[index + 2]), (year...currentYear + 1).contains(end) {
                    query.years = year...end
                    consumed.formUnion(index...(index + 2))
                    continue
                }
                query.years = year...year
            }
            consumed.insert(index)
        }
        guard query.years == nil else { return }
        let joined = " " + words.joined(separator: " ") + " "
        if joined.contains(" silent ") {
            query.years = 1900...1929
        } else if joined.contains(" black and white ") {
            query.years = 1900...1960
        } else if [" old ", " older ", " classic ", " classics ", " vintage ", " golden age "].contains(where: joined.contains) {
            query.years = 1900...1979
        } else if joined.contains(" this year ") {
            query.years = currentYear...currentYear
        } else if joined.contains(" last year ") {
            query.years = (currentYear - 1)...(currentYear - 1)
        } else if [" new ", " newer ", " recent ", " latest ", " just came out "].contains(where: joined.contains) {
            query.years = (currentYear - 3)...currentYear
        } else if joined.contains(" modern ") {
            query.years = 2000...currentYear
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
