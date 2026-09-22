import AppKit
import Combine
import WhispCore

/// Floating "listening" pill like Willow Voice: borderless, never takes focus.
/// Drag it anywhere (the spot is remembered); otherwise it sits bottom-center
/// of the screen with the mouse. Size comes from `AppSettings.pillScale`.
///   recording    → live waveform driven by recorder levels
///   transcribing → subtle spinner
///   idle         → hidden, or dimmed when `alwaysShowPill` is on
@MainActor
final class RecordingPillController {

    private let panel: NSPanel
    private let pillView: PillView
    private let settings: AppSettings
    private var state: DictationController.State = .idle
    private var cancellables = Set<AnyCancellable>()

    private static let baseSize = NSSize(width: 200, height: 52)
    private static let bottomMargin: CGFloat = 84
    private static let idleAlpha: CGFloat = 0.45

    init(controller: DictationController, settings: AppSettings) {
        self.settings = settings
        let size = Self.size(for: settings.pillScale)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0
        self.panel = panel

        let pill = PillView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = pill
        self.pillView = pill

        pill.onDragEnd = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.settings.pillOrigin = panel.frame.origin
        }

        // Recorder levels → waveform bars (cheap CALayer updates, ~30 Hz).
        controller.onLevel = { [weak self] level in
            self?.pillView.push(level: level)
        }

        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.state = state
                self?.refresh()
            }
            .store(in: &cancellables)

        settings.$pillScale.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scale in self?.resize(to: scale) }
            .store(in: &cancellables)

        Publishers.Merge(
            settings.$alwaysShowPill.dropFirst().map { _ in () },
            settings.$pillOrigin.dropFirst().filter { $0 == nil }.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.position()
            self?.refresh()
        }
        .store(in: &cancellables)
    }

    private static func size(for scale: Double) -> NSSize {
        let s = CGFloat(min(max(scale, 0.4), 1.5))
        return NSSize(width: (baseSize.width * s).rounded(), height: (baseSize.height * s).rounded())
    }

    private func refresh() {
        switch state {
        case .idle:
            pillView.mode = .idle
            settings.alwaysShowPill ? show(alpha: Self.idleAlpha) : hide()
        case .recording:
            pillView.mode = .recording
            show(alpha: 1)
        case .transcribing:
            pillView.mode = .transcribing
            show(alpha: 1)
        }
    }

    private func show(alpha: CGFloat) {
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        } else if settings.pillOrigin == nil, state == .recording {
            position() // follow the mouse to another screen
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = alpha
        }
    }

    private func hide() {
        guard panel.isVisible || panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .idle, !self.settings.alwaysShowPill else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Resize around the current center so the pill doesn't jump.
    private func resize(to scale: Double) {
        let size = Self.size(for: scale)
        let old = panel.frame
        let frame = NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        if settings.pillOrigin != nil { settings.pillOrigin = frame.origin }
    }

    /// Saved spot if it's still on a connected screen, else bottom-center of the
    /// screen holding the mouse.
    private func position() {
        let size = panel.frame.size
        if let origin = settings.pillOrigin,
           NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: origin, size: size)) }) {
            panel.setFrameOrigin(origin)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + Self.bottomMargin))
    }
}

// MARK: - Pill view

private final class PillView: NSView {

    enum Mode {
        case idle, recording, transcribing
    }

    var mode: Mode = .idle {
        didSet { if mode != oldValue { applyMode() } }
    }

    /// Called after the user finishes dragging the pill.
    var onDragEnd: (() -> Void)?

    private let background = NSVisualEffectView()
    private let barsView = WaveformBarsView()
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Dark HUD-material capsule background.
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.masksToBounds = true
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        barsView.autoresizingMask = [.width, .height]
        background.addSubview(barsView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        toolTip = "Drag to move"
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        background.layer?.cornerRadius = bounds.height / 2
        barsView.frame = bounds.insetBy(dx: bounds.height * 0.4, dy: 0)
    }

    // The whole capsule is a drag handle; subviews never take the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let before = window.frame.origin
        window.performDrag(with: event) // returns when the drag ends
        if window.frame.origin != before { onDragEnd?() }
    }

    func push(level: Float) {
        guard mode == .recording else { return }
        barsView.push(level: level)
    }

    private func applyMode() {
        barsView.isHidden = mode == .transcribing
        spinner.isHidden = mode != .transcribing
        if mode == .transcribing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            barsView.reset()
        }
    }
}

// MARK: - Waveform bars (pure CALayer — no drawRect churn at 30 Hz)

private final class WaveformBarsView: NSView {

    private let barCount = 14
    private var barLayers: [CALayer] = []
    private var levels: [Float] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        updateBars()
    }

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
        // Bars and gaps share the width equally, so the waveform scales with the pill.
        let barWidth = max(1.5, (bounds.width / CGFloat(barCount * 2 - 1)).rounded(.down))
        let total = CGFloat(barCount) * barWidth * 2 - barWidth
        let startX = (bounds.width - total) / 2
        let minHeight = max(2, barWidth * 0.75)
        let maxHeight = bounds.height * 0.7
        let midY = bounds.midY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            // levels is a right-aligned history; missing slots sit at min height.
            let levelIndex = levels.count - barCount + i
            let level = levelIndex >= 0 ? levels[levelIndex] : 0
            let height = minHeight + CGFloat(level) * (maxHeight - minHeight)
            bar.cornerRadius = barWidth / 2
            bar.frame = CGRect(x: startX + CGFloat(i) * barWidth * 2, y: midY - height / 2,
                               width: barWidth, height: height)
        }
        CATransaction.commit()
    }
}
