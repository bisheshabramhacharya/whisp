import AppKit
import SwiftUI
import WhispCore

/// Render the real views without recording, requesting permissions, or starting hotkeys.
@MainActor
func renderDesignPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "whisp-design-preview-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let model = OnboardingModel(permissions: PreviewPermissions())
    try checkOnboardingGates(model)
    try checkMicrophoneLifecycle()
    try checkEditors()
    let examples: [(String, Int, Bool, String, String)] = [
        ("01-welcome", 0, false, "Loading model…", ""),
        ("02-privacy", 1, false, "Loading model…", ""),
        ("03-permissions", 2, false, "Loading model…", ""),
        ("03-permissions-ready", 2, true, "Ready", ""),
        ("04-model-loading", 3, true, "Downloading model…", ""),
        ("04-model-failure", 3, true, "Model failed: No internet connection", ""),
        ("04-model-ready", 3, true, "Ready", ""),
        ("05-microphone", 4, true, "Ready", ""),
        ("05-microphone-ready", 4, true, "Ready", ""),
        ("06-dictation", 5, true, "Ready", ""),
        ("07-practice", 6, true, "Ready", ""),
        ("07-practice-success", 6, true, "Ready", "Hi Alex, let's meet tomorrow at three."),
        ("08-ready", 7, true, "Ready", "Hi Alex, let's meet tomorrow at three."),
    ]
    for (name, step, granted, status, text) in examples {
        model.microphoneGranted = granted
        model.accessibilityGranted = granted
        model.inputMonitoringGranted = granted
        model.modelStatus = status
        model.dictatedText = text
        model.microphoneConfirmed = step > 4 || name == "05-microphone-ready"
        model.microphoneLevel = name == "05-microphone-ready" ? 0.7 : 0
        let view = OnboardingView(model: model, settings: settings, onGrantRequested: {},
            onFinish: {}, onRetryModel: {}, step: step, practiceText: text)
        let hosting = NSHostingView(rootView: view)
        try render(hosting, size: NSSize(width: 1000, height: 650), to: directory.appendingPathComponent(name + ".png"))
    }
    for (name, mode, locked) in [("pill-idle", PillView.Mode.idle, false), ("pill-recording", .recording, false), ("pill-locked", .recording, true), ("pill-transcribing", .transcribing, true)] {
        let pill = PillView(frame: NSRect(x: 0, y: 0, width: 135, height: 38))
        pill.setApplicationIcon(NSImage(contentsOfFile: "/System/Applications/Notes.app/Contents/Resources/AppIcon.icns"), name: "Notes")
        pill.isHandsFree = locked
        pill.mode = mode
        guard pill.showsLock == (mode == .recording && locked), pill.showsSpinner == (mode == .transcribing) else {
            throw NSError(domain: "WhispPreview", code: 3, userInfo: [NSLocalizedDescriptionKey: "Incorrect lock or spinner state"])
        }
        for level: Float in [0.12, 0.3, 0.55, 0.8, 0.6, 0.35, 0.65, 0.4, 0.7] { pill.push(level: level) }
        try render(pill, size: NSSize(width: 135, height: 38), to: directory.appendingPathComponent(name + ".png"))
        pill.mode = .idle
        guard !pill.showsLock && !pill.showsSpinner else { throw NSError(domain: "WhispPreview", code: 4) }
    }
    // Status-menu warning rows — where clipboard-fallback outcomes surface.
    for (name, message) in [
        ("status-session-interrupt", DictationController.sessionInterruptMessage),
    ] {
        let row = NSTextField(labelWithString: "⚠︎ \(message)")
        row.font = .menuFont(ofSize: 0)
        row.textColor = .labelColor
        row.lineBreakMode = .byTruncatingTail
        try render(row, size: NSSize(width: 360, height: 22),
                   to: directory.appendingPathComponent(name + ".png"))
    }
    print("Rendered \(examples.count) onboarding screens, 4 pill states, and 1 status message with visibility checks to \(directory.path)")
}

@MainActor
private func render(_ view: NSView, size: NSSize, to url: URL) throws {
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .white
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw NSError(domain: "WhispPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create view bitmap"])
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "WhispPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode view bitmap"])
    }
    try png.write(to: url)
}

private struct PreviewPermissions: PermissionsProviding {
    var microphoneGranted: Bool { false }
    var accessibilityGranted: Bool { false }
    var inputMonitoringGranted: Bool { false }
    func requestMicrophone() async -> Bool { false }
    func promptAccessibility() {}
    func requestInputMonitoring() {}
    func openSettings(_ pane: PermissionPane) {}
}

@MainActor
private func checkOnboardingGates(_ model: OnboardingModel) throws {
    func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw NSError(domain: "WhispSetupCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
    }
    try expect(!model.canContinue(from: 2, practiceText: ""), "Permissions must be granted before continuing")
    model.microphoneGranted = true
    model.accessibilityGranted = true
    model.inputMonitoringGranted = true
    try expect(model.canContinue(from: 2, practiceText: ""), "All permissions should unlock the model step")
    model.modelStatus = "Downloading model…"
    try expect(!model.canContinue(from: 3, practiceText: ""), "Downloading must not count as ready")
    model.modelStatus = "Model failed: Offline"
    try expect(!model.canContinue(from: 3, practiceText: ""), "A failed model must not unlock practice")
    model.modelStatus = "Ready"
    try expect(model.canContinue(from: 3, practiceText: ""), "A ready model should unlock practice")
    try expect(!model.canContinue(from: 4, practiceText: ""), "Microphone confirmation is required")
    model.microphoneConfirmed = true
    try expect(model.canContinue(from: 4, practiceText: ""), "Confirmed microphone unlocks the dictation introduction")
    try expect(!model.canContinue(from: 6, practiceText: "Typed by hand"), "Typing alone must not complete dictation practice")
    model.dictatedText = " "
    try expect(!model.canContinue(from: 6, practiceText: "Typed by hand"), "A blank transcript must not pass practice")
    model.dictatedText = "A real dictation."
    try expect(!model.canContinue(from: 6, practiceText: ""), "A transcript without inserted text must not pass practice")
    try expect(model.canContinue(from: 6, practiceText: "A real dictation."), "Inserted dictation should pass practice")
    model.recordingState = .recording
    try expect(!model.canContinue(from: 7, practiceText: "A real dictation."), "Setup must not finish during recording")
    model.recordingState = .idle
    model.microphoneGranted = false
    try expect(!model.canContinue(from: 7, practiceText: "A real dictation."), "Revoked permissions must block completion")
    model.microphoneGranted = true
    try expect(model.canContinue(from: 7, practiceText: "A real dictation."), "Successful practice with a ready model should allow completion")
    model.dictatedText = ""
    print("14 onboarding gate checks passed")
}

private final class PreviewRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    var lostInput = false
    var starts = 0
    var cancels = 0
    var fail = false
    func start() throws {
        starts += 1
        if fail { throw MicRecorderError.inputUnavailable }
    }
    func stop() -> [Float] { [] }
    func samples(from: Int) -> [Float] { [] }
    func cancel() { cancels += 1 }
}

@MainActor
private func checkMicrophoneLifecycle() throws {
    func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw NSError(domain: "WhispMicrophoneCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
    }
    let recorder = PreviewRecorder()
    let model = OnboardingModel(permissions: PreviewPermissions(), makeMicrophoneRecorder: { recorder })
    var transitions: [Bool] = []
    model.onMicrophoneTestChanged = { transitions.append($0); return true }
    model.startMicrophoneTest()
    try expect(recorder.starts == 0, "Missing permission must not start microphone capture")
    model.microphoneGranted = true
    model.recordingState = .recording
    model.startMicrophoneTest()
    try expect(recorder.starts == 0 && transitions.isEmpty, "Dictation must not overlap the microphone check")
    model.recordingState = .idle
    model.startMicrophoneTest()
    try expect(model.microphoneTesting && recorder.starts == 1 && transitions == [true], "Starting a check pauses dictation")
    model.startMicrophoneTest()
    try expect(recorder.starts == 1, "Repeated starts must not create another capture")
    model.confirmMicrophone()
    try expect(!model.microphoneConfirmed && model.microphoneTesting, "Silence must not confirm microphone input")
    recorder.onLevel?(0.7)
    try expect(model.microphoneSignalSeen && model.microphoneLevel == 0.7, "Input drives the microphone meter")
    model.confirmMicrophone()
    try expect(model.microphoneConfirmed && !model.microphoneTesting, "Confirmation finishes the check")
    try expect(recorder.cancels == 1 && transitions == [true, false], "Finishing discards test audio and resumes dictation")
    recorder.onLevel?(0.5)
    try expect(model.microphoneLevel == 0, "Late audio callbacks must not update a stopped check")
    model.stopMicrophoneTest()
    try expect(recorder.cancels == 1, "Repeated cleanup must be harmless")
    model.startMicrophoneTest()
    model.refresh()
    try expect(!model.microphoneTesting && !model.microphoneConfirmed && recorder.cancels == 2, "Permission loss stops test capture")
    model.microphoneGranted = true
    recorder.fail = true
    model.startMicrophoneTest()
    try expect(!model.microphoneTesting && model.microphoneError != nil && transitions.last == false, "Capture failure surfaces an error and resumes dictation")
    print("12 microphone lifecycle checks passed without audio capture")
}

/// Supplies a key window only inside the offscreen editor checks.
final class DesignPreviewApplication: NSApplication {
    var editorCheckWindow: NSWindow?
    override var keyWindow: NSWindow? { editorCheckWindow ?? super.keyWindow }
}

private final class EditorPasteProbe: NSTextView {
    let pasteboard = NSPasteboard.withUniqueName()
    override func paste(_ sender: Any?) { _ = readSelection(from: pasteboard) }
}

@MainActor
private func checkEditors() throws {
    func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw NSError(domain: "WhispEditorCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
    }
    guard let app = NSApp as? DesignPreviewApplication else { return }
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    app.editorCheckWindow = window
    let previousMenu = app.mainMenu
    defer { app.editorCheckWindow = nil; app.mainMenu = previousMenu }
    let probe = EditorPasteProbe(frame: window.contentView!.bounds)
    probe.isRichText = false
    window.contentView = probe
    window.makeFirstResponder(probe)
    probe.pasteboard.setString("Dictated sentence.", forType: .string)
    defer { probe.pasteboard.releaseGlobally() }
    let paste = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
    try expect(!window.performKeyEquivalent(with: paste) && probe.string.isEmpty, "Without an Edit menu, Command-V must reproduce the missing paste")
    installEditingMenu()
    try expect(app.mainMenu!.performKeyEquivalent(with: paste) && probe.string == "Dictated sentence.", "The Edit menu must route Command-V through the focused text responder")

    func editor(in view: NSView) -> OnboardingTextView? {
        if let text = view as? OnboardingTextView { return text }
        return view.subviews.compactMap { editor(in: $0) }.first
    }
    for size: CGFloat in [13, 15] {
        var value = ""
        let binding = Binding<String>(get: { value }, set: { value = $0 })
        let hosting = NSHostingView(rootView: OnboardingEditor(text: binding, placeholder: "Try saying hello", accessibilityLabel: "Practice", fontSize: size).frame(width: 300, height: 130))
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 130)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let text = editor(in: hosting) else { throw NSError(domain: "WhispEditorCheck", code: 2) }
        window.makeFirstResponder(text)
        try expect(text.isEditable && text.isSelectable && text.font?.pointSize == size, "Both fields must be native editable text views")
        try expect(text.textContainerInset == .zero && text.textContainer?.lineFragmentPadding == 0, "Placeholder and cursor must share the same text origin and padding")
        text.insertText("Typed reply", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(value == "Typed reply", "Typing must update the SwiftUI binding")
        text.setSelectedRange(NSRange(location: 6, length: 5))
        try expect(text.readSelection(from: probe.pasteboard) && value == "Typed Dictated sentence.", "Paste must replace the selection and update the binding")
        text.insertText("\nSecond line", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(value == "Typed Dictated sentence.\nSecond line", "Both editors must accept multiline text")
        let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        try expect(app.mainMenu!.performKeyEquivalent(with: selectAll) && text.selectedRange().length == (value as NSString).length, "Select All must use the native editing menu")
    }
    print("Passed 14 offscreen editor checks; private pasteboard only, no desktop key events")
}
