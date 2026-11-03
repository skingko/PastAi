#!/usr/bin/env swift
// Draws the app icon and the logo. Run: swift scripts/make-icon.swift <output.iconset> <logo-folder>
import AppKit

// The mark is one idea: a card behind a card is copy and paste, and the spark on it is AI.
// Everything is measured on a 1024 canvas, where the mark spans 244 to 780 on both axes.
let cardSide: CGFloat = 430
let cardCorner: CGFloat = 96
let cardGap: CGFloat = 24
let backOrigin: CGFloat = 350
let frontOrigin: CGFloat = 244
let markOrigin: CGFloat = 244
let markSide: CGFloat = 536

let tangerineTop = NSColor(srgbRed: 1, green: 0.604, blue: 0.235, alpha: 1)
let tangerineBottom = NSColor(srgbRed: 0.957, green: 0.349, blue: 0.059, alpha: 1)
let sparkOrange = NSColor(srgbRed: 0.957, green: 0.392, blue: 0.059, alpha: 1)

func squircle(_ rect: NSRect) -> NSBezierPath {
    let exponent: CGFloat = 5
    let path = NSBezierPath()
    for step in 0..<720 {
        let angle = CGFloat(step) / 720 * 2 * .pi
        let x = rect.midX + rect.width / 2 * copysign(pow(abs(cos(angle)), 2 / exponent), cos(angle))
        let y = rect.midY + rect.height / 2 * copysign(pow(abs(sin(angle)), 2 / exponent), sin(angle))
        if step == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func spark(center: NSPoint, radius: CGFloat, waist: CGFloat) -> NSBezierPath {
    let tips = [
        NSPoint(x: center.x, y: center.y + radius), NSPoint(x: center.x + radius, y: center.y),
        NSPoint(x: center.x, y: center.y - radius), NSPoint(x: center.x - radius, y: center.y),
    ]
    let path = NSBezierPath()
    path.move(to: tips[0])
    for index in 0..<4 {
        let from = tips[index], to = tips[(index + 1) % 4]
        let pull = NSPoint(x: center.x + (from.x + to.x - 2 * center.x) * waist, y: center.y + (from.y + to.y - 2 * center.y) * waist)
        path.curve(to: to, controlPoint1: pull, controlPoint2: pull)
    }
    path.close()
    return path
}

/// Draws the mark with `unit` pixels per canvas unit, shifted by `offset` pixels.
func drawMark(unit: CGFloat, offset: CGFloat, back: NSColor, fillFront: (NSBezierPath) -> Void, star: NSColor, heavySpark: Bool) {
    func card(_ origin: CGFloat, grow: CGFloat = 0) -> NSBezierPath {
        let side = (cardSide + grow * 2) * unit
        let corner = (cardCorner + grow) * unit
        let rect = NSRect(x: (origin - grow) * unit + offset, y: (origin - grow) * unit + offset, width: side, height: side)
        return NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    }

    // The gap around the front card is cut from the back card, so it works on any background.
    NSGraphicsContext.saveGraphicsState()
    let outside = NSBezierPath(rect: NSRect(x: -4096, y: -4096, width: 8192, height: 8192))
    outside.append(card(frontOrigin, grow: cardGap))
    outside.windingRule = .evenOdd
    outside.addClip()
    back.setFill()
    card(backOrigin).fill()
    NSGraphicsContext.restoreGraphicsState()

    fillFront(card(frontOrigin))
    let middle = (frontOrigin + cardSide / 2) * unit + offset
    star.setFill()
    spark(center: NSPoint(x: middle, y: middle), radius: (heavySpark ? 168 : 150) * unit, waist: heavySpark ? 0.2 : 0.15).fill()
}

func bitmap(size: Int, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(size: Int) -> Data {
    bitmap(size: size) {
        let unit = CGFloat(size) / 1024
        let tile = squircle(NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -12 * unit)
        shadow.shadowBlurRadius = 26 * unit
        shadow.set()
        tangerineBottom.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: tangerineTop, ending: tangerineBottom)?.draw(in: tile, angle: -90)
        // At small sizes a fine spark disappears, so it gets heavier there.
        drawMark(
            unit: unit, offset: 0, back: NSColor(white: 1, alpha: 0.42),
            fillFront: { NSColor.white.setFill(); $0.fill() }, star: sparkOrange, heavySpark: size <= 64
        )
    }
}

func logo(size: Int) -> Data {
    bitmap(size: size) {
        let inner = CGFloat(size) * 0.92
        let unit = inner / markSide
        let offset = (CGFloat(size) - inner) / 2 - markOrigin * unit
        drawMark(
            unit: unit, offset: offset, back: tangerineTop.withAlphaComponent(0.42),
            fillFront: { NSGradient(starting: tangerineTop, ending: tangerineBottom)?.draw(in: $0, angle: -90) },
            star: .white, heavySpark: false
        )
    }
}

/// The same mark as a vector, measured from its top left, for places a bitmap will not do.
func logoSVG() -> String {
    let frontSide = Int(cardSide), corner = Int(cardCorner), gap = Int(cardGap)
    let backStart = Int(markSide - cardSide)
    let frontTop = backStart
    let middle = cardSide / 2, tip: CGFloat = 150, pull = tip * 0.15
    func number(_ value: CGFloat) -> String { String(format: "%.1f", value) }
    let centerY = CGFloat(frontTop) + middle
    let top = "\(number(middle)) \(number(centerY - tip))", right = "\(number(middle + tip)) \(number(centerY))"
    let bottom = "\(number(middle)) \(number(centerY + tip))", left = "\(number(middle - tip)) \(number(centerY))"
    func curve(_ x: CGFloat, _ y: CGFloat, to: String) -> String {
        let control = "\(number(middle + x * pull)) \(number(centerY + y * pull))"
        return "C\(control) \(control) \(to)"
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(markSide)) \(Int(markSide))">
      <defs>
        <linearGradient id="tangerine" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#FF9A3C"/>
          <stop offset="1" stop-color="#F4590F"/>
        </linearGradient>
        <mask id="gap">
          <rect width="\(Int(markSide))" height="\(Int(markSide))" fill="#fff"/>
          <rect x="\(-gap)" y="\(frontTop - gap)" width="\(frontSide + gap * 2)" height="\(frontSide + gap * 2)" rx="\(corner + gap)" fill="#000"/>
        </mask>
      </defs>
      <rect x="\(backStart)" width="\(frontSide)" height="\(frontSide)" rx="\(corner)" fill="#FF9A3C" fill-opacity="0.42" mask="url(#gap)"/>
      <rect y="\(frontTop)" width="\(frontSide)" height="\(frontSide)" rx="\(corner)" fill="url(#tangerine)"/>
      <path fill="#fff" d="M\(top) \(curve(1, -1, to: right)) \(curve(1, 1, to: bottom)) \(curve(-1, 1, to: left)) \(curve(-1, -1, to: top))Z"/>
    </svg>

    """
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
let logoFolder = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: logoFolder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try appIcon(size: size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try appIcon(size: size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
try logo(size: 1024).write(to: logoFolder.appending(path: "logo.png"))
try logoSVG().write(to: logoFolder.appending(path: "logo.svg"), atomically: true, encoding: .utf8)
