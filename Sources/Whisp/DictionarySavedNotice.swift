import AppKit

/// Small note at the top-right of the screen after a correction is saved.
/// Whisp is a menu-bar app, so this panel never activates it or takes clicks —
/// same rules as the recording pill (near-black capsule, no focus).
@MainActor
final class DictionarySavedNotice {

    private let panel: NSPanel
    private let background = NoticeBackground(frame: .zero)
    private let label: NSTextField
    /// Bumped on every show so a fade already in flight can't hide the new one.
    private var hideToken = 0

    /// How long the note stays fully visible before it fades.
    private static let hold: TimeInterval = 3
    private static let fadeIn: TimeInterval = 0.15
    private static let fadeOut: TimeInterval = 0.45

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 34),
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
        panel.contentView = background
        self.panel = panel

        let label = NSTextField(frame: .zero)
        label.cell = CenteredTextFieldCell(textCell: "")
        label.isBezeled = false
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        background.addSubview(label)
        self.label = label
    }

    /// Shows `message` on the screen under the mouse. A later call replaces it.
    func show(_ message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        hideToken += 1
        let token = hideToken
        place(message)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold) { [weak self] in
            MainActor.assumeIsolated {
                self?.fadeOut(token)
            }
        }
    }

    private func fadeOut(_ token: Int) {
        guard hideToken == token else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Sizes the capsule to the line of text and pins it to the top-right of
    /// the visible frame (below the menu bar, clear of the Dock).
    ///
    /// `NSString.size` is about 4 pt narrower than the text field actually
    /// draws, which clipped the correction ("Pychy → pi…"). The cell's own
    /// size includes that padding.
    private func place(_ message: String) {
        label.stringValue = message
        background.setAccessibilityLabel(message)
        let visible = Self.screenWithMouse()?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let margin: CGFloat = 16
        let padX: CGFloat = 16
        let height: CGFloat = 34
        let fitting = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 200))
            ?? NSSize(width: 10_000, height: height)
        let contentWidth = ceil(fitting.width)
        let maxWidth = max(160, visible.width - margin * 2)
        let labelWidth = min(contentWidth, maxWidth - padX * 2)
        let width = labelWidth + padX * 2
        let frame = NSRect(
            x: visible.maxX - width - margin,
            y: visible.maxY - height - 12,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        background.frame = NSRect(origin: .zero, size: frame.size)
        label.frame = NSRect(x: padX, y: 0, width: labelWidth, height: height)
        background.layer?.cornerRadius = height / 2
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

// MARK: - Capsule

private final class NoticeBackground: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.025, alpha: 1).cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// NSTextField draws on the cap-line. Nudge it to the vertical middle of the capsule.
private final class CenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let text = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        let delta = text.height - textHeight
        guard delta > 0 else { return text }
        return NSRect(x: text.origin.x, y: text.origin.y + delta / 2, width: text.width, height: textHeight)
    }
}
