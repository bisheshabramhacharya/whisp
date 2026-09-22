import Foundation
import WhispCore

/// Which System Settings privacy pane to open.
enum PermissionPane {
    case microphone
    case accessibility
    case inputMonitoring
}

/// Thin abstraction over the `Permissions` enum so onboarding/status-menu code
/// can run against mocks before the real implementation lands.
protocol PermissionsProviding {
    var microphoneGranted: Bool { get }
    var accessibilityGranted: Bool { get }
    var inputMonitoringGranted: Bool { get }

    /// Async ask for the mic (TCC prompt). Returns the resulting grant state.
    func requestMicrophone() async -> Bool
    /// Accessibility can't be requested programmatically; this shows the
    /// system prompt that deep-links into Settings.
    func promptAccessibility()
    /// Input Monitoring request (may prompt and/or open Settings).
    func requestInputMonitoring()
    func openSettings(_ pane: PermissionPane)
}

/// Everything the app shell needs, assembled once in Composition.
struct AppServices {
    let controller: DictationController
    let settings: AppSettings
    let history: HistoryStore
    let permissions: PermissionsProviding
}
