import AppKit
import Combine
import SwiftUI
import WhispCore

@MainActor
final class OnboardingController: NSWindowController, NSWindowDelegate {
    private let model: OnboardingModel
    private weak var appDelegate: AppDelegate?

    init(services: AppServices, appDelegate: AppDelegate) {
        let model = OnboardingModel(permissions: services.permissions)
        self.model = model
        self.appDelegate = appDelegate
        let view = OnboardingView(model: model, settings: services.settings,
            onGrantRequested: { [weak appDelegate] in appDelegate?.beginPermissionPolling() },
            onFinish: { [weak appDelegate] in appDelegate?.finishOnboarding() },
            onRetryModel: { [weak controller = services.controller] in controller?.prepareModel() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Set up Whisp"
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .white
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        model.bind(controller: services.controller)
        model.onMicrophoneTestChanged = { [weak appDelegate] active in
            appDelegate?.setMicrophoneTesting(active) ?? false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopMicrophoneTest()
        model.stopPolling()
        appDelegate?.onboardingClosed()
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false
    @Published var modelStatus = "Model not started"
    @Published var dictatedText = ""
    @Published var statusMessage: String?
    @Published var recordingState: DictationController.State = .idle

    @Published var microphoneTesting = false
    @Published var microphoneConfirmed = false
    @Published var microphoneSignalSeen = false
    @Published var microphoneLevel: Float = 0
    @Published var microphoneError: String?
    var onMicrophoneTestChanged: ((Bool) -> Bool)?
    private var microphoneRecorder: AudioRecording?
    private var microphoneTimeout: Timer?

    var allGranted: Bool { microphoneGranted && accessibilityGranted && inputMonitoringGranted }
    var modelReady: Bool { modelStatus == "Ready" }
    func practicePassed(in text: String) -> Bool {
        !dictatedText.isEmpty && text.contains(dictatedText)
    }

    func canContinue(from step: Int, practiceText: String) -> Bool {
        switch step {
        case 2: return allGranted
        case 3: return allGranted && modelReady
        case 4, 5: return allGranted && modelReady && microphoneConfirmed
        case 6, 7: return allGranted && modelReady && microphoneConfirmed && recordingState == .idle && practicePassed(in: practiceText)
        default: return true
        }
    }

    func startMicrophoneTest() {
        guard microphoneGranted, !microphoneTesting else { return }
        guard recordingState == .idle, onMicrophoneTestChanged?(true) != false else {
            microphoneError = "Finish your current dictation, then try again."
            return
        }
        microphoneError = nil
        microphoneSignalSeen = false
        microphoneConfirmed = false
        let recorder = makeMicrophoneRecorder()
        microphoneRecorder = recorder
        recorder.onLevel = { [weak self] level in
            guard let self, self.microphoneTesting else { return }
            self.microphoneLevel = level
            if level > 0.18 { self.microphoneSignalSeen = true }
        }
        do {
            try recorder.start()
            microphoneTesting = true
            microphoneTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.stopMicrophoneTest()
                    self?.microphoneError = "The check stopped after 30 seconds. You can try again."
                }
            }
        } catch {
            recorder.cancel()
            microphoneRecorder = nil
            _ = onMicrophoneTestChanged?(false)
            microphoneError = "Couldn't start your microphone. Check the selected input and its permission."
        }
    }

    func stopMicrophoneTest() {
        microphoneTimeout?.invalidate()
        microphoneTimeout = nil
        guard microphoneTesting else { return }
        microphoneTesting = false
        microphoneRecorder?.cancel()
        microphoneRecorder = nil
        microphoneLevel = 0
        _ = onMicrophoneTestChanged?(false)
    }

    func confirmMicrophone() {
        guard microphoneTesting && microphoneSignalSeen else { return }
        microphoneConfirmed = true
        stopMicrophoneTest()
    }

    func changeMicrophone() {
        stopMicrophoneTest()
        microphoneConfirmed = false
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!)
    }

    private let permissions: PermissionsProviding
    private let makeMicrophoneRecorder: () -> AudioRecording
    private var poll: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(permissions: PermissionsProviding, makeMicrophoneRecorder: @escaping () -> AudioRecording = { MicRecorder() }) {
        self.permissions = permissions
        self.makeMicrophoneRecorder = makeMicrophoneRecorder
        refresh()
    }

    func bind(controller: DictationController) {
        controller.$modelStatus.receive(on: DispatchQueue.main).assign(to: &$modelStatus)
        controller.$statusMessage.receive(on: DispatchQueue.main).assign(to: &$statusMessage)
        controller.$state.receive(on: DispatchQueue.main).assign(to: &$recordingState)
        controller.$lastResult.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] entry in self?.dictatedText = entry?.cleaned ?? "" }
            .store(in: &cancellables)
    }

    func startPolling() {
        refresh()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopPolling() { poll?.invalidate(); poll = nil }

    func refresh() {
        microphoneGranted = permissions.microphoneGranted
        if !microphoneGranted {
            stopMicrophoneTest()
            microphoneConfirmed = false
        }
        accessibilityGranted = permissions.accessibilityGranted
        inputMonitoringGranted = permissions.inputMonitoringGranted
    }

    func grant(_ pane: PermissionPane) {
        switch pane {
        case .microphone:
            Task { @MainActor in
                if !(await self.permissions.requestMicrophone()) { self.permissions.openSettings(.microphone) }
                self.refresh()
            }
        case .accessibility:
            permissions.promptAccessibility()
            permissions.openSettings(.accessibility)
        case .inputMonitoring:
            permissions.requestInputMonitoring()
            permissions.openSettings(.inputMonitoring)
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    let onGrantRequested: () -> Void
    let onFinish: () -> Void
    let onRetryModel: () -> Void
    @State var step = 0
    @State var practiceText = ""
    @FocusState private var practiceFocused: Bool

    private let purple = Color(red: 0.34, green: 0.27, blue: 0.68)
    private let ink = Color(white: 0.23)
    private let muted = Color(white: 0.55)
    private let surface = Color(white: 0.966)
    private var canContinue: Bool { model.canContinue(from: step, practiceText: practiceText) }
    private var shortcut: String {
        switch settings.hotkeyKeyCode {
        case 61: return "Right Option"
        case 58: return "Left Option"
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 62: return "Right Control"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 56: return "Left Shift"
        case 63: return "Fn"
        default: return "your dictation key"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Capsule().fill(Color(white: 0.94))
                Capsule().fill(LinearGradient(colors: [Color(red: 0.8, green: 0.8, blue: 0.97), Color(red: 0.57, green: 0.49, blue: 0.93)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * CGFloat(step + 1) / 8)
            }.frame(height: 5).padding(.bottom, 36)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 0 { action("Back", primary: false) { step -= 1 } }
                Spacer()
                action(step == 7 ? "Start using Whisp" : "Next", primary: true, enabled: canContinue) {
                    if step == 7 { onFinish() } else { step += 1 }
                }
            }.padding(.top, 24)
        }
        .padding(.horizontal, 44).padding(.top, 26).padding(.bottom, 32)
        .frame(width: 1000, height: 650)
        .foregroundStyle(ink).background(.white).preferredColorScheme(.light)
        .onChange(of: step) { _, newStep in
            if newStep != 4 { model.stopMicrophoneTest() }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            HStack(spacing: 55) {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 9) { appIcon(34); Text("Whisp").font(.system(size: 19, weight: .medium)) }
                    heading("Your voice.\nA little less typing.", "Speak in the app you're already using. Whisp puts your words right at the cursor.", large: true)
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Hold a key, speak, release.", systemImage: "waveform")
                        Label("Speech recognition runs on your Mac.", systemImage: "desktopcomputer")
                        Label("Move the pill wherever it suits you.", systemImage: "cursorarrow")
                    }.font(.system(size: 14)).foregroundStyle(muted)
                }.frame(width: 405, alignment: .leading)
                illustration {
                    VStack(spacing: 18) {
                        exampleCard("Messages", icon: "bubble.left", text: "I'll send the draft over this afternoon.").rotationEffect(.degrees(-6)).offset(x: -8)
                        exampleCard("Notes", icon: "note.text", text: "A good idea, before it gets away.").offset(x: 18)
                        exampleCard("Email", icon: "envelope", text: "Hi Alex, let's find a time to catch up.").rotationEffect(.degrees(5)).offset(x: -4)
                    }.frame(width: 330)
                }
            }
        case 1:
            HStack(spacing: 50) {
                VStack(alignment: .leading, spacing: 22) {
                    heading("Your voice, your control", "Your speech model runs locally. Choose whether to keep the audio after each dictation.")
                    privacyChoice("Keep audio on this Mac", "Save recordings locally so you can play them back from History.", selected: settings.keepRecordings) { settings.keepRecordings = true }
                    privacyChoice("Don't keep audio", "Discard the recording after transcription. Text history still stays on this Mac.", selected: !settings.keepRecordings) { settings.keepRecordings = false }
                    Text("You can change this in the Whisp menu at any time.").font(.system(size: 12)).foregroundStyle(muted)
                }.frame(width: 450)
                illustration { mailIllustration }
            }
        case 2:
            HStack(spacing: 50) {
                VStack(alignment: .leading, spacing: 17) {
                    heading("Let Whisp listen and type", "Enable these permissions so your shortcut works in any app.").padding(.bottom, 6)
                    permissionRow("Let Whisp listen", "Use your microphone when you dictate.", model.microphoneGranted, .microphone)
                    permissionRow("Let Whisp insert text", "Place your words in the focused text field.", model.accessibilityGranted, .accessibility)
                    permissionRow("Enable your shortcut", "Recognize \(shortcut) wherever you work.", model.inputMonitoringGranted, .inputMonitoring)
                    Text("Enable Whisp in Settings, then return here. Permissions update automatically.").font(.system(size: 12)).foregroundStyle(muted)
                }.frame(width: 450)
                illustration {
                    VStack(spacing: 0) {
                        HStack { Text("Privacy & Security").font(.system(size: 13, weight: .medium)); Spacer() }.padding(20)
                        Divider().opacity(0.4)
                        settingsIllustrationRow("Microphone", granted: model.microphoneGranted)
                        settingsIllustrationRow("Accessibility", granted: model.accessibilityGranted)
                        settingsIllustrationRow("Input Monitoring", granted: model.inputMonitoringGranted)
                    }.frame(width: 315).background(.white, in: RoundedRectangle(cornerRadius: 20)).shadow(color: purple.opacity(0.08), radius: 22, y: 8)
                }
            }
        case 3:
            centeredHeading("A speech model, on your Mac", "The first setup downloads your model. Once it's ready, you can dictate offline.")
            illustration {
                VStack(spacing: 20) {
                    appIcon(70)
                    Text(model.modelReady ? "Ready to listen" : model.modelStatus).font(.system(size: 17, weight: .medium)).multilineTextAlignment(.center)
                    if model.modelStatus.hasPrefix("Model failed") { action("Try again", primary: true, action: onRetryModel) }
                    else if !model.modelReady { ProgressView().controlSize(.small) }
                    else { Label("Speech recognition stays local", systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(purple) }
                }.padding(30).frame(width: 410, height: 245).background(.white, in: RoundedRectangle(cornerRadius: 26)).shadow(color: .black.opacity(0.07), radius: 25, y: 8)
            }.frame(maxWidth: .infinity)
        case 4:
            centeredHeading("Make sure we can hear you", "Speak a few words and watch the bars move. Whisp uses your Mac's selected input.")
            illustration {
                VStack(spacing: 25) {
                    Text(model.microphoneConfirmed ? "Your microphone is ready" : model.microphoneTesting ? "Do the bars move when you speak?" : "Let's check your microphone").font(.system(size: 16, weight: .medium))
                    meter(level: model.microphoneLevel).frame(height: 45)
                    HStack(spacing: 12) {
                        action("Change microphone", primary: false) { model.changeMicrophone() }
                        if model.microphoneTesting {
                            action("Yes, they move", primary: true, enabled: model.microphoneSignalSeen) { model.confirmMicrophone() }
                        } else { action(model.microphoneConfirmed ? "Test again" : "Test microphone", primary: true) { model.startMicrophoneTest() } }
                    }
                    if let error = model.microphoneError { Text(error).font(.system(size: 12)).foregroundStyle(muted) }
                }.padding(28).frame(width: 500).background(.white, in: RoundedRectangle(cornerRadius: 26)).shadow(color: .black.opacity(0.09), radius: 25, y: 8)
            }.frame(maxWidth: .infinity)
        case 5:
            centeredHeading("Speak naturally. We'll type it.", "Hold \(shortcut) to dictate. Release when you're done. Double-tap for hands-free recording.")
            illustration {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) { Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(purple); Text("Project notes").font(.system(size: 14, weight: .medium)); Spacer() }.padding(18)
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Alex").font(.system(size: 12, weight: .semibold)).foregroundStyle(muted)
                        Text("Could you send the updated draft when you have a moment?").font(.system(size: 14)).lineSpacing(3)
                        Text("Message Alex…").font(.system(size: 13)).foregroundStyle(muted).padding(15).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 18)
                        HStack { miniPill; Text("Sure, I'll send it over this afternoon.").font(.system(size: 12)); Spacer() }.padding(12).foregroundStyle(.white).background(Color(white: 0.08), in: Capsule())
                    }.padding(24)
                }.frame(width: 470).background(.white, in: RoundedRectangle(cornerRadius: 24)).shadow(color: .black.opacity(0.06), radius: 25, y: 8)
            }.frame(maxWidth: .infinity)
        case 6:
            VStack(alignment: .leading, spacing: 22) {
                heading("Try your first message", "Click the email below. Hold \(shortcut), say a sentence, then release.")
                ZStack {
                    RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [Color(red: 0.93, green: 0.91, blue: 0.96), Color(red: 0.85, green: 0.88, blue: 0.93), Color(red: 0.96, green: 0.94, blue: 0.93)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) { ForEach([Color.red.opacity(0.7), .orange.opacity(0.7), .green.opacity(0.7)], id: \.self) { Circle().fill($0).frame(width: 7, height: 7) }; Spacer(); Text("New message").font(.system(size: 11)).foregroundStyle(muted); Spacer() }.padding(13)
                        Divider().opacity(0.3)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("To: Alex").foregroundStyle(muted)
                            Divider().opacity(0.3)
                            Text("Subject: A quick hello").foregroundStyle(muted)
                            Divider().opacity(0.3)
                            ZStack(alignment: .topLeading) {
                                if practiceText.isEmpty { Text("Try saying: Hi Alex, let's meet tomorrow at three.").foregroundStyle(muted).padding(.top, 9).padding(.leading, 5).allowsHitTesting(false) }
                                TextEditor(text: $practiceText).font(.system(size: 15)).scrollContentBackground(.hidden).focused($practiceFocused).accessibilityLabel("Dictation practice email")
                            }.frame(height: 130).onAppear { practiceFocused = true }
                        }.font(.system(size: 13)).padding(20)
                    }.frame(width: 520).background(.white, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)).shadow(color: .black.opacity(0.04), radius: 18, y: 3).padding(.top, 25)
                }.frame(height: 300).clipped()
                HStack(spacing: 8) {
                    if model.practicePassed(in: practiceText) { Image(systemName: "checkmark.circle.fill").foregroundStyle(purple); Text("That's your voice, typed.") }
                    else { Text(model.statusMessage ?? (model.recordingState == .recording ? "Listening…" : model.recordingState == .transcribing ? "Typing your words…" : "Your message stays in this practice window.")) }
                }.font(.system(size: 12)).foregroundStyle(muted)
                if !model.allGranted { Text("A permission is missing. Go back to enable it.").font(.caption).foregroundStyle(muted) }
            }
        default:
            centeredHeading("You're ready", "A thought, a message, a first draft. Just say it.")
            illustration {
                VStack(spacing: 24) {
                    appIcon(85)
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Hold \(shortcut) to speak", systemImage: "keyboard")
                        Label("Double-tap to keep recording. Tap again to finish.", systemImage: "lock")
                        Label("Drag the pill anywhere. It remembers its place.", systemImage: "cursorarrow")
                    }.font(.system(size: 14)).foregroundStyle(muted)
                    Toggle("Launch Whisp when I log in", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 })).toggleStyle(.switch).tint(purple).font(.system(size: 13)).fixedSize()
                }
            }.frame(maxWidth: .infinity)
        }
    }

    private func heading(_ title: String, _ subtitle: String, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: large ? 36 : 27, weight: .medium)).tracking(-0.7)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func centeredHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 27, weight: .medium)).tracking(-0.7)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(muted).lineSpacing(4)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 120).padding(.bottom, 10)
    }

    private func action(_ title: String, primary: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 13, weight: .medium)).padding(.horizontal, 22).padding(.vertical, 10).foregroundStyle(primary ? .white : ink).background(primary ? purple.opacity(enabled ? 1 : 0.3) : surface, in: Capsule()) }
            .buttonStyle(.plain).disabled(!enabled)
    }

    private func appIcon(_ size: CGFloat) -> some View { Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: size, height: size) }

    private func illustration<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            RadialGradient(colors: [purple.opacity(0.10), purple.opacity(0.045), .clear], center: .center, startRadius: 0, endRadius: 200).frame(width: 400, height: 400)
            content()
        }.frame(maxHeight: .infinity)
    }

    private func exampleCard(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(purple); Text(text).font(.system(size: 17)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading) }
            .padding(22).background(.white, in: RoundedRectangle(cornerRadius: 22)).shadow(color: purple.opacity(0.08), radius: 18, y: 6)
    }

    private func privacyChoice(_ title: String, _ subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 14, weight: .medium)); Text(subtitle).font(.system(size: 13)).foregroundStyle(muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 16)).foregroundStyle(selected ? purple : muted.opacity(0.6))
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(selected ? purple.opacity(0.045) : surface, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(selected ? purple.opacity(0.2) : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func permissionRow(_ title: String, _ subtitle: String, _ granted: Bool, _ pane: PermissionPane) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 14, weight: .medium)); Text(subtitle).font(.system(size: 12)).foregroundStyle(muted) }
            Spacer()
            if granted { Image(systemName: "checkmark.circle.fill").foregroundStyle(purple).font(.system(size: 19)) }
            else { Button { model.grant(pane); onGrantRequested() } label: { Text("Enable").font(.system(size: 12)).padding(.horizontal, 15).padding(.vertical, 7).background(.white, in: RoundedRectangle(cornerRadius: 8)).shadow(color: .black.opacity(0.04), radius: 4, y: 2) }.buttonStyle(.plain) }
        }.padding(20).frame(maxWidth: .infinity).background(surface, in: RoundedRectangle(cornerRadius: 17))
    }

    private func settingsIllustrationRow(_ title: String, granted: Bool) -> some View {
        HStack(spacing: 10) { appIcon(27); Text(title).font(.system(size: 13)); Spacer(); Capsule().fill(granted ? purple : Color(white: 0.85)).frame(width: 31, height: 18).overlay(Circle().fill(.white).frame(width: 14, height: 14).offset(x: granted ? 6 : -6)) }.padding(15).background(granted ? purple.opacity(0.06) : .clear)
    }

    private var mailIllustration: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(Color(white: 0.87)).frame(width: 8, height: 8) }; Spacer() }
            VStack(alignment: .leading, spacing: 14) {
                Text("To: Alex"); Divider().opacity(0.4); Text("A quick hello"); Divider().opacity(0.4)
                Text("Hi Alex,").padding(.top, 5)
                Text("Looking forward to catching up.").font(.system(size: 14))
                ForEach([210.0, 180.0, 110.0], id: \.self) { width in Capsule().fill(surface).frame(width: width, height: 6) }
            }.font(.system(size: 12)).foregroundStyle(muted).padding(22).background(.white, in: RoundedRectangle(cornerRadius: 20))
            HStack { Spacer(); miniPill; Spacer() }.padding(12).background(Color(white: 0.025), in: Capsule()).frame(width: 120).offset(x: 85, y: -12)
        }.padding(14).frame(width: 330).background(purple.opacity(0.035), in: RoundedRectangle(cornerRadius: 24)).shadow(color: purple.opacity(0.07), radius: 25, y: 6)
    }

    private var miniPill: some View {
        HStack(spacing: 3) { ForEach(Array([3.0, 6, 9, 13, 8, 5, 3].enumerated()), id: \.offset) { _, height in Capsule().fill(.white).frame(width: 2, height: height) } }
    }

    private func meter(level: Float) -> some View {
        HStack(spacing: 5) { ForEach(0..<15) { index in Capsule().fill(purple.opacity(index < Int(level * 15) ? 1 : 0.23)).frame(width: 4, height: 8 + CGFloat(index) * 2) } }.accessibilityLabel("Microphone input level")
    }
}
