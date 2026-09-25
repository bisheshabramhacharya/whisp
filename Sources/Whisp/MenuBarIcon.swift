import AppKit

/// Menu-bar icon: an SF Symbol picked in IconLab, shared style across Bishesha's apps.
/// The app icon uses the same symbol (~/projects/app-icons/make-icons.swift).
enum MenuBarIcon {
    static let image: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisp")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}
