// make-icon.swift — renders the Whisp app icon into a .iconset directory.
//
// Usage: swift scripts/make-icon.swift <output.iconset>
//
// Design: matches the shared Bishesha icon family (~/projects/app-icons) —
// an ivory rounded square with the charcoal "waveform" SF Symbol, the same
// symbol the menu bar shows via MenuBarIcon.swift.

import AppKit
import Foundation

// iconutil requires exactly these (name, pixelSize) pairs.
let iconEntries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// Anthropic-style palette, same as the shared family.
let ivory = NSColor(srgbRed: 0.941, green: 0.933, blue: 0.902, alpha: 1)      // #F0EEE6
let ivoryDeep = NSColor(srgbRed: 0.894, green: 0.878, blue: 0.827, alpha: 1)
let charcoal = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.075, alpha: 1)   // #141413

/// Draws an SF Symbol in one colour, aspect-fit and centred in `box`.
func drawSymbol(_ name: String, in box: NSRect, color: NSColor, weight: NSFont.Weight) {
    let config = NSImage.SymbolConfiguration(pointSize: box.height, weight: weight)
        .applying(.init(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let scale = min(box.width / image.size.width, box.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                          width: size.width, height: size.height))
}

/// macOS 1024 grid: 824-pt body at 100, soft shadow, ivory fill, charcoal symbol.
func drawIcon(size: CGFloat) {
    let k = size / 1024
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 22 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    ivory.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: ivory, ending: ivoryDeep)?.draw(in: shape, angle: -90)
    NSColor.black.withAlphaComponent(0.08).setStroke()
    shape.lineWidth = 2 * k
    shape.stroke()

    let mark = body.insetBy(dx: 190 * k, dy: 190 * k)
    drawSymbol("waveform", in: mark, color: charcoal, weight: .medium)
}

func png(_ size: NSSize, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                               pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// main
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (name, pixels) in iconEntries {
    let data = png(NSSize(width: pixels, height: pixels)) { drawIcon(size: CGFloat(pixels)) }
    try data.write(to: outDir.appendingPathComponent(name))
}
print("wrote \(iconEntries.count) icons to \(outDir.path)")
