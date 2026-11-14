// Generates Resources/AppIcon.icns reproducibly with CoreGraphics (no design tools).
// Usage (from the repo root): swift scripts/make-icon.swift
// Intermediate PNGs go to .build/icon/ (git-ignored) for previewing.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = repo.appendingPathComponent(".build/icon")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Superellipse ("squircle") like the macOS icon shape.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let (cx, cy, a, b) = (r.midX, r.midY, r.width / 2, r.height / 2)
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// SD card outline: rounded rectangle with the top-right corner cut off.
func sdCard(_ r: CGRect, radius: CGFloat, notch: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY - notch), tangent2End: CGPoint(x: r.maxX - notch, y: r.maxY), radius: radius * 0.5)
    p.addArc(tangent1End: CGPoint(x: r.maxX - notch, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius * 0.5)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radius)
    p.closeSubpath()
    return p
}

/// Draws on a 1024-unit canvas scaled to `px`. Small sizes drop fine detail and thicken strokes.
func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.interpolationQuality = .high
    let small = px <= 32

    // Background tile: 824pt body inside the 1024 canvas (Apple's ~10% margin), soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tile); ctx.setFillColor(rgb(0x0E4A63)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x2A8FA8), rgb(0x0B3B5A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let sheen = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // SD card.
    let card = small ? CGRect(x: 262, y: 220, width: 420, height: 560) : CGRect(x: 292, y: 236, width: 400, height: 536)
    let cardPath = sdCard(card, radius: 40, notch: small ? 120 : 104)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x00131F, 0.40))
    ctx.addPath(cardPath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(cardPath); ctx.clip()
    let cardShade = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF), rgb(0xE3EDF2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(cardShade, start: CGPoint(x: 0, y: card.maxY), end: CGPoint(x: 0, y: card.minY), options: [])
    ctx.restoreGState()

    // Contact stripes along the top edge (omitted at tiny sizes where they'd be mush).
    if !small {
        ctx.setFillColor(rgb(0x1B6F8A, 0.85))
        for i in 0..<5 {
            let w: CGFloat = 34, gap: CGFloat = 20
            let r = CGRect(x: card.minX + 44 + CGFloat(i) * (w + gap), y: card.maxY - 44 - 104, width: w, height: 104)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
        }
    }

    // Check badge, overlapping the card's lower-right corner, with a ring in the tile colour to separate it.
    let c = small ? CGPoint(x: 668, y: 320) : CGPoint(x: 676, y: 318)
    let radius: CGFloat = small ? 190 : 160
    // Knock-out ring: repaint the tile gradient around the badge so it reads as a cut-out at every size.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - radius - 22, y: c.y - radius - 22, width: 2 * (radius + 22), height: 2 * (radius + 22))); ctx.clip()
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)); ctx.clip()
    let green = CGGradient(colorsSpace: nil, colors: [rgb(0x4CD964), rgb(0x1FA84A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(green, start: CGPoint(x: c.x, y: c.y + radius), end: CGPoint(x: c.x, y: c.y - radius), options: [])
    ctx.restoreGState()
    let s = radius / 160
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth((small ? 60 : 44) * s); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: c.x - 70 * s, y: c.y + 4 * s))
    ctx.addLine(to: CGPoint(x: c.x - 18 * s, y: c.y - 50 * s))
    ctx.addLine(to: CGPoint(x: c.x + 76 * s, y: c.y + 58 * s))
    ctx.strokePath()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    precondition(CGImageDestinationFinalize(d), "couldn't write \(url.path)")
}

for base in [16, 32, 128, 256, 512] {
    writePNG(render(base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(render(1024), work.appendingPathComponent("preview-1024.png"))

let out = repo.appendingPathComponent("Resources/AppIcon.icns")
try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")
print("Wrote \(out.path) (previews in \(work.path))")
