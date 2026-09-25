import AppKit
import Combine
import WhispCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var services: AppServices!
    private var statusBar: StatusBarController!
    private var pill: RecordingPillController?
    private var onboarding: OnboardingController?

    /// Polls permission state after the user was sent to Settings, so the
    /// hotkey starts as soon as Accessibility + Input Monitoring land.
    private var permissionPoll: Timer?
    /// Notices a hotkey permission being revoked or re-granted while running.
    private var permissionWatch: Timer?
    private var hotkeyStoppedForPermission = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? AppPaths.ensureDirectories()
        AppPaths.ensureDictionaryTemplate()

        let services = Composition.makeServices()
        self.services = services

        statusBar = StatusBarController(services: services)
        pill = RecordingPillController(controller: services.controller, settings: services.settings)

        // Warm the model in the background — first launch may download it.
        services.controller.prepareModel()

        // Start the hotkey as soon as the required permissions exist.
        if hotkeyPermissionsGranted {
            services.controller.startHotkey()
            services.pasteLast.start()
        }

        // First launch (or missing permissions): show the setup window.
        if !allPermissionsGranted {
            showOnboarding()
        }

        permissionWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.permissionWatchTick() }
        }
    }

    private func permissionWatchTick() {
        guard let services, permissionPoll == nil else { return }
        if hotkeyPermissionsGranted {
            if hotkeyStoppedForPermission {
                hotkeyStoppedForPermission = false
                services.controller.startHotkey()
            }
        } else if services.controller.isHotkeyRunning {
            services.controller.hotkeyPermissionLost()
            hotkeyStoppedForPermission = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPoll?.invalidate()
        permissionWatch?.invalidate()
        services?.controller.shutdown()
    }

    // MARK: - Permissions

    private var hotkeyPermissionsGranted: Bool {
        services.permissions.accessibilityGranted && services.permissions.inputMonitoringGranted
    }

    private var allPermissionsGranted: Bool {
        hotkeyPermissionsGranted && services.permissions.microphoneGranted
    }

    /// Called by the onboarding window and menu "Grant…" actions after they
    /// kick off a request; polls until grants land, then starts the hotkey.
    func beginPermissionPolling() {
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.permissionPollTick() }
        }
    }

    private func permissionPollTick() {
        guard let services else { return }
        if hotkeyPermissionsGranted {
            services.controller.startHotkey()
            services.pasteLast.start()
        }
        if allPermissionsGranted {
            permissionPoll?.invalidate()
            permissionPoll = nil
            onboarding?.close()
            onboarding = nil
        }
    }

    private func showOnboarding() {
        let ob = OnboardingController(services: services, appDelegate: self)
        ob.showWindow(nil)
        onboarding = ob
        beginPermissionPolling()
    }
}
