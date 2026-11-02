#!/usr/bin/env swift
// Draws the app icon and writes an .iconset folder. Run: swift scripts/make-icon.swift <output.iconset>
import AppKit

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
    }

    let tile = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: 186 * scale, yRadius: 186 * scale)
    NSGradient(colors: [
        NSColor(red: 0.13, green: 0.15, blue: 0.24, alpha: 1),
        NSColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1),
    ])!.draw(in: tile, angle: -90)

    // Stacked cards read as clipboard history; the accent card is the current clip.
    let cards: [(CGFloat, NSColor)] = [
        (560, NSColor(red: 0.20, green: 0.77, blue: 0.40, alpha: 1)),
        (450, NSColor(red: 0.75, green: 0.15, blue: 0.83, alpha: 1)),
        (340, NSColor(red: 1.00, green: 0.54, blue: 0.12, alpha: 1)),
    ]
    for (index, card) in cards.enumerated() {
        let inset = CGFloat(index) * 34
        let body = NSBezierPath(roundedRect: rect(232 - inset / 2 + 17, card.0 - 128, 560 + inset - 34, 300), xRadius: 42 * scale, yRadius: 42 * scale)
        NSColor(white: 1, alpha: 0.14 + CGFloat(index) * 0.08).setFill()
        body.fill()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        card.1.setFill()
        rect(150, card.0 + 96, 720, 76).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSColor.white.setFill()
    for (y, width) in [(CGFloat(268), CGFloat(380)), (214, 300)] {
        NSBezierPath(roundedRect: rect(262, y, width, 26), xRadius: 13 * scale, yRadius: 13 * scale).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size: size).write(to: output.appending(path: "icon_\(size)x\(size).png"))
    try render(size: size * 2).write(to: output.appending(path: "icon_\(size)x\(size)@2x.png"))
}
