import Foundation

/// Additive, rules-only formatting: it changes how the words are written, never which
/// words they are. No model, no network — three passes over the tokens of one take, so
/// a five minute dictation costs a fraction of a millisecond.
///
/// - spoken file paths are joined ("src slash main dot swift" -> "src/main.swift"),
/// - numbers of twenty and up are written in digits, with money and percentages
///   ("twenty five dollars" -> "$25", "twenty five percent" -> "25%"), and spoken
///   clock times ("at five thirty" -> "at 5:30"),
/// - each sentence gets a closing stop and a capital letter, sentences that open like
///   questions get a question mark, and a short list of openers gets its comma
///   ("Yes I do" -> "Yes, I do").
///
/// Where it stops, on purpose: a number under twenty stays a word, because "five
/// minutes" reads better than "5 minutes" and "one thing" must never become "1 thing";
/// a bare hour stays a word ("meet me at five") because "at one point" would become
/// "at 1 point"; a lone "hundred" stays a word ("a hundred times"); "star" is not
/// rewritten as "*"; and a separator word doing its job as a verb ("we slash prices")
/// is left alone.
public final class TextFormatter: TextFormatting {

    public init() {}

    public func format(_ text: String) -> String {
        var tokens = text.split(whereSeparator: \.isWhitespace).map { Token(String($0)) }
        guard !tokens.isEmpty else { return "" }
        joinPaths(&tokens)
        writeNumbers(&tokens)
        punctuate(&tokens)
        return tokens.map(\.text).joined(separator: " ")
    }

    // MARK: - Spoken file paths

    private static let pathEndings: Set<String> = [
        "swift", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "java", "kt", "c", "h",
        "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "json", "yaml",
        "yml", "toml", "xml", "html", "htm", "css", "scss", "sass", "md", "txt", "rtf",
        "csv", "tsv", "sql", "log", "lock", "env", "plist", "pdf", "png", "jpg", "jpeg",
        "gif", "svg", "webp", "wav", "mp3", "mp4", "mov", "zip", "gz", "tar", "dmg",
        "ipa", "apk", "xlsx", "docx", "pptx", "key", "pages",
        "com", "org", "net", "io", "dev", "app", "co", "ai",
    ]

    /// Words that are never part of a path. Without them "we slash prices" would
    /// become "we/prices".
    private static let notPathWords: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "we", "you", "they", "he", "she", "it",
        "the", "a", "an", "this", "that", "these", "those", "our", "my", "your", "their",
        "his", "her", "its", "is", "are", "was", "were", "be", "been", "being", "am",
        "do", "does", "did", "done", "can", "could", "will", "would", "should", "shall",
        "may", "might", "must", "not", "no", "yes", "ok", "okay", "and", "or", "but",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "as", "if", "then",
        "than", "so", "just", "like", "about", "into", "onto", "over", "under", "after",
        "before", "up", "down", "out", "off", "all", "any", "some", "every", "each",
        "there", "here", "what", "which", "who", "whom", "whose", "when", "where", "why",
        "how", "also", "very", "really", "more", "most", "less", "least", "only", "same",
        "other", "another", "both", "few", "many", "much",
    ]

    /// A word that can stand on either side of a spoken path separator: no leading
    /// punctuation, and no trailing punctuation unless it ends the take.
    private static let separatorWords: Set<String> = ["slash", "backslash", "dot", "underscore", "forward"]

    private static func isPathWord(_ token: Token) -> Bool {
        guard token.leading.isEmpty, !token.core.isEmpty,
              !separatorWords.contains(token.word) else { return false }
        for ch in token.core where !(ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ".") {
            return false
        }
        return token.trailing.isEmpty || token.trailing.contains(where: { ".?!,;:".contains($0) })
    }

    /// The spoken separator at `index`, with the punctuation it stands for and how
    /// many words it takes ("forward slash" is two).
    private static func separator(in tokens: [Token], at index: Int)
        -> (text: String, isSlash: Bool, length: Int)? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        guard token.leading.isEmpty, token.trailing.isEmpty else { return nil }
        switch token.word {
        case "slash", "backslash": return ("/", true, 1)
        case "dot": return (".", false, 1)
        case "underscore": return ("_", false, 1)
        case "forward":
            guard index + 1 < tokens.count, tokens[index + 1].word == "slash",
                  tokens[index + 1].leading.isEmpty, tokens[index + 1].trailing.isEmpty
            else { return nil }
            return ("/", true, 2)
        default: return nil
        }
    }

    private struct PathRun {
        var start: Int
        var end: Int
        var lastPart: Int
        var separators: Int
        var hasSlash: Bool
        var startsWithSeparator: Bool
        var wordBeforeFirstSeparator: String?
    }

    /// The run of tokens at `start` that spells a path, or nil when they are really
    /// ordinary words. Conservative: a separator only joins when the result is a path
    /// somebody recognises, so "we slash prices" and "a dot of paint" stay words.
    private static func pathRun(in tokens: [Token], at start: Int) -> PathRun? {
        // "we slash prices slash costs" is three words and two verbs, not a path: a
        // run never starts right after a separator word.
        if start > 0, separator(in: tokens, at: start - 1) != nil { return nil }
        var run = PathRun(start: start, end: start, lastPart: start, separators: 0,
                          hasSlash: false, startsWithSeparator: false,
                          wordBeforeFirstSeparator: nil)
        var cursor: Int
        if let sep = separator(in: tokens, at: start) {
            // ".env", ".gitignore": a dot with only a known ending behind it, and only
            // at the start of a sentence. In the middle of one, "package dot json" and
            // "Edit dot env" are told apart by nothing a fixed rule can see.
            let part = start + sep.length
            guard start == 0 || tokens[start - 1].endsSentence,
                  sep.text == ".", part < tokens.count, isPathWord(tokens[part]),
                  pathEndings.contains(tokens[part].word) else { return nil }
            run.startsWithSeparator = true
            run.separators = 1
            run.lastPart = part
            run.end = part + 1
            cursor = part + 1
        } else {
            guard isPathWord(tokens[start]) else { return nil }
            run.lastPart = start
            run.end = start + 1
            cursor = start + 1
            if !tokens[start].trailing.isEmpty { return nil }
        }
        while let sep = separator(in: tokens, at: cursor) {
            let part = cursor + sep.length
            guard part < tokens.count, isPathWord(tokens[part]) else { break }
            if !run.startsWithSeparator, run.separators == 0 {
                run.wordBeforeFirstSeparator = tokens[cursor - 1].word
            }
            run.separators += 1
            if sep.isSlash { run.hasSlash = true }
            run.lastPart = part
            run.end = part + 1
            cursor = part + 1
            // A part that carries punctuation ends the sentence, so nothing follows it.
            if !tokens[part].trailing.isEmpty { break }
        }
        guard run.separators > 0 else { return nil }
        // Two separators ("src slash main dot swift", "www dot example dot com") or a
        // slash ("src slash components") join. One spoken "dot" on its own does not:
        // "package dot json" and "Edit dot env" look the same to a fixed rule, and a
        // wrong join is worse than a left-alone dot. A dot-file at the start of a run
        // ("dot env" -> ".env") is handled above, where nothing can be mistaken for a
        // path in front of it.
        guard run.separators >= 2 || run.hasSlash || run.startsWithSeparator else { return nil }
        if let left = run.wordBeforeFirstSeparator, notPathWords.contains(left) { return nil }
        if !run.startsWithSeparator {
            var index = start
            while index < run.end {
                if separator(in: tokens, at: index) == nil, notPathWords.contains(tokens[index].word) {
                    return nil
                }
                index += 1
            }
        }
        return run
    }

    private static func path(_ run: PathRun, in tokens: [Token]) -> String {
        var out = ""
        var index = run.start
        while index < run.end {
            if let sep = separator(in: tokens, at: index) {
                out += sep.text
                index += sep.length
            } else {
                out += tokens[index].core
                index += 1
            }
        }
        return out
    }

    private func joinPaths(_ tokens: inout [Token]) {
        var start = 0
        while start < tokens.count {
            guard let run = Self.pathRun(in: tokens, at: start) else {
                start += 1
                continue
            }
            var token = tokens[start]
            token.leading = ""
            token.core = Self.path(run, in: tokens)
            token.trailing = tokens[run.lastPart].trailing
            tokens.replaceSubrange(start..<run.end, with: [token])
            start += 1
        }
    }

    // MARK: - Numbers

    private static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
        "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90, "hundredth": 100, "thousandth": 1000,
        "millionth": 1_000_000,
    ]

    private struct NumberRun {
        var value: Int
        var count: Int
        var ordinal: Bool
    }

    /// The number a run of number words spells, or nil when they are not one number
    /// ("five six" is two words, not 56).
    private static func numberRun(in tokens: [Token], at start: Int) -> NumberRun? {
        var total = 0
        var current = 0
        var count = 0
        var last = ""
        var ordinal = false
        while start + count < tokens.count {
            let token = tokens[start + count]
            guard token.leading.isEmpty else { break }
            if token.word == "and", last == "scale" {
                count += 1
                last = "and"
                continue
            }
            let kind: String
            let value: Int
            if let found = ones[token.word] {
                kind = "unit"
                value = found
            } else if let found = tens[token.word] {
                kind = "tens"
                value = found
            } else if let found = scales[token.word] {
                kind = "scale"
                value = found
            } else if let found = ordinals[token.word] {
                kind = found < 20 ? "unit" : (found < 100 ? "tens" : "scale")
                value = found
                ordinal = true
            } else {
                break
            }
            if count > 0 {
                // "twenty five" is 25, "five twenty" is not 25, and "twenty
                // nineteen" is a year, not 39.
                if kind == "unit", last == "unit" { break }
                if kind == "unit", last == "tens", value >= 10 { break }
                if kind == "tens", last == "unit" || last == "tens" { break }
            }
            if kind == "scale", value == 100 {
                current = max(current, 1) * value
            } else if kind == "scale" {
                total += max(current, 1) * value
                current = 0
            } else {
                current += value
            }
            count += 1
            last = kind
            // Only the last number word of a run can be an ordinal ("twenty fifth").
            if ordinal { break }
        }
        guard count > 0 else { return nil }
        return NumberRun(value: total + current, count: count, ordinal: ordinal)
    }

    private static func isNumberWord(_ word: String) -> Bool {
        ones[word] != nil || tens[word] != nil || scales[word] != nil || ordinals[word] != nil
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        switch value % 100 {
        case 11, 12, 13: return "th"
        default:
            switch value % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }
    }

    /// The digits for a run, or nil when the words read better left alone.
    private static func digits(for run: NumberRun) -> String? {
        // A number under twenty stays a word: "five minutes" beats "5 minutes", and
        // "one thing" must never become "1 thing". A lone "hundred" stays a word too:
        // "I've told you a hundred times".
        if run.count == 1, run.value < 20 || scales.values.contains(run.value) { return nil }
        if run.ordinal { return "\(run.value)\(ordinalSuffix(run.value))" }
        return String(run.value)
    }

    /// Money words and "percent" belong to the number in front of them.
    private static func absorbed(after run: NumberRun, in tokens: [Token], at start: Int)
        -> (prefix: String, suffix: String, count: Int) {
        let next = start + run.count
        guard next < tokens.count else { return ("", "", 0) }
        let word = tokens[next].word
        // The money word may be the last word of the take; its punctuation moves to
        // the number ("It costs fifty bucks." -> "It costs $50.").
        if ["dollars", "dollar", "bucks", "buck"].contains(word), tokens[next].leading.isEmpty {
            return ("$", "", 1)
        }
        if word == "percent", tokens[next].leading.isEmpty {
            return ("", "%", 1)
        }
        if word == "per", next + 1 < tokens.count, tokens[next + 1].word == "cent",
           tokens[next + 1].leading.isEmpty {
            return ("", "%", 2)
        }
        return ("", "", 0)
    }

    // MARK: - Clock times

    private static let clockPrepositions: Set<String> = [
        "at", "by", "around", "from", "before", "after", "until", "till", "past", "about",
    ]
    private static let minuteTens: [String: Int] = [
        "ten": 10, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    ]

    /// "at five thirty" -> (5:30, 2 words). Only after a clock preposition ("at one
    /// point" must stay words) and only with an hour and a minute, so a bare "at five"
    /// is left alone.
    private static func clockTime(in tokens: [Token], at start: Int) -> (text: String, count: Int)? {
        guard start + 1 < tokens.count, tokens[start].leading.isEmpty else { return nil }
        let spoken = start > 0 ? tokens[start - 1].word : ""
        guard clockPrepositions.contains(spoken) else { return nil }
        guard let hour = ones[tokens[start].word], hour >= 1, hour <= 12 else { return nil }
        let minuteToken = tokens[start + 1]
        guard minuteToken.leading.isEmpty else { return nil }
        var minute = 0
        var count = 1
        if minuteToken.word == "oh", start + 2 < tokens.count,
           let unit = ones[tokens[start + 2].word], unit < 10 {
            minute = unit
            count = 2
        } else if let found = minuteTens[minuteToken.word] {
            minute = found
            if start + 2 < tokens.count, tokens[start + 2].leading.isEmpty,
               let unit = ones[tokens[start + 2].word], unit < 10 {
                minute += unit
                count = 2
            }
        } else if let found = ones[minuteToken.word], found >= 10 {
            minute = found
        } else {
            return nil
        }
        // The minute has to be complete: another number word means it was not a time.
        let after = start + 1 + count
        if after < tokens.count, ones[tokens[after].word] != nil || tens[tokens[after].word] != nil
            || scales[tokens[after].word] != nil {
            return nil
        }
        return ("\(hour):" + (minute < 10 ? "0\(minute)" : "\(minute)"), 1 + count)
    }

    private func writeNumbers(_ tokens: inout [Token]) {
        var start = 0
        while start < tokens.count {
            if let clock = Self.clockTime(in: tokens, at: start) {
                var token = tokens[start]
                token.leading = ""
                token.core = clock.text
                token.trailing = tokens[start + clock.count - 1].trailing
                tokens.replaceSubrange(start..<(start + clock.count), with: [token])
                start += 1
                continue
            }
            guard let run = Self.numberRun(in: tokens, at: start),
                  var written = Self.digits(for: run) else {
                start += 1
                continue
            }
            // A number word touching the run on either side means the speaker said a
            // year or a price the way people do ("twenty nineteen", "two fifty",
            // "twenty twenty four"). Half a reading would write a wrong number, so
            // leave all of it as words.
            let before = start > 0 ? tokens[start - 1].word : ""
            let after = start + run.count < tokens.count ? tokens[start + run.count].word : ""
            guard !Self.isNumberWord(before), !Self.isNumberWord(after) else {
                start += 1
                continue
            }
            let absorbed = Self.absorbed(after: run, in: tokens, at: start)
            if written.first?.isNumber == true { written = absorbed.prefix + written + absorbed.suffix }
            var token = tokens[start]
            token.leading = ""
            token.core = written
            token.trailing = tokens[start + run.count + absorbed.count - 1].trailing
            tokens.replaceSubrange(start..<(start + run.count + absorbed.count), with: [token])
            start += 1
        }
    }

    // MARK: - Punctuation

    /// Openers that take a comma when a sentence continues after them.
    private static let commasAfter: Set<String> = [
        "yes", "yeah", "yep", "nope", "no", "okay", "ok", "alright", "sure", "well", "hey",
        "hi", "hello", "thanks", "sorry", "actually", "honestly", "anyway", "basically",
    ]

    /// What a comma-taking opener is followed by when the comma belongs there.
    private static let commaBefore: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "we", "we're", "we'll", "you", "you're",
        "they", "they're", "he", "he's", "she", "she's", "it", "it's", "this", "that",
        "these", "those", "the", "a", "an", "my", "our", "your", "their", "his", "her",
        "its", "there", "let's", "here's", "everyone", "everybody",
    ]

    /// Words that open a question.
    private static let questionAuxiliaries: Set<String> = [
        "do", "does", "did", "is", "are", "was", "were", "can", "could", "would", "should",
        "will", "shall", "may", "might", "have", "has", "had", "am", "isn't", "aren't",
        "wasn't", "weren't", "don't", "doesn't", "didn't", "can't", "couldn't",
        "wouldn't", "shouldn't", "won't", "haven't", "hasn't", "hadn't",
    ]
    private static let questionWh: Set<String> = [
        "what", "where", "when", "why", "how", "who", "whom", "which", "whose",
    ]
    private static let questionSubjects: Set<String> = [
        "i", "i'm", "you", "you're", "we", "we're", "they", "they're", "he", "she", "it",
        "there", "this", "that", "these", "those", "the", "a", "an", "my", "our", "your",
        "their", "his", "her", "anyone", "someone", "anybody", "everybody", "everyone",
    ]

    private func punctuate(_ tokens: inout [Token]) {
        guard !tokens.isEmpty else { return }
        addClosingStop(&tokens)
        capitalizeStarts(&tokens)
        addOpenerCommas(&tokens)
        addQuestionMarks(&tokens)
    }

    /// A take is a sentence: give it its closing stop when it has none.
    private func addClosingStop(_ tokens: inout [Token]) {
        let last = tokens.count - 1
        guard tokens.count >= 3, !tokens[last].core.isEmpty, !tokens[last].endsSentence else { return }
        var trailing = tokens[last].trailing
        let closers = ")]}\"'”’"
        if trailing.hasSuffix(",") || trailing.hasSuffix(":") || trailing.hasSuffix(";") {
            trailing.removeLast()
            trailing += "."
        } else if let closer = trailing.firstIndex(where: { closers.contains($0) }) {
            trailing.insert(".", at: closer)
        } else {
            trailing += "."
        }
        tokens[last].trailing = trailing
    }

    private func capitalizeStarts(_ tokens: inout [Token]) {
        capitalize(&tokens[0])
        for index in tokens.indices where index > 0 && tokens[index - 1].endsSentence {
            capitalize(&tokens[index])
        }
    }

    private func capitalize(_ token: inout Token) {
        // ".env" at the start of a take has no first letter to capitalize.
        guard !token.leading.hasSuffix(".") else { return }
        token.capitalizeFirst()
    }

    private func addOpenerCommas(_ tokens: inout [Token]) {
        for index in tokens.indices where index + 1 < tokens.count {
            let token = tokens[index]
            guard token.trailing.isEmpty, Self.commasAfter.contains(token.word) else { continue }
            guard index == 0 || tokens[index - 1].endsSentence else { continue }
            let next = tokens[index + 1]
            guard next.leading.isEmpty, Self.commaBefore.contains(next.word) else { continue }
            tokens[index].trailing = ","
        }
    }

    private func addQuestionMarks(_ tokens: inout [Token]) {
        var sentenceStart = 0
        for index in tokens.indices where tokens[index].endsSentence {
            if isQuestion(tokens, from: sentenceStart, to: index) {
                replaceFinalStop(&tokens[index])
            }
            sentenceStart = index + 1
        }
    }

    private static let tagWords: Set<String> = ["right", "okay", "ok", "correct", "yeah"]

    /// True when the sentence `from...to` opens like a question and closes with a stop,
    /// so it should be a question mark. Statements that merely start with one of these
    /// words ("Do not do that", "What is done is done") stay statements.
    private func isQuestion(_ tokens: [Token], from: Int, to: Int) -> Bool {
        guard from <= to, tokens[to].trailing.last == "." else { return false }
        let words = (from...to).map { tokens[$0].word }
        // "it's fine, right." -> "it's fine, right?"
        if to - from >= 1, Self.tagWords.contains(words[to - from]),
           tokens[to - 1].trailing == "," {
            return true
        }
        let first = words[0]
        let second = words.count > 1 ? words[1] : ""
        if Self.questionAuxiliaries.contains(first), Self.questionSubjects.contains(second) {
            return true
        }
        if Self.questionWh.contains(first), Self.questionAuxiliaries.contains(second) {
            let third = words.count > 2 ? words[2] : ""
            return Self.questionSubjects.contains(third)
        }
        return false
    }

    private func replaceFinalStop(_ token: inout Token) {
        var trailing = token.trailing
        guard let stop = trailing.lastIndex(where: { ".?!".contains($0) }) else { return }
        trailing.replaceSubrange(stop...stop, with: "?")
        token.trailing = trailing
    }
}
