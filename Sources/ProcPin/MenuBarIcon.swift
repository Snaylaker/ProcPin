import AppKit

/// Draws the menu-bar status item glyph: a small checklist with a sparkle
/// cluster, as a transparent template image (macOS tints it for light/dark
/// menu bars).
enum MenuBarIcon {

    static func image() -> NSImage {
        let w: CGFloat = 18, h: CGFloat = 14
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(ctx, S: rect.width)
            return true
        }
        img.isTemplate = true   // transparent + adapts to menu bar appearance
        return img
    }

    /// Design space is 18 wide; everything scales by k = S/18.
    private static func draw(_ ctx: CGContext, S: CGFloat) {
        let k = S / 18.0
        func X(_ v: CGFloat) -> CGFloat { v * k }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))

        func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            ctx.addPath(CGPath(roundedRect: CGRect(x: X(x), y: X(y), width: X(w), height: X(h)),
                               cornerWidth: X(r), cornerHeight: X(r), transform: nil))
            ctx.fillPath()
        }
        func strokeRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ lw: CGFloat) {
            ctx.addPath(CGPath(roundedRect: CGRect(x: X(x), y: X(y), width: X(w), height: X(h)),
                               cornerWidth: X(r), cornerHeight: X(r), transform: nil))
            ctx.setLineWidth(X(lw))
            ctx.strokePath()
        }

        // Three task rows (checkbox + line), y centers from the top.
        let centers: [CGFloat] = [10.4, 6.4, 2.4]
        let box: CGFloat = 3.0
        let lineRights: [CGFloat] = [11.8, 15.2, 13.0]
        for (i, cy) in centers.enumerated() {
            let by = cy - box / 2
            if i == 0 {
                roundRect(0.6, by, box, box, 0.9)            // filled checkbox
            } else {
                strokeRect(0.6, by, box, box, 0.9, 0.7)      // outlined checkbox
            }
            let lx: CGFloat = 4.6
            roundRect(lx, cy - 0.85, lineRights[i] - lx, 1.7, 0.85)
        }

        // Sparkle cluster (top-right): one large + one small 4-point star.
        func star(_ cx: CGFloat, _ cy: CGFloat, _ outer: CGFloat) {
            let inner = outer * 0.36
            let p = CGMutablePath()
            for kk in 0..<4 {
                let a = CGFloat(kk) / 4 * .pi * 2 - .pi / 2
                let tip = CGPoint(x: X(cx) + cos(a) * X(outer), y: X(cy) + sin(a) * X(outer))
                let aP = a - .pi / 4, aN = a + .pi / 4
                let cP = CGPoint(x: X(cx) + cos(aP) * X(inner), y: X(cy) + sin(aP) * X(inner))
                let cN = CGPoint(x: X(cx) + cos(aN) * X(inner), y: X(cy) + sin(aN) * X(inner))
                if kk == 0 { p.move(to: cP) }
                p.addQuadCurve(to: tip, control: CGPoint(x: X(cx) + cos(aP) * X(inner) * 0.5,
                                                         y: X(cy) + sin(aP) * X(inner) * 0.5))
                p.addQuadCurve(to: cN, control: CGPoint(x: X(cx) + cos(aN) * X(inner) * 0.5,
                                                        y: X(cy) + sin(aN) * X(inner) * 0.5))
            }
            p.closeSubpath()
            ctx.addPath(p)
            ctx.fillPath()
        }
        star(15.4, 12.0, 2.7)
        star(13.0, 13.0, 1.3)
    }
}
