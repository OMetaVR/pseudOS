//
//  Wallpaper.swift
//  pseudOS
//
//  Seeded contour-line ("pseudo-terrain") wallpaper, rendered once per seed/size/appearance.
//

import UIKit

enum PWallpaper {
    private static var cache: (key: String, image: UIImage)?

    static func image(seed: UInt32, size: CGSize, dark: Bool, accent: UIColor, scale: CGFloat = UIScreen.main.scale) -> UIImage {
        let key = "\(seed)-\(Int(size.width))x\(Int(size.height))-\(dark)-\(accent.description)"
        if let cache, cache.key == key { return cache.image }
        let img = render(seed: seed, size: size, dark: dark, accent: accent, scale: min(scale, 3))
        cache = (key, img)
        return img
    }

    private static func render(seed: UInt32, size: CGSize, dark: Bool, accent: UIColor, scale: CGFloat) -> UIImage {
        let W = size.width, H = size.height
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = scale; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { rc in
            let g = rc.cgContext
            // Base gradient
            let top = dark ? UIColor(hex: 0x232931) : UIColor(hex: 0xEEF1F4)
            let bottom = dark ? UIColor(hex: 0x181C21) : UIColor(hex: 0xE2E7EC)
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: H), options: [])
            }

            // Seeded value noise, four octaves
            var s = seed == 0 ? 1 : seed
            func rnd() -> Double { s = s &* 1664525 &+ 1013904223; return Double(s) / 4294967296.0 }
            let N = 64
            var grid = [Double](repeating: 0, count: N * N)
            for i in 0..<grid.count { grid[i] = rnd() }
            func sm(_ t: Double) -> Double { t * t * (3 - 2 * t) }
            func vn(_ x: Double, _ y: Double) -> Double {
                let xi = Int(floor(x)), yi = Int(floor(y))
                let xf = sm(x - floor(x)), yf = sm(y - floor(y))
                func v(_ i: Int, _ j: Int) -> Double { grid[((j & 63) * N) + (i & 63)] }
                let a = v(xi, yi), b = v(xi + 1, yi), c = v(xi, yi + 1), d = v(xi + 1, yi + 1)
                return a + (b - a) * xf + (c - a) * yf + (a - b - c + d) * xf * yf
            }
            let ox = rnd() * 40, oy = rnd() * 40
            func f(_ x: Double, _ y: Double) -> Double {
                var t = 0.0, amp = 0.55, fr = 1.0 / 150.0
                for _ in 0..<4 { t += amp * vn(x * fr + ox, y * fr + oy); amp *= 0.5; fr *= 2.03 }
                return t
            }

            let cs: CGFloat = 6
            let cols = Int(ceil(W / cs)) + 1, rows = Int(ceil(H / cs)) + 1
            var F = [Double](repeating: 0, count: cols * rows)
            var mn = 9.0, mx = -9.0, pk = -9.0
            var peak = CGPoint(x: W / 2, y: H / 2)
            for j in 0..<rows {
                for i in 0..<cols {
                    let x = CGFloat(i) * cs, y = CGFloat(j) * cs
                    let v = f(Double(x), Double(y))
                    F[j * cols + i] = v
                    mn = min(mn, v); mx = max(mx, v)
                    // The summit mark stays clear of the edges, the clock and the dock.
                    if v > pk && x > 40 && x < W - 70 && y > H * 0.31 && y < H - 160 { pk = v; peak = CGPoint(x: x, y: y) }
                }
            }

            let levels = 22
            let step = (mx - mn) / Double(levels)
            g.setLineCap(.round)
            for L in 1..<levels {
                let iso = mn + Double(L) * step
                let index = L % 5 == 0
                let color = dark
                    ? UIColor(red: 201 / 255, green: 209 / 255, blue: 217 / 255, alpha: index ? 0.20 : 0.085)
                    : UIColor(red: 30 / 255, green: 35 / 255, blue: 41 / 255, alpha: index ? 0.22 : 0.10)
                g.setStrokeColor(color.cgColor)
                g.setLineWidth(index ? 1.1 : 0.8)
                g.beginPath()
                for j in 0..<(rows - 1) {
                    for i in 0..<(cols - 1) {
                        let a = F[j * cols + i], b = F[j * cols + i + 1]
                        let c = F[(j + 1) * cols + i + 1], d = F[(j + 1) * cols + i]
                        let k = (a > iso ? 1 : 0) | (b > iso ? 2 : 0) | (c > iso ? 4 : 0) | (d > iso ? 8 : 0)
                        if k == 0 || k == 15 { continue }
                        let x = CGFloat(i) * cs, y = CGFloat(j) * cs
                        func lerp(_ p: Double, _ q: Double) -> CGFloat { CGFloat((iso - p) / (q - p)) }
                        let T = CGPoint(x: x + cs * lerp(a, b), y: y)
                        let R = CGPoint(x: x + cs, y: y + cs * lerp(b, c))
                        let B = CGPoint(x: x + cs * lerp(d, c), y: y + cs)
                        let Lp = CGPoint(x: x, y: y + cs * lerp(a, d))
                        func seg(_ p: CGPoint, _ q: CGPoint) { g.move(to: p); g.addLine(to: q) }
                        switch k {
                        case 1, 14: seg(Lp, T)
                        case 2, 13: seg(T, R)
                        case 3, 12: seg(Lp, R)
                        case 4, 11: seg(R, B)
                        case 5: seg(Lp, T); seg(R, B)
                        case 6, 9: seg(T, B)
                        case 7, 8: seg(Lp, B)
                        case 10: seg(T, R); seg(Lp, B)
                        default: break
                        }
                    }
                }
                g.strokePath()
            }

            // The summit mark: the one accent detail.
            g.setStrokeColor(accent.cgColor); g.setLineWidth(1.4)
            g.move(to: CGPoint(x: peak.x - 6, y: peak.y)); g.addLine(to: CGPoint(x: peak.x + 6, y: peak.y))
            g.move(to: CGPoint(x: peak.x, y: peak.y - 6)); g.addLine(to: CGPoint(x: peak.x, y: peak.y + 6))
            g.strokePath()
            let label = String(1000 + Int(seed % 3000)) as NSString
            label.draw(at: CGPoint(x: peak.x + 8, y: peak.y - 18),
                       withAttributes: [.font: PFont.uiGeist(10, .medium), .foregroundColor: accent])
        }
    }
}
