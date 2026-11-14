// Renders the CcinnStarRocks app icon (all macOS iconset sizes) with AppKit.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 186 * scale

    // Drop shadow under the squircle.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.16, green: 0.12, blue: 0.52, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Night-sky gradient.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.49, green: 0.43, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.31, green: 0.24, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.09, blue: 0.40, alpha: 1),
    ], atLocations: [0, 0.5, 1], colorSpace: .sRGB)
    gradient?.draw(in: shape, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Soft top highlight.
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])
    highlight?.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    // A few small stars.
    let stars: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.78, 10), (0.80, 0.82, 7), (0.72, 0.30, 8), (0.18, 0.36, 6), (0.86, 0.56, 5)]
    for (x, y, size) in stars {
        let rect = NSRect(x: body.minX + body.width * x - size * scale / 2, y: body.minY + body.height * y - size * scale / 2,
                          width: size * scale, height: size * scale)
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
    // Columnar "rows" bars under the star.
    let barWidths: [CGFloat] = [0.50, 0.36, 0.22]
    for (index, fraction) in barWidths.enumerated() {
        let width = body.width * fraction
        let height = 34 * scale
        let rect = NSRect(x: body.midX - width / 2, y: body.minY + (150 - CGFloat(index) * 54) * scale, width: width, height: height)
        NSColor.white.withAlphaComponent(0.92 - CGFloat(index) * 0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Sparkle glyph.
    let configuration = NSImage.SymbolConfiguration(pointSize: 420 * scale, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        glyphShadow.shadowBlurRadius = 18 * scale
        glyphShadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        NSGraphicsContext.saveGraphicsState()
        glyphShadow.set()
        let size = tinted.size
        let origin = NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2 + 70 * scale)
        tinted.draw(in: NSRect(origin: origin, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
print("wrote \(sizes.count) images to \(outputDirectory.path)")
