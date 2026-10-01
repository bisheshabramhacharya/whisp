// make-icon.swift — renders the Whisp app icon into a .iconset directory.
//
// Usage: swift scripts/make-icon.swift <output.iconset>
//
// Design: a porcelain-white rounded square with a quiet purple waveform.

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

let porcelain = NSColor(srgbRed: 0.98, green: 0.98, blue: 1.0, alpha: 1)
let violet = NSColor(srgbRed: 0.40, green: 0.33, blue: 0.77, alpha: 1)

/// Relative bar heights, symmetric like a breath.
let barHeights: [CGFloat] = [0.22, 0.46, 0.78, 1.0, 0.78, 0.46, 0.22]

/// macOS 1024 grid: white body, restrained shadow, solid purple bars.
func drawIcon(size: CGFloat) {
    let k = size / 1024
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = 22 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    porcelain.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    porcelain.setFill()
    shape.fill()
    NSColor.white.setStroke()
    shape.lineWidth = 2 * k
    shape.stroke()

    let barWidth = 62 * k
    let gap = 34 * k
    let total = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
    let maxHeight = 480 * k
    var x = body.midX - total / 2
    let bars = NSBezierPath()
    for h in barHeights {
        let height = max(barWidth, maxHeight * h)
        bars.append(NSBezierPath(
            roundedRect: NSRect(x: x, y: body.midY - height / 2, width: barWidth, height: height),
            xRadius: barWidth / 2, yRadius: barWidth / 2))
        x += barWidth + gap
    }

    violet.setFill()
    bars.fill()
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
