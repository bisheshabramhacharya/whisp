import Combine
import Foundation
import WhispCore

// MARK: - Composition root
//
// THE ONLY FILE that instantiates concrete implementations. Everything else
// (DictationController, status bar, pill, onboarding) only knows protocols.

@MainActor
enum Composition {

    static func makeServices() -> AppServices {
        let settings = AppSettings()
        let history = HistoryStore()
        let recordings = RecordingArchive()

        let transcriber = ParakeetTranscriber()
        let recorder = MicRecorder()
        let hotkey = RightOptionHotkey(keyCode: UInt16(clamping: settings.hotkeyKeyCode))
        let paster = Paster()
        let dictionary = PersonalDictionary(fileURL: AppPaths.dictionaryFile)
        let cleaner = FillerCleaner(dictionary: dictionary)
        let muter = RealAudioMuter()
        let sounds = RealSounds(settings: settings)
        // Dictionary terms are applied as text fixes by the cleaner (reloaded on
        // every edit), not fed to transcriber.vocabulary: acoustic rescoring
        // measured 2-3x slower on this M1 without fixing more words.

        let controller = DictationController(
            transcriber: transcriber,
            recorder: recorder,
            hotkey: hotkey,
            paster: paster,
            cleaner: cleaner,
            muter: muter,
            sounds: sounds,
            settings: settings,
            history: history,
            recordings: recordings
        )

        // Status lines arrive on the main thread; the hop keeps the
        // @MainActor controller access explicit. Weak: the transcriber (which
        // stores this closure) is owned by the controller.
        transcriber.onStatus = { [weak controller] status in
            Task { @MainActor [weak controller] in
                controller?.modelStatus = status
            }
        }

        return AppServices(
            controller: controller,
            settings: settings,
            history: history,
            permissions: RealPermissions(),
            pasteLast: PasteLastHotkey(controller: controller, history: history, paster: paster)
        )
    }
}

/// Adapts SystemAudioMuter to AudioMuting.
final class RealAudioMuter: AudioMuting {
    private let muter = SystemAudioMuter()
    func mute() { muter.mute() }
    func restore() { muter.restore() }
}

/// Adapts the static `Sounds` enum to SoundPlaying, keeping `Sounds.enabled`
/// live-synced with the Sounds setting.
final class RealSounds: SoundPlaying {
    private var cancellable: AnyCancellable?

    @MainActor
    init(settings: AppSettings) {
        Sounds.preload()
        cancellable = settings.$sounds
            .receive(on: DispatchQueue.main)
            .sink { Sounds.enabled = $0 }
    }

    func playStart() { Sounds.playStart() }
    func playStop() { Sounds.playStop() }
    func playCancel() { Sounds.playCancel() }
    func playError() { Sounds.playError() }
}

/// Adapts the static `Permissions` enum to PermissionsProviding.
struct RealPermissions: PermissionsProviding {
    var microphoneGranted: Bool { Permissions.microphoneGranted }
    var accessibilityGranted: Bool { Permissions.accessibilityGranted }
    var inputMonitoringGranted: Bool { Permissions.inputMonitoringGranted }
    func requestMicrophone() async -> Bool { await Permissions.requestMicrophone() }
    func promptAccessibility() { Permissions.promptAccessibility() }
    func requestInputMonitoring() { Permissions.requestInputMonitoring() }
    func openSettings(_ pane: PermissionPane) {
        switch pane {
        case .microphone: Permissions.openSettings(.microphone)
        case .accessibility: Permissions.openSettings(.accessibility)
        case .inputMonitoring: Permissions.openSettings(.inputMonitoring)
        }
    }
}
