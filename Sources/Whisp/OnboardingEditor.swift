import AppKit
import SwiftUI

struct OnboardingEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    var fontSize: CGFloat = 15

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = OnboardingTextView()
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = NSColor(white: 0.23, alpha: 1)
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.placeholder = placeholder
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.delegate = context.coordinator
        editor.string = text
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? OnboardingTextView else { return }
        if editor.string != text { editor.string = text }
        editor.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
            editor.needsDisplay = true
        }
    }
}

final class OnboardingTextView: NSTextView {
    var placeholder = ""

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let font, let textContainer else { return }
        let storage = NSTextStorage(string: placeholder, attributes: [
            .font: font, .foregroundColor: NSColor(white: 0.55, alpha: 1),
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: textContainer.size)
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs, at: textContainerOrigin)
    }
}
