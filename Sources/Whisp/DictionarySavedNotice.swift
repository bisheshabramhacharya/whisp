import AppKit
import WhispCore

/// Small card at the top right of the screen after a correction lands in the
/// dictionary: a soft chime, a confetti pop, and five seconds of Undo.
///
/// Rules it lives by: it never activates Whisp or takes keyboard focus (same
/// rules as the recording pill), it is click-through except while Undo is live,
/// and it is only ever shown from the learning callback — so nothing here runs
/// on the dictation path, between key release and the paste.
@MainActor
final class DictionarySavedNotice {

    /// How long Undo accepts a click, and how long the card lingers after.
    static let undoWindow: TimeInterval = 5
    private static let holdAfterUndoWindow: TimeInterval = 0.8
    private static let fadeIn: TimeInterval = 0.15
    private static let fadeOut: TimeInterval = 0.4
    private static let cardHeight: CGFloat = 66
    private static let confettiHeight: CGFloat = 92
    private static let padX: CGFloat = 14
    private static let undoWidth: CGFloat = 52

    private let panel: NSPanel
    private let container = NSView(frame: .zero)
    private let card = CardView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "Added to dictionary")
    private let pairLabel = NSTextField(labelWithString: "")
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let confetti = ConfettiView(frame: .zero)

    private var batch: LearnedBatch?
    /// Bumped on every show so a fade or an expired Undo from the last card
    /// can't act on the new one.
    private var token = 0

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: Self.cardHeight + Self.confettiHeight),
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
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.alphaValue = 0
        panel.contentView = container
        self.panel = panel

        container.addSubview(confetti)
        container.addSubview(card)
        card.addSubview(titleLabel)
        card.addSubview(pairLabel)
        card.addSubview(undoButton)

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        pairLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pairLabel.textColor = .white
        pairLabel.lineBreakMode = .byTruncatingTail

        undoButton.target = self
        undoButton.action = #selector(undoTapped)
        undoButton.isBordered = false
        undoButton.wantsLayer = true
        undoButton.layer?.cornerRadius = 7
        undoButton.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        undoButton.attributedTitle = NSAttributedString(string: "Undo", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        undoButton.setAccessibilityLabel("Undo the dictionary change")
    }

    /// Shows `batch` and offers Undo for `undoWindow` seconds. Only ever called
    /// once a write to dictionary.json has returned.
    func show(_ batch: LearnedBatch) {
        let pair = Self.describe(batch.entries)
        guard !pair.isEmpty else { return }
        self.batch = batch
        token += 1
        let token = token
        titleLabel.stringValue = "Added to dictionary"
        pairLabel.stringValue = pair
        container.setAccessibilityLabel("Added to dictionary: \(pair)")
        undoButton.isHidden = false
        undoButton.isEnabled = true
        panel.ignoresMouseEvents = false
        place()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        confetti.burst(width: card.frame.width)

        // Undo closes after its window; the card lingers a beat, then fades.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == token else { return }
                self.closeUndoWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdAfterUndoWindow) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.token == token else { return }
                        self.fadeOut(token)
                    }
                }
            }
        }
    }

    /// `from → to`, or a comma list when one take taught more than one word.
    static func describe(_ entries: [LearnedEntry]) -> String {
        entries
            .map { $0.from.isEmpty ? $0.to : "\($0.from) → \($0.to)" }
            .joined(separator: ", ")
    }

    @objc private func undoTapped() {
        guard let batch else { return }
        token += 1
        let token = token
        self.batch = nil
        batch.undo()
        pairLabel.stringValue = "Removed again"
        container.setAccessibilityLabel("Removed from the dictionary")
        closeUndoWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == token else { return }
                self.fadeOut(token)
            }
        }
    }

    private func closeUndoWindow() {
        undoButton.isEnabled = false
        undoButton.isHidden = true
        panel.ignoresMouseEvents = true
    }

    private func fadeOut(_ token: Int) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == token else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Layout

    /// Pins the card to the top-right of the screen under the mouse, with the
    /// confetti area hanging below it.
    private func place() {
        let visible = Self.screenWithMouse()?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let width = cardWidth(maxWidth: max(200, visible.width - 32))
        let size = NSSize(width: width, height: Self.cardHeight + Self.confettiHeight)
        panel.setFrame(
            NSRect(x: visible.maxX - width - 16, y: visible.maxY - size.height - 12, width: width,
                   height: size.height),
            display: true
        )
        layout(size: size, width: width)
    }

    /// Sizes the card to its two lines plus the Undo button.
    private func cardWidth(maxWidth: CGFloat) -> CGFloat {
        let text = max(Self.width(of: titleLabel), Self.width(of: pairLabel))
        return min(text + Self.padX * 2 + Self.undoWidth + 10, maxWidth)
    }

    /// Positions everything for a container of `size`. Shared with the
    /// design-preview render so the picture is the live layout.
    private func layout(size: NSSize, width: CGFloat) {
        let textWidth = width - Self.padX * 2 - Self.undoWidth - 10
        container.frame = NSRect(origin: .zero, size: size)
        card.frame = NSRect(x: 0, y: Self.confettiHeight, width: width, height: Self.cardHeight)
        confetti.frame = NSRect(x: 0, y: 0, width: width, height: Self.confettiHeight)
        titleLabel.frame = NSRect(x: Self.padX, y: Self.cardHeight - 32, width: textWidth, height: 14)
        pairLabel.frame = NSRect(x: Self.padX, y: 16, width: textWidth, height: 18)
        undoButton.frame = NSRect(x: width - Self.padX - Self.undoWidth,
                                  y: (Self.cardHeight - 26) / 2, width: Self.undoWidth, height: 26)
    }

    private static func width(of label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 200)).width ?? 0)
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - Design preview

    /// The live card for `entries`, laid out in a plain view, for
    /// `Whisp --render-designs`. Same subviews and frames the panel shows; no
    /// window, no sound.
    func previewCard(_ entries: [LearnedEntry]) -> NSView {
        pairLabel.stringValue = Self.describe(entries)
        titleLabel.stringValue = "Added to dictionary"
        undoButton.isHidden = false
        undoButton.isEnabled = true
        let width = cardWidth(maxWidth: 360)
        let size = NSSize(width: width, height: Self.cardHeight + Self.confettiHeight)
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.addSubview(container)
        layout(size: size, width: width)
        confetti.burst(width: width)
        return box
    }
}

// MARK: - Card

private final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 0.97).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Confetti

/// A short burst of dots that fall out from under the card and fade. Model
/// positions are the end of each dot's path, so a still frame reads as a burst;
/// the animation is what moves them, and nothing stays on screen afterwards.
private final class ConfettiView: NSView {
    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.45, green: 0.72, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.75, alpha: 1),
        NSColor(calibratedWhite: 0.95, alpha: 1),
    ]

    private var dots: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func burst(width: CGFloat) {
        guard width > 40, bounds.height > 20 else { return }
        dots.forEach { $0.removeFromSuperlayer() }
        dots = []
        let fromY = bounds.height
        for _ in 0..<18 {
            let dot = CALayer()
            let size = CGFloat.random(in: 3.5...6)
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size * 1.6)
            dot.cornerRadius = size / 3
            dot.backgroundColor = Self.palette.randomElement()?.cgColor
            let startX = width * CGFloat.random(in: 0.08...0.92)
            let endX = startX + CGFloat.random(in: -42...42)
            let endY = max(6, fromY - CGFloat.random(in: 22...84))
            dot.position = CGPoint(x: endX, y: endY)
            dot.opacity = 1
            layer?.addSublayer(dot)

            let fall = CABasicAnimation(keyPath: "position")
            fall.fromValue = NSValue(point: NSPoint(x: startX, y: fromY))
            fall.toValue = NSValue(point: NSPoint(x: endX, y: endY))
            fall.duration = Double.random(in: 0.55...0.9)
            fall.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.random(in: -3...3)
            spin.duration = fall.duration

            // Faded over the back half of the fall, so a dot never pops back
            // once its animation is gone.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.beginTime = CACurrentMediaTime() + fall.duration * 0.4
            fade.duration = fall.duration * 0.6
            fade.fillMode = .backwards

            dot.add(fall, forKey: "fall")
            dot.add(spin, forKey: "spin")
            dot.add(fade, forKey: "fade")
            dots.append(dot)
        }
        let dots = self.dots
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            dots.forEach { $0.removeFromSuperlayer() }
            if self?.dots.count == dots.count { self?.dots = [] }
        }
    }
}
