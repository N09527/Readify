import CoreGraphics
import Foundation
import UIKit

enum PageCurlRenderer {
    /// Cubic-Bezier(0.22, 0.12, 0.25, 1.0) smooth ease-out curve matching Android's PathInterpolator.
    static func smoothTurnInterpolate(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        if x <= 0 || x >= 1 { return x }
        let p1x: CGFloat = 0.22
        let p1y: CGFloat = 0.12
        let p2x: CGFloat = 0.25
        let p2y: CGFloat = 1.0

        func sampleX(_ u: CGFloat) -> CGFloat {
            let inv = 1 - u
            return 3 * inv * inv * u * p1x + 3 * inv * u * u * p2x + u * u * u
        }

        func sampleY(_ u: CGFloat) -> CGFloat {
            let inv = 1 - u
            return 3 * inv * inv * u * p1y + 3 * inv * u * u * p2y + u * u * u
        }

        var lo: CGFloat = 0
        var hi: CGFloat = 1
        var u = x
        for _ in 0..<12 {
            let est = sampleX(u)
            if abs(est - x) < 1e-4 { break }
            if est < x { lo = u } else { hi = u }
            u = (lo + hi) * 0.5
        }
        return sampleY(u)
    }

    static func drawSlideTransition(
        ctx: CGContext,
        bounds: CGRect,
        curImage: UIImage,
        tgtImage: UIImage,
        touchX: CGFloat,
        fromLeft: Bool
    ) {
        let w = bounds.width
        let h = bounds.height
        tgtImage.draw(in: bounds)

        let offsetX: CGFloat = fromLeft
            ? min(w, max(0, touchX))
            : min(0, max(-w, touchX - w))

        ctx.saveGState()
        ctx.translateBy(x: offsetX, y: 0)
        curImage.draw(in: bounds)
        ctx.restoreGState()

        let shadowEdgeX = fromLeft ? offsetX : (offsetX + w)
        let shadowW: CGFloat = 24
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        ctx.saveGState()
        let shadowRect = fromLeft
            ? CGRect(x: shadowEdgeX - shadowW, y: 0, width: shadowW, height: h)
            : CGRect(x: shadowEdgeX, y: 0, width: shadowW, height: h)
        ctx.clip(to: shadowRect)

        let startColor = fromLeft
            ? UIColor.clear.cgColor
            : UIColor.black.withAlphaComponent(95.0 / 255.0).cgColor
        let endColor = fromLeft
            ? UIColor.black.withAlphaComponent(95.0 / 255.0).cgColor
            : UIColor.clear.cgColor

        let slideLocations: [CGFloat] = [0.0, 1.0]
        if let grad = CGGradient(
            colorsSpace: colorSpace,
            colors: [startColor, endColor] as CFArray,
            locations: slideLocations
        ) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: shadowRect.minX, y: 0),
                end: CGPoint(x: shadowRect.maxX, y: 0),
                options: []
            )
        }
        ctx.restoreGState()
    }

    static func drawRealisticBezierCurl(
        ctx: CGContext,
        bounds: CGRect,
        curImage: UIImage,
        tgtImage: UIImage,
        touchX: CGFloat,
        touchY: CGFloat,
        cornerY: CGFloat,
        fromLeft: Bool,
        isDark: Bool,
        pageBackColor: UIColor
    ) {
        let w = bounds.width
        let h = bounds.height
        let fx: CGFloat = fromLeft ? 0 : w
        let fy: CGFloat = cornerY > 0 ? h : 0

        let distX = abs(fx - touchX)
        if distX < 1.5 {
            curImage.draw(in: bounds)
            return
        }

        let rawDy = abs(fy - touchY)
        let minDy = max(12, min(h * 0.035, distX * 0.12))
        let maxDy = max(minDy + 1, min(h * 0.42, distX * 0.52 + 16))
        let clampedDy = min(maxDy, max(minDy, rawDy))
        let effAy = fy > 0 ? (fy - clampedDy) : (fy + clampedDy)
        let effAx = touchX

        let gx = (effAx + fx) / 2.0
        let gy = (effAy + fy) / 2.0
        let denomX = fx - gx
        let denomY = fy - gy
        if abs(denomX) < 0.5 || abs(denomY) < 0.5 {
            curImage.draw(in: bounds)
            return
        }

        let ex = gx - (denomY * denomY) / denomX
        let ey = fy
        let hx = fx
        let hy = gy - (denomX * denomX) / denomY

        let cx = ex - (fx - ex) / 2.0
        let cy = fy
        let jx = fx
        let jy = hy - (fy - hy) / 2.0

        let bPt = lineIntersect(effAx, effAy, ex, ey, cx, cy, jx, jy)
        let kPt = lineIntersect(effAx, effAy, hx, hy, cx, cy, jx, jy)
        let bx = bPt.x
        let by = bPt.y
        let kx = kPt.x
        let ky = kPt.y

        let dx = (cx + 2 * ex + bx) / 4.0
        let dy = (cy + 2 * ey + by) / 4.0
        let ix = (jx + 2 * hx + kx) / 4.0
        let iy = (jy + 2 * hy + ky) / 4.0

        let mebX = (ex + bx) / 2.0
        let mebY = (ey + by) / 2.0
        let mhkX = (hx + kx) / 2.0
        let mhkY = (hy + ky) / 2.0

        let ux = ix - dx
        let uy = iy - dy
        let uLen = hypot(ux, uy)
        if uLen < 1 {
            curImage.draw(in: bounds)
            return
        }
        var nx = -uy / uLen
        var ny = ux / uLen
        if nx * (fx - dx) + ny * (fy - dy) < 0 {
            nx = -nx
            ny = -ny
        }

        let flapDepth = max(10, abs(nx * (effAx - dx) + ny * (effAy - dy)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Path0: entire lifted region (curled flap + revealed next page)
        let path0 = CGMutablePath()
        path0.move(to: CGPoint(x: jx, y: jy))
        path0.addQuadCurve(to: CGPoint(x: kx, y: ky), control: CGPoint(x: hx, y: hy))
        path0.addLine(to: CGPoint(x: effAx, y: effAy))
        path0.addLine(to: CGPoint(x: bx, y: by))
        path0.addQuadCurve(to: CGPoint(x: cx, y: cy), control: CGPoint(x: ex, y: ey))
        path0.addLine(to: CGPoint(x: fx, y: fy))
        path0.closeSubpath()

        // Path1: curled backside paper flap ONLY (exact De Casteljau shared sub-curves)
        let path1 = CGMutablePath()
        path1.move(to: CGPoint(x: ix, y: iy))
        path1.addLine(to: CGPoint(x: dx, y: dy))
        path1.addQuadCurve(to: CGPoint(x: bx, y: by), control: CGPoint(x: mebX, y: mebY))
        path1.addLine(to: CGPoint(x: effAx, y: effAy))
        path1.addLine(to: CGPoint(x: kx, y: ky))
        path1.addQuadCurve(to: CGPoint(x: ix, y: iy), control: CGPoint(x: mhkX, y: mhkY))
        path1.closeSubpath()

        // 1. Base flat current page
        curImage.draw(in: bounds)

        // 2. Subtle pre-fold shadow outside Path0 (using even-odd clip rule)
        let frontShadowW = min(26, max(10, flapDepth * 0.22))
        let frontLocations: [CGFloat] = [0.0, 0.45, 1.0]
        ctx.saveGState()
        let clipOutPath = CGMutablePath()
        clipOutPath.addRect(bounds.insetBy(dx: -200, dy: -200))
        clipOutPath.addPath(path0)
        ctx.addPath(clipOutPath)
        ctx.clip(using: .evenOdd)

        if let frontGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                UIColor.black.withAlphaComponent(isDark ? (95.0 / 255.0) : (52.0 / 255.0)).cgColor,
                UIColor.black.withAlphaComponent(isDark ? (35.0 / 255.0) : (18.0 / 255.0)).cgColor,
                UIColor.clear.cgColor
            ] as CFArray,
            locations: frontLocations
        ) {
            ctx.drawLinearGradient(
                frontGrad,
                start: CGPoint(x: cx, y: cy),
                end: CGPoint(x: cx - nx * frontShadowW, y: cy - ny * frontShadowW),
                options: [.drawsBeforeStartLocation]
            )
        }
        ctx.restoreGState()

        // 3. Revealed next page + seamless cast shadow strictly along ridge D -> I
        let castW = min(86, max(20, flapDepth * 0.55))
        let underOverlap: CGFloat = 3
        let castLocations: [CGFloat] = [0.0, 0.22, 0.58, 1.0]
        ctx.saveGState()
        ctx.addPath(path0)
        ctx.clip()
        tgtImage.draw(in: bounds)

        if let castGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                UIColor.black.withAlphaComponent(isDark ? (190.0 / 255.0) : (135.0 / 255.0)).cgColor,
                UIColor.black.withAlphaComponent(isDark ? (115.0 / 255.0) : (72.0 / 255.0)).cgColor,
                UIColor.black.withAlphaComponent(isDark ? (42.0 / 255.0) : (22.0 / 255.0)).cgColor,
                UIColor.clear.cgColor
            ] as CFArray,
            locations: castLocations
        ) {
            ctx.drawLinearGradient(
                castGrad,
                start: CGPoint(x: dx - nx * underOverlap, y: dy - ny * underOverlap),
                end: CGPoint(x: dx + nx * castW, y: dy + ny * castW),
                options: [.drawsBeforeStartLocation]
            )
        }
        ctx.restoreGState()

        // 4. Curled paper backside (Path1): paper tint + exact reflected page content + cylindrical shading
        ctx.saveGState()
        ctx.addPath(path1)
        ctx.clip()

        ctx.setFillColor(pageBackColor.cgColor)
        ctx.fill(bounds)

        // Exact reflection across fold line E -> H in UIKit top-left CTM
        ctx.saveGState()
        let angleRad = atan2(hy - ey, hx - ex)
        ctx.translateBy(x: ex, y: ey)
        ctx.rotate(by: angleRad)
        ctx.scaleBy(x: 1, y: -1)
        ctx.rotate(by: -angleRad)
        ctx.translateBy(x: -ex, y: -ey)
        curImage.draw(in: bounds, blendMode: .normal, alpha: isDark ? (36.0 / 255.0) : (48.0 / 255.0))
        ctx.restoreGState()

        let highlightAlpha: CGFloat = isDark ? (20.0 / 255.0) : (56.0 / 255.0)
        let curlLocations: [CGFloat] = [0.0, 0.20, 0.65, 1.0]
        if let curlGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                UIColor.black.withAlphaComponent(isDark ? (130.0 / 255.0) : (88.0 / 255.0)).cgColor,
                UIColor.white.withAlphaComponent(highlightAlpha).cgColor,
                UIColor.clear.cgColor,
                UIColor.black.withAlphaComponent(isDark ? (85.0 / 255.0) : (46.0 / 255.0)).cgColor
            ] as CFArray,
            locations: curlLocations
        ) {
            ctx.drawLinearGradient(
                curlGrad,
                start: CGPoint(x: dx, y: dy),
                end: CGPoint(x: dx - nx * flapDepth, y: dy - ny * flapDepth),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()
    }

    private static func lineIntersect(
        _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
        _ x3: CGFloat, _ y3: CGFloat, _ x4: CGFloat, _ y4: CGFloat
    ) -> CGPoint {
        let denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if abs(denom) < 1e-4 {
            return CGPoint(x: (x1 + x2) * 0.5, y: (y1 + y2) * 0.5)
        }
        let px = ((x1 * y2 - y1 * x2) * (x3 - x4) - (x1 - x2) * (x3 * y4 - y3 * x4)) / denom
        let py = ((x1 * y2 - y1 * x2) * (y3 - y4) - (y1 - y2) * (x3 * y4 - y3 * x4)) / denom
        return CGPoint(x: px, y: py)
    }
}
