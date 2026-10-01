import AppKit
import Combine
import WhispCore

/// Floating "listening" pill like Willow Voice: borderless, never takes focus.
/// Drag it anywhere (the spot is remembered); otherwise it sits bottom-center
/// of the screen with the mouse. Size comes from `AppSettings.pillScale`.
///   recording    → live waveform driven by recorder levels
///   transcribing → a thin gray spinner; model progress is in the tooltip
///   idle         → hidden, or dimmed when `alwaysShowPill` is on
@MainActor
final class RecordingPillController {

    private let panel: NSPanel
    private let pillView: PillView
    private let settings: AppSettings
    private var state: DictationController.State = .idle
    private var cancellables = Set<AnyCancellable>()

    private static let baseSize = NSSize(width: 200, height: 56)
    private static let bottomMargin: CGFloat = 84
    private static let idleAlpha: CGFloat = 0.95

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

        // Native dragging finishes after performDrag returns; save actual moves.
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak panel] _ in
                guard let self, let panel else { return }
                self.settings.pillOrigin = panel.frame.origin
            }
            .store(in: &cancellables)

        updateApplicationIcon()
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.state != .transcribing else { return }
                self.updateApplicationIcon()
            }
            .store(in: &cancellables)

        // Recorder levels → waveform bars (cheap CALayer updates, ~30 Hz).
        controller.onLevel = { [weak self] level in
            self?.pillView.push(level: level)
        }

        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateApplicationIcon()
                self?.state = state
                self?.refresh()
            }
            .store(in: &cancellables)

        // Until the model is ready the pill tooltip is the only place progress shows.
        controller.$modelStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.pillView.toolTip = status == "Ready" ? "Drag to move" : status
            }
            .store(in: &cancellables)

        controller.$isHandsFree.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.pillView.isHandsFree = $0 }
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

    private func updateApplicationIcon() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        pillView.setApplicationIcon(app.icon, name: app.localizedName ?? "Current app")
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

final class PillView: NSView {
    enum Mode { case idle, recording, transcribing }
    var mode: Mode = .idle { didSet { if mode != oldValue { applyMode() } } }
    var isHandsFree = false { didSet { applyMode() } }
    var showsLock: Bool { mode == .recording && isHandsFree }
    var showsSpinner: Bool { mode == .transcribing }

    private let barsView = WaveformBarsView()
    private let applicationIcon = NSImageView()
    private let lockIcon = NSImageView()
    private let spinner = CAShapeLayer()
    private let spinnerTrack = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.025, alpha: 1).cgColor
        layer?.masksToBounds = true
        addSubview(barsView)
        applicationIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(applicationIcon)
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Hands-free recording")
        lockIcon.contentTintColor = NSColor(white: 0.8, alpha: 1)
        addSubview(lockIcon)
        for ring in [spinnerTrack, spinner] {
            ring.fillColor = nil
            ring.lineWidth = 1.8
            ring.lineCap = .round
            layer?.addSublayer(ring)
        }
        spinnerTrack.strokeColor = NSColor(white: 0.24, alpha: 1).cgColor
        spinner.strokeColor = NSColor(white: 0.75, alpha: 1).cgColor
        spinner.strokeEnd = 0.28
        toolTip = "Drag to move"
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let h = bounds.height
        let iconSize = h * 0.49
        applicationIcon.frame = NSRect(x: h * 0.34, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        let centerX = bounds.width * 0.59
        barsView.frame = NSRect(x: centerX - h * 0.57, y: 0, width: h * 1.14, height: h)
        lockIcon.frame = NSRect(x: bounds.width - h * 0.7, y: h * 0.32, width: h * 0.28, height: h * 0.36)
        let diameter = h * 0.4
        for ring in [spinnerTrack, spinner] {
            ring.frame = CGRect(x: centerX - diameter / 2, y: (h - diameter) / 2, width: diameter, height: diameter)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    func setApplicationIcon(_ image: NSImage?, name: String) {
        applicationIcon.image = image ?? NSImage(systemSymbolName: "app", accessibilityDescription: name)
        applicationIcon.setAccessibilityLabel(name)
        toolTip = "\(name) · Drag to move"
    }

    func push(level: Float) {
        guard mode == .recording else { return }
        barsView.push(level: level)
    }

    private func applyMode() {
        barsView.isHidden = showsSpinner
        lockIcon.isHidden = !showsLock
        spinner.isHidden = !showsSpinner
        spinnerTrack.isHidden = !showsSpinner
        if showsSpinner && spinner.animation(forKey: "spin") == nil {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = 2 * Double.pi
            animation.duration = 0.9
            animation.repeatCount = .infinity
            spinner.add(animation, forKey: "spin")
        } else if !showsSpinner {
            spinner.removeAnimation(forKey: "spin")
        }
        if mode != .recording { barsView.reset() }
        setAccessibilityLabel(mode == .transcribing ? "Processing dictation" : showsLock ? "Hands-free recording" : mode == .recording ? "Recording" : "Whisp ready")
    }
}

// MARK: - Plain white waveform

private final class WaveformBarsView: NSView {
    private let barCount = 9
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
    override func layout() { super.layout(); updateBars() }
    func reset() { levels.removeAll(keepingCapacity: true); updateBars() }

    func push(level: Float) {
        levels.append((levels.last ?? 0) * 0.35 + level * 0.65)
        if levels.count > barCount / 2 + 1 { levels.removeFirst() }
        updateBars()
    }

    private func updateBars() {
        let barWidth = max(1, bounds.width / CGFloat(barCount * 2 - 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let index = levels.count - 1 - abs(i - barCount / 2)
            let level = index >= 0 ? levels[index] : 0
            let height = max(1.5, barWidth) + CGFloat(level) * bounds.height * 0.42
            bar.cornerRadius = barWidth / 2
            bar.frame = CGRect(x: CGFloat(i) * barWidth * 2, y: bounds.midY - height / 2, width: barWidth, height: height)
        }
        CATransaction.commit()
    }
}
