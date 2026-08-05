import AppKit

// Generates the Pi Agent app icon as a flat PNG (the OS applies the rounded
// mask). Usage:
//   swift scripts/macos/generate-app-icon.swift <output.png> [size]
// The result is compiled into an .icns by scripts/macos/build-app.sh.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon.swift <output.png> [size]\n".utf8))
    exit(1)
}
let outputPath = arguments[1]
let size = arguments.count >= 3 ? (Int(arguments[2]) ?? 1024) : 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("could not allocate bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: size, height: size)

// Deep indigo → slate, biased toward the top-left for a soft highlight.
let highlight = NSColor(calibratedRed: 0.45, green: 0.38, blue: 0.92, alpha: 1)
let shadow = NSColor(calibratedRed: 0.15, green: 0.13, blue: 0.31, alpha: 1)
NSGradient(colors: [highlight, shadow])!.draw(in: rect, relativeCenterPosition: NSPoint(x: -0.28, y: 0.38))

/// Renders an SF Symbol as a flat, tinted image.
func tintedSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return nil }
    let image = NSImage(size: base.size)
    image.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: base.size))
    color.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    image.unlockFocus()
    return image
}

let glyphPointSize = CGFloat(size) * 0.52
guard let glyph = tintedSymbol("sparkles", pointSize: glyphPointSize, weight: .medium, color: .white) else {
    FileHandle.standardError.write(Data("SF Symbol 'sparkles' is unavailable\n".utf8))
    exit(1)
}

let dropShadow = NSShadow()
dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
dropShadow.shadowBlurRadius = CGFloat(size) * 0.022
dropShadow.shadowOffset = NSSize(width: 0, height: -CGFloat(size) * 0.01)
dropShadow.set()

let glyphRect = NSRect(
    x: (CGFloat(size) - glyph.size.width) / 2,
    y: (CGFloat(size) - glyph.size.height) / 2,
    width: glyph.size.width,
    height: glyph.size.height
)
glyph.draw(in: glyphRect)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath) (\(size)x\(size))")
