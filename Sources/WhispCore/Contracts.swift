import Foundation

// Shared contracts between modules. Each module's concrete type conforms to one of these,
// and DictationController wires them together.

/// Speech-to-text engine. Input is 16 kHz mono Float32 PCM in [-1, 1].
public protocol Transcribing: AnyObject {
    /// Download (first run), load and warm up the model. Safe to call more than once.
    func prepare() async throws
    /// Returns the raw transcript (punctuated/capitalized by the model, no cleanup applied).
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Microphone capture. Always delivers 16 kHz mono Float32 samples.
public protocol AudioRecording: AnyObject {
    /// Normalized input level 0...1, called on the main thread ~30x/s while recording.
    var onLevel: ((Float) -> Void)? { get set }
    func start() throws
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
}

/// Global hotkey listener. Events are delivered on the main thread.
public protocol HotkeyMonitoring: AnyObject {
    var onEvent: ((HotkeyEvent) -> Void)? { get set }
    /// Throws HotkeyError.permissionDenied if Accessibility/Input Monitoring is not granted.
    func start() throws
    func stop()
}

public enum HotkeyError: Error {
    case permissionDenied
}

/// Inserts text into the frontmost app at the cursor.
public protocol TextPasting: AnyObject {
    func paste(_ text: String)
}

/// Non-rewriting cleanup: removes fillers/stutters and applies personal dictionary.
public protocol TextCleaning: AnyObject {
    func clean(_ raw: String) -> String
}
