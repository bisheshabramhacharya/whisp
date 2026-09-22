import AppKit
import Combine
import WhispCore

/// Floating "listening" pill like Willow Voice: borderless, never takes focus,
/// follows the screen containing the mouse, bottom-center.
///   recording    → live waveform driven by recorder levels
///   transcribing → subtle spinner
///   idle         → hidden
@MainActor
final class RecordingPillController {

    private let panel: NSPanel
    private let pillView: PillView
    private var cancellables = Set<AnyCancellable>()

    private static let size = NSSize(width: 200, height: 52)
    private static let bottomMargin: CGFloat = 84

    init(controller: DictationController) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0
        self.panel = panel

        let pill = PillView(frame: NSRect(origin: .zero, size: Self.size))
        panel.contentView = pill
        self.pillView = pill

        // Recorder levels → waveform bars (cheap CALayer updates, ~30 Hz).
        controller.onLevel = { [weak self] level in
            self?.pillView.push(level: level)
        }

        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state: state) }
            .store(in: &cancellables)
    }

    private func apply(state: DictationController.State) {
        switch state {
        case .idle:
            hide()
        case .recording:
            pillView.mode = .recording
            show()
        case .transcribing:
            pillView.mode = .transcribing
            show()
        }
    }

    private func show() {
        positionOnMouseScreen()
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard panel.isVisible || panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    /// Bottom-center of whichever screen currently holds the mouse pointer.
    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.minY + Self.bottomMargin
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Pill view

private final class PillView: NSView {

    enum Mode {
        case recording, transcribing
    }

    var mode: Mode = .recording {
        didSet { applyMode() }
    }

    private let barsView = WaveformBarsView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Transcribing")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Dark HUD-material capsule background.
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = frameRect.height / 2
        background.layer?.masksToBounds = true
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        barsView.frame = bounds.insetBy(dx: 20, dy: 0)
        barsView.autoresizingMask = [.width, .height]
        background.addSubview(barsView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(spinner)

        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: background.centerXAnchor, constant: -30),
            spinner.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        applyMode()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func push(level: Float) {
        guard mode == .recording else { return }
        barsView.push(level: level)
    }

    private func applyMode() {
        let recording = (mode == .recording)
        barsView.isHidden = !recording
        spinner.isHidden = recording
        statusLabel.isHidden = recording
        if recording {
            spinner.stopAnimation(nil)
            barsView.reset()
        } else {
            spinner.startAnimation(nil)
        }
    }
}

// MARK: - Waveform bars (pure CALayer — no drawRect churn at 30 Hz)

private final class WaveformBarsView: NSView {

    private let barCount = 14
    private let barWidth: CGFloat = 4
    private let barGap: CGFloat = 4
    private var barLayers: [CALayer] = []
    private var levels: [Float] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            bar.cornerRadius = barWidth / 2
            bar.frame = CGRect(x: 0, y: frameRect.midY - 1.5, width: barWidth, height: 3)
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reset() {
        levels.removeAll(keepingCapacity: true)
        updateBars()
    }

    /// Push a new level (0...1). Newest sample renders at the right edge.
    func push(level: Float) {
        levels.append(level)
        if levels.count > barCount {
            levels.removeFirst(levels.count - barCount)
        }
        updateBars()
    }

    private func updateBars() {
        let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (bounds.width - total) / 2
        let maxHeight = bounds.height - 16
        let midY = bounds.midY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            // levels is a right-aligned history; missing slots sit at min height.
            let levelIndex = levels.count - barCount + i
            let level = levelIndex >= 0 ? levels[levelIndex] : 0
            let height = max(3, 3 + CGFloat(level) * (maxHeight - 3))
            bar.frame = CGRect(
                x: startX + CGFloat(i) * (barWidth + barGap),
                y: midY - height / 2,
                width: barWidth,
                height: height
            )
        }
        CATransaction.commit()
    }
}
