import AppKit

// Whisp is a menu-bar app: no Dock icon (LSUIElement in Info.plist for the
// bundled app; .accessory policy covers running as a bare SwiftPM binary).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// AppDelegate is @MainActor; top-level code isn't, but it does run on the main
// thread, so assume the isolation explicitly. `app.delegate` is weak — the
// top-level `delegate` retains it for the app's lifetime.
if let index = CommandLine.arguments.firstIndex(of: "--render-designs") {
    guard CommandLine.arguments.indices.contains(index + 1) else {
        fputs("usage: Whisp --render-designs <output-directory>\n", stderr)
        exit(2)
    }
    do {
        try MainActor.assumeIsolated {
            try renderDesignPreviews(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
