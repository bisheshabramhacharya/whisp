import AppKit

// Whisp is a menu-bar app: no Dock icon (LSUIElement in Info.plist for the
// bundled app; .accessory policy covers running as a bare SwiftPM binary).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// AppDelegate is @MainActor; top-level code isn't, but it does run on the main
// thread, so assume the isolation explicitly. `app.delegate` is weak — the
// top-level `delegate` retains it for the app's lifetime.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
