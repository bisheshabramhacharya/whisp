import ApplicationServices
import Foundation

// Shared contracts between modules. Each module's concrete type conforms to one of these,
// and DictationController wires them together.

/// Speech-to-text engine. Input is 16 kHz mono Float32 PCM in [-1, 1].
public protocol Transcribing: AnyObject {
    /// Download (first run), load and warm up the model. Safe to call more than once.
    func prepare() async throws
    /// Returns the raw transcript (punctuated/capitalized by the model, no cleanup applied).
    func transcribe(_ samples: [Float]) async throws -> String
    /// Wakes the model ahead of a decode, e.g. at key press after idle. Optional.
    func rewarm() async
    /// Called while recording with the length of audio a release decode would
    /// get now, so engines with several encoder sizes can wake the one that
    /// decode needs before the key comes up. Optional.
    func prewarm(forSamples samples: Int) async
}

public extension Transcribing {
    func rewarm() async {}
    func prewarm(forSamples samples: Int) async {}
}

/// Engine that can report human-readable model status ("Downloading…", "Ready").
/// Optional capability — engines opt in so the composition layer doesn't have to
/// know the concrete type.
public protocol StatusReporting: AnyObject {
    var onStatus: ((String) -> Void)? { get set }
}

/// Microphone capture. Always delivers 16 kHz mono Float32 samples.
public protocol AudioRecording: AnyObject {
    /// Normalized input level 0...1, called on the main thread ~30x/s while recording.
    var onLevel: ((Float) -> Void)? { get set }
    /// True when the input device went away mid-recording and capture could not resume,
    /// so the last `stop()` returned only the audio from before the device change.
    var lostInput: Bool { get }
    func start() throws
    /// Copy of the audio captured so far, from sample `start` on (empty when not recording).
    func samples(from start: Int) -> [Float]
    /// Stops capture and returns everything recorded since start().
    func stop() -> [Float]
    /// Stops capture and discards audio.
    func cancel()
}

public enum HotkeyEvent: Sendable {
    /// Begin recording (Right Option pressed, or hands-free mode entered).
    case start
    /// Finish recording and transcribe (Right Option released, or hands-free mode ended).
    case stop
    /// Abort without transcribing (Esc, or Right Option used as part of another shortcut).
    case cancel
    /// A second short tap released into hands-free recording.
    case handsFree
}

/// Global hotkey listener. Events are delivered on the main thread.
public protocol HotkeyMonitoring: AnyObject {
    var onEvent: ((HotkeyEvent) -> Void)? { get set }
    /// Throws HotkeyError.permissionDenied if Accessibility/Input Monitoring is not granted.
    func start() throws
    func stop()
    /// Drops held-key state without stopping the listener — used after
    /// sleep/lock/user-switch, where a key-up can be lost and a key still
    /// physically down would otherwise look stuck.
    func reset()
}

public enum HotkeyError: Error {
    case permissionDenied
}

/// The focused text element at key release: the one time-boxed AX lookup that
/// serves the leading-space heuristic (preceding), and — for auto-learn —
/// the element + cursor + ~40 chars of anchor text before it.
public struct FocusedContext: @unchecked Sendable { // AXUIElement is a CFType
    public let element: AXUIElement
    /// UTF-16 offset of the insertion point (where the paste will land).
    public let cursorLocation: Int
    /// Character immediately before the cursor.
    public let preceding: Character?
    /// Up to 40 UTF-16 characters of text before the cursor (the anchor).
    public let beforeText: String

    public init(element: AXUIElement, cursorLocation: Int, preceding: Character?, beforeText: String) {
        self.element = element
        self.cursorLocation = cursorLocation
        self.preceding = preceding
        self.beforeText = beforeText
    }
}

/// Where a dictation should land, captured at key release.
public struct PasteTarget: Sendable {
    /// Frontmost app at key release.
    public let pid: pid_t?
    /// The focused-element lookup running in the background so the
    /// Accessibility round-trips overlap transcription instead of delaying
    /// the paste.
    public let focused: Task<FocusedContext?, Never>
    /// Character before the cursor, derived from `focused`.
    public let precedingCharacter: Task<Character?, Never>
    /// General-pasteboard contents captured at key release, off the main thread, so
    /// the restore snapshot doesn't have to wait on the pasteboard server at paste time.
    public let clipboard: Task<ClipboardCapture, Never>?

    public init(pid: pid_t?, focused: Task<FocusedContext?, Never>,
                clipboard: Task<ClipboardCapture, Never>? = nil) {
        self.pid = pid
        self.focused = focused
        self.precedingCharacter = Task { await focused.value?.preceding }
        self.clipboard = clipboard
    }

    /// For fakes and callers that only care about the preceding character.
    public init(pid: pid_t?, precedingCharacter: Task<Character?, Never>,
                clipboard: Task<ClipboardCapture, Never>? = nil) {
        self.pid = pid
        self.focused = Task { nil }
        self.precedingCharacter = precedingCharacter
        self.clipboard = clipboard
    }
}

public enum PasteResult: Sendable {
    case pasted
    /// Focus moved to another app while transcribing; the text was left on the clipboard.
    case copiedAppChanged
    /// The Mac slept, locked, or switched users before paste time; the text was
    /// left on the clipboard because the target session was gone.
    case copiedSessionInterrupt
}

/// Inserts text into the frontmost app at the cursor.
@MainActor
public protocol TextPasting: AnyObject {
    /// Call at key release.
    func target() -> PasteTarget
    func paste(_ text: String, into target: PasteTarget) async -> PasteResult
    /// Leaves text on the clipboard without posting keystrokes — for takes
    /// whose target is gone by definition (sleep/lock/user-switch).
    func copy(_ text: String) -> PasteResult
}

/// Non-rewriting cleanup: removes fillers/stutters and applies personal dictionary.
public protocol TextCleaning: AnyObject {
    func clean(_ raw: String) -> String
}
