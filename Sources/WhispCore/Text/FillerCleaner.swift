import Foundation

/// Subtractive, rules-only cleanup. It never rephrases: it only removes
///
/// - hesitation sounds anywhere ("um", "uh", "erm", "hmm"),
/// - "like" / "you know" / "I mean" when set off by commas ("It was, like, huge"),
/// - immediate stutters ("I I think", "the, the") except intentional doubles
///   ("that that", "had had", "no no", "very very"),
///
/// then repairs the punctuation/capitalization it disturbed, writes clock times with a
/// colon ("at 5.30" -> "at 5:30"), and applies the personal dictionary.
public final class FillerCleaner: TextCleaning {

    private let dictionary: PersonalDictionary?

    public init(dictionary: PersonalDictionary? = nil) {
        self.dictionary = dictionary
    }

    public func clean(_ raw: String) -> String {
        var tokens = raw.split(whereSeparator: \.isWhitespace).map { Token(String($0)) }
        removeHesitations(&tokens)
        removeParentheticalFillers(&tokens)
        removeStutters(&tokens)
        let text = Self.fixClockTimes(tokens.map(\.text).joined(separator: " "))
        return dictionary?.apply(text) ?? text
    }

    /// Parakeet writes "five thirty" as "5.30". Use a colon when the context says it's a
    /// clock time: followed by am/pm, or after at/by/until/… ("version 2.45" is untouched).
    private static let clockTimeRules: [(NSRegularExpression, String)] = [
        (#"(?<![\d.])(1[0-2]|0?[1-9])\.([0-5]\d)(?=\s*[ap]\.?m\b)"#, "$1:$2"),
        (#"\b(at|by|until|till|around|from|before|after) (1[0-2]|0?[1-9])\.([0-5]\d)(?!\.?\d)"#, "$1 $2:$3"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }

    private static func fixClockTimes(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = text
        for (regex, template) in clockTimeRules {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    // MARK: - Word lists

    private static let hesitations: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "erm", "hmm", "hmmm", "hm", "mmm",
    ]

    // "er" and "mm" are left out on purpose: "the ER", "5 mm".

    /// Removed only when fenced by commas / sentence boundaries.
    private static let parentheticals: [[String]] = [["you", "know"], ["i", "mean"], ["like"]]

    /// Words people deliberately double.
    private static let intentionalDoubles: Set<String> = [
        "that", "had", "is", "no", "very", "really", "so", "bye", "yeah", "yes", "okay", "ok", "oh",
        "ha", "haha", "hey", "go", "well", "please", "more", "again", "too", "many", "much", "blah",
        "knock", "now", "wait", "come", "there", "far", "long", "over", "round", "up", "down", "wow",
        "tick", "tock", "cha", "boo", "choo", "yay", "hip", "bang", "night", "done", "fine", "sure",
    ]

    /// Sentence-initial lead-ins whose comma survives when a following filler is removed ("So, um, we" -> "So, we").
    private static let leadIns: Set<String> = [
        "so", "well", "yes", "yeah", "no", "okay", "ok", "oh", "right", "now", "anyway", "actually",
        "also", "first", "second", "then", "hey", "hi", "hello", "alright", "honestly", "basically",
    ]

    // MARK: - Passes

    private func removeHesitations(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            if Self.hesitations.contains(tokens[i].word) {
                remove(&tokens, i..<(i + 1), requireFence: false)
            } else {
                i += 1
            }
        }
    }

    private func removeParentheticalFillers(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            guard let phrase = Self.parentheticals.first(where: { matches($0, in: tokens, at: i) }) else {
                i += 1
                continue
            }
            let range = i..<(i + phrase.count)
            if isFenced(range, in: tokens) {
                remove(&tokens, range, requireFence: true)
            } else {
                i += 1
            }
        }
    }

    private func removeStutters(_ tokens: inout [Token]) {
        var i = 1
        while i < tokens.count {
            let prev = tokens[i - 1], cur = tokens[i]
            let separable = prev.trailing.isEmpty || prev.trailing == ","
            if separable, !cur.word.isEmpty, cur.leading.isEmpty, prev.leading.isEmpty,
               cur.word == prev.word, !Self.intentionalDoubles.contains(cur.word) {
                // Keep the second copy's punctuation, the first copy's casing.
                tokens[i] = Token(leading: "", core: prev.core, trailing: cur.trailing)
                tokens.remove(at: i - 1)
            } else {
                i += 1
            }
        }
    }

    // MARK: - Removal with punctuation repair

    /// A phrase is fenced when it's bounded on the left by a comma or sentence start, and on
    /// the right by a comma, or by sentence end when the left side is a comma.
    private func isFenced(_ range: Range<Int>, in tokens: [Token]) -> Bool {
        guard tokens[range].dropLast().allSatisfy({ $0.trailing.isEmpty }),
              tokens[range].allSatisfy({ $0.leading.isEmpty }) else { return false }
        let prev = range.lowerBound > 0 ? tokens[range.lowerBound - 1] : nil
        let last = tokens[range.upperBound - 1]
        let leftComma = prev?.trailing == ","
        let atStart = prev == nil || prev!.endsSentence
        if last.trailing == "," { return leftComma || atStart }
        if last.endsSentence { return leftComma }
        return false
    }

    private func remove(_ tokens: inout [Token], _ range: Range<Int>, requireFence: Bool) {
        let first = tokens[range.lowerBound]
        let last = tokens[range.upperBound - 1]
        let prevIndex = range.lowerBound > 0 ? range.lowerBound - 1 : nil
        let atSentenceStart = prevIndex.map { tokens[$0].endsSentence } ?? true
        let wasCapitalized = first.core.first?.isUppercase == true

        if last.endsSentence, let p = prevIndex, !tokens[p].endsSentence {
            // "I think, um." -> "I think."
            tokens[p].trailing = String(tokens[p].trailing.drop(while: { $0 == "," })) + last.trailing
        } else if !last.endsSentence, let p = prevIndex, tokens[p].trailing == ",",
                  last.trailing == "," || requireFence,
                  !(Self.leadIns.contains(tokens[p].word) && (p == 0 || tokens[p - 1].endsSentence)) {
            // "I was, uh, going" -> "I was going"
            tokens[p].trailing = ""
        }

        tokens.removeSubrange(range)

        if atSentenceStart, wasCapitalized, range.lowerBound < tokens.count {
            tokens[range.lowerBound].capitalizeFirst()
        }
    }

    private func matches(_ phrase: [String], in tokens: [Token], at i: Int) -> Bool {
        guard i + phrase.count <= tokens.count else { return false }
        return phrase.indices.allSatisfy { tokens[i + $0].word == phrase[$0] }
    }
}

// MARK: - Token

/// A whitespace-delimited word split into leading punctuation, core, and trailing punctuation.
private struct Token {
    var leading: String
    var core: String
    var trailing: String

    init(leading: String, core: String, trailing: String) {
        self.leading = leading
        self.core = core
        self.trailing = trailing
    }

    init(_ raw: String) {
        let isWordChar: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        guard let start = raw.firstIndex(where: isWordChar),
              let end = raw.lastIndex(where: isWordChar) else {
            self.init(leading: "", core: "", trailing: raw)
            return
        }
        self.init(leading: String(raw[..<start]),
                  core: String(raw[start...end]),
                  trailing: String(raw[raw.index(after: end)...]))
    }

    var text: String { leading + core + trailing }
    var word: String { core.lowercased() }
    var endsSentence: Bool { trailing.contains { ".?!".contains($0) } }

    mutating func capitalizeFirst() {
        guard let f = core.first, f.isLowercase else { return }
        core = f.uppercased() + core.dropFirst()
    }
}
