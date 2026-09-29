import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Watches the span Whisp just pasted into and, once, later re-reads a narrow
/// window around it to learn the owner's manual corrections into
/// `dictionary.json`. Review triggers: the next dictation's key press, the
/// frontmost app changing, or a 90-second timer — whichever comes first.
///
/// Privacy rules: only the element Whisp pasted into is read, only a bounded
/// window around the paste, field contents are never logged or saved (only
/// the learned word pairs), and secure text fields are never touched.
public final class EditWatcher: CorrectionWatching {

    /// A paste worth reviewing: where it landed and what anchors it.
    /// @unchecked Sendable: AXUIElement is a CFType, safe to pass and time-boxed.
    struct Span: @unchecked Sendable {
        let pid: pid_t?
        let element: AXUIElement
        /// UTF-16 offset where the paste began (cursor location at release).
        let start: Int
        /// The exact text inserted (including any leading space).
        let text: String
        /// Up to 40 UTF-16 chars before the paste — the anchor.
        let beforeText: String
        let pastedAt: Date
    }

    /// How far before/after the span to read for the review window (UTF-16).
    nonisolated public static let windowBefore = 200
    nonisolated public static let windowAfter = 400
    /// Hard cap on every AX round-trip so a hung app can't stall the check.
    nonisolated static let axTimeout: Float = 0.02

    private let learner: CorrectionLearner
    private let pending: PendingCorrections
    private let dictionaryFile: URL
    private let isEnabled: () -> Bool
    private let logger = Logger(subsystem: "com.bishesha.whisp", category: "Learn")
    private var span: Span?
    private var checkTask: Task<Void, Never>?
    private var expiryTimer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    /// "Learned: soul → Sol" — shown in the menu with an Undo item.
    public private(set) var lastSummary: String?
    /// The decisions that produced `lastSummary`, so Undo can reverse them.
    private var lastApplied: [CorrectionLearner.Decision] = []

    public init(learner: CorrectionLearner, dictionaryFile: URL, pendingFile: URL,
                isEnabled: @escaping () -> Bool) {
        self.learner = learner
        self.dictionaryFile = dictionaryFile
        self.pending = PendingCorrections(fileURL: pendingFile)
        self.isEnabled = isEnabled
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPending() }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// The paste landed — remember the span and arm the 90 s fallback.
    /// Reads the element's subrole once; secure text fields are never watched.
    @MainActor
    public func record(_ context: FocusedContext, text: String, pid: pid_t?) {
        guard isEnabled(), !text.isEmpty else { return }
        var subrole: AnyObject?
        let secure = AXUIElementCopyAttributeValue(
            context.element, "AXSubrole" as CFString, &subrole) == .success
            && (subrole as? String) == "AXSecureTextField"
        guard !secure else { return }

        span = Span(pid: pid, element: context.element, start: context.cursorLocation,
                    text: text, beforeText: context.beforeText, pastedAt: Date())
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 90)
        timer.setEventHandler { [weak self] in self?.checkPending() }
        timer.resume()
        expiryTimer = timer
    }

    /// Next dictation beginning — review the previous paste now, off this call.
    @MainActor
    public func dictationStarting() {
        checkPending()
    }

    /// Whatever came first: consume the span and review it off the main actor.
    /// Silent by design — a dead element, a moved anchor, or a rewrite all end
    /// the review without side effects.
    @MainActor
    private func checkPending() {
        guard let span else { return }
        self.span = nil
        expiryTimer?.cancel()
        expiryTimer = nil
        checkTask?.cancel()
        let learner = self.learner, dictionaryFile = self.dictionaryFile
        checkTask = Task.detached(priority: .utility) { [weak self] in
            guard let window = Self.readWindow(around: span) else { return }
            // The anchor must appear exactly once — else we can't be sure which
            // occurrence the pasted text follows, so learn nothing.
            guard let range = Self.singleOccurrence(of: span.beforeText, in: window) else { return }
            let current = String(window[range.upperBound...])
            let rules = PersonalDictionary.loadPairs(fileURL: dictionaryFile)
            let decisions = learner.decide(pasted: span.text, current: current, existingRules: rules)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.apply(decisions)
            }
        }
    }

    // MARK: - Applying

    /// Writes each decision to dictionary.json / the pending file. Called on
    /// the main actor; file IO is tiny JSON so no queue is needed.
    @MainActor
    public func apply(_ decisions: [CorrectionLearner.Decision]) {
        let pending = self.pending
        var learned: [String] = []
        var applied: [CorrectionLearner.Decision] = []
        for decision in decisions {
            do {
                switch decision {
                case .term(let term):
                    try PersonalDictionary.addTerm(term, fileURL: dictionaryFile)
                    learned.append(term)
                    applied.append(decision)
                case .replacement(let from, let to):
                    try PersonalDictionary.addReplacement(from: from, to: to, fileURL: dictionaryFile)
                    learned.append("\(from) → \(to)")
                    applied.append(decision)
                case .pending(let from, let to, let kind):
                    let count = pending.record(from: from, to: to, kind: kind)
                    guard count >= 2 else { break }
                    pending.remove(from: from, to: to)
                    let promoted: CorrectionLearner.Decision =
                        kind == .term ? .term(to) : .replacement(from: from, to: to)
                    switch promoted {
                    case .term(let term):
                        try PersonalDictionary.addTerm(term, fileURL: dictionaryFile)
                        learned.append(term)
                    case .replacement:
                        try PersonalDictionary.addReplacement(from: from, to: to, fileURL: dictionaryFile)
                        learned.append("\(from) → \(to)")
                    default: break
                    }
                    applied.append(promoted)
                case .removed(let from, let to):
                    try PersonalDictionary.removeReplacement(from: from, to: to, fileURL: dictionaryFile)
                    learned.append("unlearned \(from) → \(to)")
                    applied.append(decision)
                }
            } catch {
                // An unparseable dictionary.json throws before writing — the file
                // is never clobbered, and learning simply skips this fix.
                logger.error("learn write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !learned.isEmpty {
            lastSummary = "Learned: " + learned.joined(separator: ", ")
            lastApplied = applied
        }
    }

    /// Reverses the most recent learned write (menu → Undo).
    @MainActor
    public func undoLast() {
        guard lastSummary != nil else { return }
        for decision in lastApplied {
            switch decision {
            case .term(let term):
                try? PersonalDictionary.removeTerm(term, fileURL: dictionaryFile)
            case .replacement(let from, let to):
                try? PersonalDictionary.removeReplacement(from: from, to: to, fileURL: dictionaryFile)
            case .removed(let from, let to):
                try? PersonalDictionary.addReplacement(from: from, to: to, fileURL: dictionaryFile)
            case .pending(let from, let to, _):
                pending.remove(from: from, to: to)
            }
        }
        lastSummary = nil
        lastApplied = []
    }

    // MARK: - AX read (detached)

    /// Reads the bounded window around the span via the parameterized
    /// string-for-range attribute. nil on any failure (dead element, hung app).
    nonisolated static func readWindow(around span: Span) -> String? {
        AXUIElementSetMessagingTimeout(span.element, axTimeout)
        var range = CFRange(
            location: max(0, span.start - windowBefore),
            length: windowBefore + span.text.utf16.count + windowAfter)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            span.element, kAXStringForRangeParameterizedAttribute as CFString,
            param, &value
        ) == .success else { return nil }
        return value as? String
    }

    /// Index range of the anchor when it occurs exactly once in `window`.
    /// An empty anchor (paste at document start) is still valid: it pins the
    /// review to the very start of the window.
    public nonisolated static func singleOccurrence(of anchor: String, in window: String) -> Range<String.Index>? {
        if anchor.isEmpty { return window.startIndex..<window.startIndex }
        var found: Range<String.Index>?
        var start = window.startIndex
        while let r = window.range(of: anchor, range: start..<window.endIndex) {
            if found != nil { return nil } // ambiguous
            found = r
            start = r.upperBound
        }
        return found
    }
}
