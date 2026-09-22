import AppKit
import Combine
import WhispCore

/// NSStatusItem + dropdown menu. Icon follows DictationController.state.
/// The menu is rebuilt every time it opens so history/permissions stay fresh.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private let services: AppServices
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    /// Retains @objc action targets for the current menu incarnation.
    private var menuActions: [MenuAction] = []

    init(services: AppServices) {
        self.services = services
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = Self.icon(for: .idle)
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        services.controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateIcon(for: state) }
            .store(in: &cancellables)
    }

    // MARK: - Icon

    private static func icon(for state: DictationController.State) -> NSImage? {
        switch state {
        case .idle:         return NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisp")
        case .recording:    return NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Whisp — recording")
        case .transcribing: return NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Whisp — transcribing")
        }
    }

    private func updateIcon(for state: DictationController.State) {
        guard let button = statusItem.button else { return }
        let image = Self.icon(for: state)
        switch state {
        case .recording:
            image?.isTemplate = false
            button.contentTintColor = .systemRed
        default:
            image?.isTemplate = true
            button.contentTintColor = nil
        }
        button.image = image
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        menuActions.removeAll()

        let controller = services.controller

        // Model + error status
        menu.addItem(disabled("Model: \(controller.modelStatus)"))
        if let message = controller.statusMessage, !message.isEmpty {
            menu.addItem(disabled("⚠︎ \(message)"))
        }
        menu.addItem(.separator())

        // Last transcript — click copies
        if let last = controller.lastResult {
            menu.addItem(item("Last: \(truncate(last.cleaned, 46))", action: { [weak self] in
                self?.copyToPasteboard(last.cleaned)
            }))
        } else {
            menu.addItem(disabled("No transcripts yet"))
        }

        // History submenu — last 10, click copies
        let historyMenu = NSMenu()
        let entries = services.history.loadLast(10)
        if entries.isEmpty {
            historyMenu.addItem(disabled("Empty"))
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            for entry in entries {
                let title = "\(fmt.string(from: entry.date))  \(truncate(entry.cleaned, 40))"
                historyMenu.addItem(item(title, action: { [weak self] in
                    self?.copyToPasteboard(entry.cleaned)
                }))
            }
        }
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
        menu.addItem(.separator())

        // Data
        menu.addItem(item("Open Whisp Folder", action: {
            NSWorkspace.shared.open(AppPaths.root)
        }))
        menu.addItem(item("Edit Dictionary…", action: {
            NSWorkspace.shared.open(AppPaths.ensureDictionaryTemplate())
        }))
        menu.addItem(.separator())

        // Toggles
        menu.addItem(toggle("Sounds", isOn: services.settings.sounds) { [weak self] in
            guard let self else { return }
            self.services.settings.sounds.toggle()
        })
        menu.addItem(toggle("Mute audio while dictating", isOn: services.settings.autoMute) { [weak self] in
            guard let self else { return }
            self.services.settings.autoMute.toggle()
        })
        menu.addItem(toggle("Keep recordings", isOn: services.settings.keepRecordings) { [weak self] in
            guard let self else { return }
            self.services.settings.keepRecordings.toggle()
        })
        menu.addItem(toggle("Launch at Login", isOn: services.settings.launchAtLogin) { [weak self] in
            guard let self else { return }
            self.services.settings.launchAtLogin.toggle()
        })
        menu.addItem(.separator())

        // Permissions
        addPermissionRow(to: menu, title: "Microphone",
                         granted: services.permissions.microphoneGranted, pane: .microphone)
        addPermissionRow(to: menu, title: "Accessibility",
                         granted: services.permissions.accessibilityGranted, pane: .accessibility)
        addPermissionRow(to: menu, title: "Input Monitoring",
                         granted: services.permissions.inputMonitoringGranted, pane: .inputMonitoring)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Whisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: - Permission rows

    private func addPermissionRow(to menu: NSMenu, title: String, granted: Bool, pane: PermissionPane) {
        if granted {
            menu.addItem(disabled("✓ \(title)"))
        } else {
            menu.addItem(item("✗ \(title) — Grant…", action: { [weak self] in
                self?.grantPermission(pane)
            }))
        }
    }

    private func grantPermission(_ pane: PermissionPane) {
        let permissions = services.permissions
        switch pane {
        case .microphone:
            Task { @MainActor in
                let granted = await permissions.requestMicrophone()
                if !granted { permissions.openSettings(.microphone) }
            }
        case .accessibility:
            permissions.promptAccessibility()
        case .inputMonitoring:
            permissions.requestInputMonitoring()
            permissions.openSettings(.inputMonitoring)
        }
        (NSApp.delegate as? AppDelegate)?.beginPermissionPolling()
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func truncate(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let handler = MenuAction(action)
        menuActions.append(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = handler
        return item
    }

    private func toggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = item(title, action: action)
        menuItem.state = isOn ? .on : .off
        return menuItem
    }
}

/// Boxed closure for NSMenuItem target/action.
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
