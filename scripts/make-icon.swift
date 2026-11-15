// Draws the app icon into an .iconset directory: `swift scripts/make-icon.swift <dir>.iconset`.
// Generated at build time so the repository holds no binary assets.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)

    // macOS icon grid: the tile fills ~80% of the canvas, leaving room for the shadow.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let shape = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.00, green: 0.80, blue: 0.56, alpha: 1),
        NSColor(red: 0.02, green: 0.45, blue: 0.42, alpha: 1),
    ])!.draw(in: shape, angle: -70)

    // A soft highlight across the top half gives the tile depth.
    NSGradient(colors: [.white.withAlphaComponent(0.22), .white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18), angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.36, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 0.02, green: 0.45, blue: 0.42, alpha: 1), .white]))
    if let symbol = NSImage(systemSymbolName: "icloud.and.arrow.up.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2 - s * 0.01,
                               width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: out.appending(path: "icon_\(points)x\(points).png"))
    try render(points * 2).write(to: out.appending(path: "icon_\(points)x\(points)@2x.png"))
}
