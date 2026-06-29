#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Generates the ProcPin app icon: a task-manager list with a star/sparkle
// cluster in the top-right corner, on a rounded gradient squircle.
//
// Output: build/AppIcon.iconset/* and build/icon-preview.png

// MARK: - Drawing

func draw(in ctx: CGContext, size S: CGFloat) {
    let cs = CGColorSpaceCreateDeviceRGB()
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Transparent canvas.
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

    // Rounded squircle background.
    let margin = S * 0.085
    let r = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = r.width * 0.2237
    let bg = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()
    // Diagonal indigo -> violet gradient.
    let c1 = CGColor(colorSpace: cs, components: [0.40, 0.47, 1.00, 1.0])!  // indigo
    let c2 = CGColor(colorSpace: cs, components: [0.55, 0.34, 0.96, 1.0])!  // violet
    let grad = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: r.minX, y: r.maxY),
                           end: CGPoint(x: r.maxX, y: r.minY),
                           options: [])
    // Subtle top sheen.
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [CGColor(colorSpace: cs, components: [1, 1, 1, 0.16])!,
                                    CGColor(colorSpace: cs, components: [1, 1, 1, 0.0])!] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: r.midX, y: r.maxY),
                           end: CGPoint(x: r.midX, y: r.midY),
                           options: [])
    ctx.restoreGState()

    // MARK: Task list (three rows)
    let leftX = r.minX + r.width * 0.18
    let rowH = r.height * 0.105
    let checkW = rowH
    let gap = r.height * 0.085
    let barX = leftX + checkW + r.width * 0.07
    let barMaxRight = r.maxX - r.width * 0.16
    // Rows occupy the lower-middle band.
    let totalH = rowH * 3 + gap * 2
    let startY = r.minY + (r.height - totalH) * 0.42  // slightly low of center
    let barWidths: [CGFloat] = [1.0, 0.78, 0.55]      // top row longest

    func rounded(_ rect: CGRect, _ rad: CGFloat, _ color: CGColor) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    let white = CGColor(colorSpace: cs, components: [1, 1, 1, 1])!
    for i in 0..<3 {
        // Rows drawn top-to-bottom: row 0 at the top.
        let y = startY + CGFloat(2 - i) * (rowH + gap)

        // Checkbox (rounded square) with an accent fill on the first row.
        let checkRect = CGRect(x: leftX, y: y, width: checkW, height: rowH)
        rounded(checkRect, rowH * 0.28, white)
        if i == 0 {
            // Draw a small check mark inside the first checkbox (violet).
            let inset = checkW * 0.26
            let cr = checkRect.insetBy(dx: inset, dy: inset)
            ctx.setStrokeColor(CGColor(colorSpace: cs, components: [0.52, 0.33, 0.95, 1.0])!)
            ctx.setLineWidth(checkW * 0.14)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: cr.minX, y: cr.midY))
            ctx.addLine(to: CGPoint(x: cr.minX + cr.width * 0.36, y: cr.minY + cr.height * 0.12))
            ctx.addLine(to: CGPoint(x: cr.maxX, y: cr.maxY))
            ctx.strokePath()
        }

        // Task bar.
        let full = barMaxRight - barX
        let w = full * barWidths[i]
        let barRect = CGRect(x: barX, y: y + rowH * 0.18, width: w, height: rowH * 0.64)
        let alpha: CGFloat = i == 0 ? 0.98 : (i == 1 ? 0.82 : 0.62)
        rounded(barRect, barRect.height * 0.5,
                CGColor(colorSpace: cs, components: [1, 1, 1, alpha])!)
    }

    // MARK: Star / sparkle cluster (top-right)
    func star(center: CGPoint, outer: CGFloat, color: CGColor) {
        // 4-point sparkle: concave star with cubic curves toward the center.
        let inner = outer * 0.34
        let path = CGMutablePath()
        let pts = 4
        for k in 0..<pts {
            let a = CGFloat(k) / CGFloat(pts) * .pi * 2 - .pi / 2
            let tip = CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer)
            let aPrev = a - .pi / CGFloat(pts)
            let aNext = a + .pi / CGFloat(pts)
            let cPrev = CGPoint(x: center.x + cos(aPrev) * inner, y: center.y + sin(aPrev) * inner)
            let cNext = CGPoint(x: center.x + cos(aNext) * inner, y: center.y + sin(aNext) * inner)
            if k == 0 { path.move(to: cPrev) }
            path.addQuadCurve(to: tip, control: CGPoint(
                x: center.x + cos(aPrev) * inner * 0.6 + (tip.x - center.x) * 0.2,
                y: center.y + sin(aPrev) * inner * 0.6 + (tip.y - center.y) * 0.2))
            path.addQuadCurve(to: cNext, control: CGPoint(
                x: center.x + cos(aNext) * inner * 0.6 + (tip.x - center.x) * 0.2,
                y: center.y + sin(aNext) * inner * 0.6 + (tip.y - center.y) * 0.2))
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    let warm = CGColor(colorSpace: cs, components: [1.0, 0.90, 0.55, 1.0])!   // soft gold
    let bigCenter = CGPoint(x: r.maxX - r.width * 0.20, y: r.maxY - r.height * 0.19)
    star(center: bigCenter, outer: r.width * 0.115, color: white)
    star(center: CGPoint(x: bigCenter.x - r.width * 0.135, y: bigCenter.y - r.height * 0.055),
         outer: r.width * 0.055, color: warm)
    star(center: CGPoint(x: bigCenter.x + r.width * 0.075, y: bigCenter.y - r.height * 0.115),
         outer: r.width * 0.042, color: CGColor(colorSpace: cs, components: [1, 1, 1, 0.92])!)
}

// MARK: - Render helpers

func render(px: Int, to url: URL) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    draw(in: ctx, size: CGFloat(px))
    guard let cg = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

// MARK: - Main

let fm = FileManager.default
let buildDir = URL(fileURLWithPath: "build", isDirectory: true)
let iconset = buildDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2)
]
for v in variants {
    let px = v.base * v.scale
    let name = v.scale == 1 ? "icon_\(v.base)x\(v.base).png" : "icon_\(v.base)x\(v.base)@2x.png"
    render(px: px, to: iconset.appendingPathComponent(name))
}
render(px: 1024, to: buildDir.appendingPathComponent("icon-preview.png"))
print("Wrote \(iconset.path) and build/icon-preview.png")
