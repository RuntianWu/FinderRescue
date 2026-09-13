// Renders the Finder Rescue app icon (1024×1024 PNG) with Core Graphics.
// Usage: swift scripts/render_icon.swift <output.png>
//
// Design ("Pulse"): a white folder with a heartbeat line on a Finder-blue continuous-corner tile —
// Finder's health, at a glance. Layout follows the macOS icon grid: an 824-pt tile centred on a
// 1024 canvas, leaving room for the drop shadow.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                          space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create bitmap context")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Apple-style continuous-corner tile: a superellipse with n ≈ 5.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...1440 {
        let t = CGFloat(i) / 1440 * 2 * .pi
        let c = cos(t), s = sin(t)
        let pt = CGPoint(x: rect.midX + a * copysign(pow(abs(c), 2 / n), c),
                         y: rect.midY + b * copysign(pow(abs(s), 2 / n), s))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

/// Fills `path` with a vertical gradient, optionally casting a soft shadow first.
func fill(_ path: CGPath, _ g: CGGradient, top: CGFloat, bottom: CGFloat, shadow: (dy: CGFloat, blur: CGFloat, alpha: CGFloat)? = nil) {
    if let shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: shadow.dy), blur: shadow.blur, color: color(0x000000, shadow.alpha))
        ctx.addPath(path)
        ctx.setFillColor(color(0x000000))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: bottom), options: [])
    ctx.restoreGState()
}

// MARK: Tile

let tile = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(tile)
ctx.setFillColor(color(0x1E6BE6))
ctx.fillPath()
ctx.restoreGState()
fill(tile, gradient(0x5CB3FF, 0x1E6BE6), top: 924, bottom: 100)
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
ctx.addPath(tile)
ctx.setStrokeColor(color(0xFFFFFF, 0.18))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// MARK: Folder

let folder = CGRect(x: 252, y: 290, width: 520, height: 430)
let radius = folder.height * 0.09
let back = CGMutablePath()
back.addPath(roundedRect(CGRect(x: folder.minX, y: folder.minY, width: folder.width, height: folder.height * 0.86), radius))
back.addPath(roundedRect(CGRect(x: folder.minX, y: folder.minY + folder.height * 0.70,
                                width: folder.width * 0.40, height: folder.height * 0.30), radius * 0.8))
let frontRect = CGRect(x: folder.minX, y: folder.minY, width: folder.width, height: folder.height * 0.74)
let front = roundedRect(frontRect, radius)

fill(back, gradient(0xDCEBFF, 0xC4DDFF), top: folder.maxY, bottom: folder.minY, shadow: (-10, 24, 0.22))
fill(front, gradient(0xFFFFFF, 0xEEF5FF), top: frontRect.maxY, bottom: folder.minY, shadow: (-6, 14, 0.18))

// MARK: Heartbeat

let points: [(x: CGFloat, y: CGFloat)] = [(0.12, 0), (0.36, 0), (0.44, 0.26), (0.53, -0.30), (0.61, 0.12), (0.66, 0), (0.88, 0)]
let pulse = CGMutablePath()
for (i, p) in points.enumerated() {
    let pt = CGPoint(x: frontRect.minX + frontRect.width * p.x, y: frontRect.midY - 6 + frontRect.height * p.y)
    if i == 0 { pulse.move(to: pt) } else { pulse.addLine(to: pt) }
}
ctx.addPath(pulse)
ctx.setStrokeColor(color(0x2A7BF0))
ctx.setLineWidth(34)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

// MARK: Write

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create image")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(out.path)") }
print("Wrote \(out.path)")
