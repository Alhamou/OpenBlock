// Renders OpenBlock's shield icon as PNGs: swift scripts/make-icons.swift <output-dir>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
for size in [48, 96, 128, 256, 512] {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let background = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.22, yRadius: inset.height * 0.22)
        NSGradient(starting: NSColor(red: 0.16, green: 0.55, blue: 0.98, alpha: 1),
                   ending: NSColor(red: 0.07, green: 0.30, blue: 0.80, alpha: 1))!.draw(in: background, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.5, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
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
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon-\(size).png"))
}
