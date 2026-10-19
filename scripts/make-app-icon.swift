// Draws SwiftPutty's app icon into App/SwiftPutty/Assets.xcassets/AppIcon.appiconset.
//
//   swift scripts/make-app-icon.swift            (from the repository root)
//
// The icon is drawn, not scaled, at every size the asset catalog needs:
// macOS's icon grid (an 824-point rounded square on a 1024-point canvas,
// with a soft shadow), a navy gradient, and a terminal prompt: a white
// chevron and an orange cursor. Details too small to read are left out of
// the smallest sizes.

import AppKit

let canvas: CGFloat = 1024

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colours: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray,
               locations: locations)!
}

/// Draws the icon in 1024-point coordinates (origin bottom left).
func drawIcon(in ctx: CGContext, pixels: Int) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    // Shadows are measured in pixels, not in the scaled coordinates.
    let px = CGFloat(pixels) / canvas

    // Shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * px), blur: 24 * px, color: colour(0x000000, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(colour(0x101A30))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: navy gradient with a cool glow from the top left.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([colour(0x2A3D6B), colour(0x16223F), colour(0x0B111F)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(gradient([colour(0x6F9BFF, 0.30), colour(0x6F9BFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 330, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 860), endRadius: 560, options: [])

    // A terminal's title bar dots, where they are big enough to see.
    if pixels >= 128 {
        for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(colour(hex, 0.85))
            ctx.fillEllipse(in: CGRect(x: 196 + CGFloat(i) * 58, y: 784, width: 36, height: 36))
        }
    }
    ctx.restoreGState()

    // Edge: a faint light rim, brighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(pixels >= 64 ? 4 : 8)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([colour(0xFFFFFF, 0.28), colour(0xFFFFFF, 0.04)], [0, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The prompt chevron, white fading to a pale blue.
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: 292, y: 660))
    chevron.addLine(to: CGPoint(x: 478, y: 512))
    chevron.addLine(to: CGPoint(x: 292, y: 364))
    ctx.saveGState()
    ctx.addPath(chevron)
    ctx.setLineWidth(pixels >= 64 ? 96 : 120)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([colour(0xFFFFFF), colour(0xC7D6F5)], [0, 1]),
                           start: CGPoint(x: 0, y: 720), end: CGPoint(x: 0, y: 300), options: [])
    ctx.restoreGState()

    // The cursor: an orange block with a warm glow.
    let cursor = CGPath(roundedRect: CGRect(x: 548, y: 318, width: 208, height: pixels >= 64 ? 84 : 104),
                        cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.saveGState()
    if pixels >= 64 {
        ctx.setShadow(offset: .zero, blur: 40 * px, color: colour(0xFF8A3D, 0.55))
    }
    ctx.addPath(cursor)
    ctx.setFillColor(colour(0xFF7A3D))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(cursor)
    ctx.clip()
    ctx.drawLinearGradient(gradient([colour(0xFFB347), colour(0xF05138)], [0, 1]),
                           start: CGPoint(x: 0, y: 420), end: CGPoint(x: 0, y: 318), options: [])
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, pixels: pixels)
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "App/SwiftPutty/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: set.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appending(path: "Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]],
                           options: [.prettyPrinted, .sortedKeys])
    .write(to: set.deletingLastPathComponent().appending(path: "Contents.json"))
print("Wrote \(images.count) images to \(set.path)")
