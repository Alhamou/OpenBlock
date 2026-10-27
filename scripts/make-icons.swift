// Renders OpenBlock's shield icon as PNGs.
//   swift scripts/make-icons.swift <output-dir>             web-extension icons (icon-<size>.png)
//   swift scripts/make-icons.swift --appicon <appiconset>   macOS app icon set with Contents.json
import AppKit

/// - Parameter margin: share of the canvas left empty on each side. macOS app icons use Apple's
///   grid (an 824pt shape on a 1024pt canvas, ~10%) so they line up with other Dock icons.
func render(size: Int, margin: CGFloat, shadow: Bool) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let shape = rect.insetBy(dx: rect.width * margin, dy: rect.height * margin)
        let background = NSBezierPath(roundedRect: shape, xRadius: shape.width * 0.225, yRadius: shape.height * 0.225)
        if shadow {
            NSGraphicsContext.saveGraphicsState()
            let drop = NSShadow()
            drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
            drop.shadowBlurRadius = rect.height * 0.02
            drop.shadowOffset = NSSize(width: 0, height: -rect.height * 0.01)
            drop.set()
            NSColor(red: 0.07, green: 0.30, blue: 0.80, alpha: 1).setFill()
            background.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGradient(starting: NSColor(red: 0.16, green: 0.55, blue: 0.98, alpha: 1),
                   ending: NSColor(red: 0.07, green: 0.30, blue: 0.80, alpha: 1))!.draw(in: background, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: shape.height * 0.53, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: shape.midX - s.width / 2, y: shape.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--appicon" {
    let output = URL(fileURLWithPath: arguments.dropFirst().first ?? "AppIcon.appiconset")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try render(size: points * scale, margin: 0.098, shadow: true).write(to: output.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("Contents.json"))
} else {
    let output = URL(fileURLWithPath: arguments.first ?? ".")
    for size in [48, 96, 128, 256, 512] {
        try render(size: size, margin: 0.06, shadow: false).write(to: output.appendingPathComponent("icon-\(size).png"))
    }
}
