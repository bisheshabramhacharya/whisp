import AppKit
import Foundation

/// The one answer to "is this a real word" that the app uses everywhere.
///
/// `CorrectionLearner` is tested against this oracle, not a look-alike: the
/// production wiring in `Composition`, the test suite, and `whisp-learnprobe`
/// all build their learner here. A stub in the suite once made two rules look
/// correct that production cannot make, because production knows "Sol" and
/// "Claude" and the stub did not. One factory means a change to the oracle
/// changes what the tests measure at the same moment, and `swift run -c release
/// whisp-tests` fails instead of going quietly wrong.
public enum SpellCheckOracle {

    /// False when NSSpellChecker flags the word, which is the same judgement
    /// that underlines it in the app.
    public static let isKnownWord: (String) -> Bool = { word in
        NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }

    /// A learner wired to the app's own oracle.
    public static func learner() -> CorrectionLearner {
        CorrectionLearner(isKnownWord: isKnownWord)
    }
}
