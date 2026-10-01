import AppKit
import Combine
import WhispCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var services: AppServices!
    private var statusBar: StatusBarController!
    private var pill: RecordingPillController?
    private var onboarding: OnboardingController?
    private var microphoneTesting = false

    /// Polls permission state after the user was sent to Settings, so the
    /// hotkey starts as soon as Accessibility + Input Monitoring land.
    /// Bounded by `permissionPollDeadline` — between requests, activation
    /// events drive the checks instead (no timers fire while idle).
    private var permissionPoll: Timer?
    private var permissionPollDeadline: Date?
    /// Turns observed permission state into stop/start decisions for the hotkey.
    private var permissionTracker = HotkeyPermissionTracker()
    private var activationObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? AppPaths.ensureDirectories()
        AppPaths.ensureDictionaryTemplate()
        // Repair system audio if a previous run died while muted.
        SystemAudioMuter.repairAfterCrash()

        let services = Composition.makeServices()
        self.services = services

        statusBar = StatusBarController(services: services, onOpenSetup: { [weak self] in self?.showOnboarding() })
        pill = RecordingPillController(controller: services.controller, settings: services.settings)

        // Warm the model in the background — first launch may download it.
        services.controller.prepareModel()

        // Start dictation only after all three permissions are available.
        if allPermissionsGranted {
            services.controller.startHotkey()
            services.pasteLast.start()
        }

        // First launch (or missing permissions): show the setup window.
        if !services.settings.onboardingCompleted || !allPermissionsGranted || CommandLine.arguments.contains("--onboarding") {
            showOnboarding()
        }

        // Permission checks are event-driven: our own activation (menu clicks,
        // the setup window) and every app activation (covers "granted it in
        // Settings, switched back"). Nothing fires while the app is idle.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkPermissions() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkPermissions() }
        }
    }

    /// Runs the permission tracker once. Only meaningful when the grant poll
    /// isn't already driving (same ownership rule as the old watch timer).
    private func checkPermissions() {
        guard let services, permissionPoll == nil, !microphoneTesting else { return }
        switch permissionTracker.check(hotkeyPermissionsGranted: allPermissionsGranted,
                                       hotkeyRunning: services.controller.isHotkeyRunning) {
        case .startHotkey:
            services.controller.startHotkey()
            services.pasteLast.start()
        case .stopHotkey:
            services.controller.hotkeyPermissionLost()
        case .none:
            break
        }
    }

    /// Onboarding closed (completed or dismissed): the grant poll's job is done.
    /// The next activation re-checks permission state on its own.
    func onboardingClosed() {
        permissionPoll?.invalidate()
        permissionPoll = nil
        onboarding = nil
        // Grants may have landed while the window was up — start the hotkey now.
        if let services, allPermissionsGranted {
            services.controller.startHotkey()
            services.pasteLast.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPoll?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
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
    /// The poll dies with the onboarding window or after 3 minutes — whichever
    /// comes first; activation checks carry on after that.
    func beginPermissionPolling() {
        permissionPollDeadline = Date().addingTimeInterval(180)
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.permissionPollTick() }
        }
    }

    private func permissionPollTick() {
        guard let services else { return }
        if let deadline = permissionPollDeadline, Date() > deadline {
            permissionPoll?.invalidate()
            permissionPoll = nil
            return
        }
        if allPermissionsGranted && !microphoneTesting {
            services.controller.startHotkey()
            services.pasteLast.start()
            permissionPoll?.invalidate()
            permissionPoll = nil
        }
    }

    func setMicrophoneTesting(_ active: Bool) -> Bool {
        if active {
            guard services.controller.state == .idle else { return false }
            microphoneTesting = true
            services.controller.stopHotkey()
        } else {
            microphoneTesting = false
            if allPermissionsGranted {
                services.controller.startHotkey()
                services.pasteLast.start()
            }
        }
        return true
    }

    func finishOnboarding() {
        guard allPermissionsGranted, services.controller.modelStatus == "Ready" else { return }
        services.settings.onboardingCompleted = true
        onboarding?.close()
    }

    private func showOnboarding() {
        if let onboarding {
            onboarding.showWindow(nil)
            return
        }
        let ob = OnboardingController(services: services, appDelegate: self)
        ob.showWindow(nil)
        onboarding = ob
        beginPermissionPolling()
    }
}
