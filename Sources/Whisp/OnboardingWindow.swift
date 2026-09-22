import AppKit
import Combine
import SwiftUI
import WhispCore

/// First-run setup: lists the three required permissions with Grant buttons
/// that tick over as they land, plus model download status. Polls while shown;
/// AppDelegate closes it once everything is granted.
@MainActor
final class OnboardingController: NSWindowController, NSWindowDelegate {

    private let model: OnboardingModel

    init(services: AppServices, appDelegate: AppDelegate) {
        let model = OnboardingModel(permissions: services.permissions)
        self.model = model

        let view = OnboardingView(model: model, services: services) { [weak appDelegate] in
            appDelegate?.beginPermissionPolling()
        }
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Whisp"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        model.bind(controller: services.controller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        model.startPolling()
        // Accessory app: activate so the setup window actually comes forward.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Stop the refresh poll when the window isn't visible.
    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}

// MARK: - Model

@MainActor
private final class OnboardingModel: ObservableObject {
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false
    @Published var modelStatus = "Model not started"

    var allGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }

    private let permissions: PermissionsProviding
    private var poll: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(permissions: PermissionsProviding) {
        self.permissions = permissions
        refresh()
    }

    func bind(controller: DictationController) {
        controller.$modelStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$modelStatus)
    }

    func startPolling() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    func refresh() {
        microphoneGranted = permissions.microphoneGranted
        accessibilityGranted = permissions.accessibilityGranted
        inputMonitoringGranted = permissions.inputMonitoringGranted
    }

    func grant(_ pane: PermissionPane) {
        switch pane {
        case .microphone:
            Task { @MainActor in
                let granted = await self.permissions.requestMicrophone()
                if !granted { self.permissions.openSettings(.microphone) }
                self.refresh()
            }
        case .accessibility:
            permissions.promptAccessibility()
        case .inputMonitoring:
            permissions.requestInputMonitoring()
            permissions.openSettings(.inputMonitoring)
        }
    }
}

// MARK: - SwiftUI view

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let services: AppServices
    let onGrantRequested: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisp").font(.title2).bold()
                    Text("Local, offline dictation").font(.caption).foregroundColor(.secondary)
                }
            }

            Text("Hold **Right Option**, speak, release — text is pasted at your cursor.\nWhisp needs three permissions:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "To hear you while the key is held",
                    granted: model.microphoneGranted,
                    pane: .microphone
                )
                permissionRow(
                    icon: "hand.raised.fill",
                    title: "Accessibility",
                    subtitle: "To detect the key and paste into apps",
                    granted: model.accessibilityGranted,
                    pane: .accessibility
                )
                permissionRow(
                    icon: "keyboard.fill",
                    title: "Input Monitoring",
                    subtitle: "To see the hotkey in every app",
                    granted: model.inputMonitoringGranted,
                    pane: .inputMonitoring
                )
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "cpu").foregroundColor(.secondary)
                Text(model.modelStatus).font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Text("Whisp lives in the menu bar — no Dock icon.")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button(model.allGranted ? "Done" : "Close") {
                    NSApp.keyWindow?.close()
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func permissionRow(icon: String, title: String, subtitle: String, granted: Bool, pane: PermissionPane) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).bold()
                Text(subtitle).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else {
                Button("Grant…") {
                    model.grant(pane)
                    onGrantRequested()
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}
