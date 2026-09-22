// make-icon.swift — renders the Whisp app icon into a .iconset directory.
//
// Usage: swift scripts/make-icon.swift <output.iconset>
//
// Design: macOS-style rounded-square tile with a vertical indigo→violet
// gradient and a centered white waveform glyph (five rounded bars).

import CoreGraphics
import Foundation
import ImageIO

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

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [r, g, b, a])!
}

func roundedRectPath(in rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
           transform: nil)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Rounded-square tile, ~22.5% corner radius (Apple icon shape).
    let inset = s * 0.01
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = roundedRectPath(in: tile, radius: s * 0.225)

    // Vertical gradient: indigo -> violet.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [srgb(0.36, 0.49, 1.00),
                                       srgb(0.55, 0.30, 0.98)] as CFArray,
                              locations: [0.0, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: s / 2, y: s),
                           end: CGPoint(x: s / 2, y: 0),
                           options: [])
    ctx.restoreGState()

    // Subtle top highlight for depth.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let sheen = CGGradient(colorsSpace: colorSpace,
                           colors: [srgb(1, 1, 1, 0.22), srgb(1, 1, 1, 0.0)] as CFArray,
                           locations: [0.0, 0.45])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: s / 2, y: s),
                           end: CGPoint(x: s / 2, y: s * 0.55),
                           options: [])
    ctx.restoreGState()

    // Waveform glyph: five centered vertical bars with rounded caps.
    let barHeights: [CGFloat] = [0.30, 0.56, 0.86, 0.56, 0.30]
    let barWidth = s * 0.085
    let spacing = s * 0.145
    let midY = s / 2
    let firstX = s / 2 - spacing * 2

    ctx.setFillColor(srgb(1, 1, 1, 0.96))
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.02,
                  color: srgb(0.2, 0.1, 0.5, 0.35))
    for (i, h) in barHeights.enumerated() {
        let bh = s * h * 0.62
        let rect = CGRect(x: firstX + CGFloat(i) * spacing - barWidth / 2,
                          y: midY - bh / 2,
                          width: barWidth,
                          height: bh)
        ctx.addPath(roundedRectPath(in: rect, radius: barWidth / 2))
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "CGImageDestination failed for \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "finalize failed for \(url.path)"])
    }
}

// main
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (name, pixels) in iconEntries {
    try writePNG(drawIcon(size: pixels), to: outDir.appendingPathComponent(name))
}
print("wrote \(iconEntries.count) icons to \(outDir.path)")
