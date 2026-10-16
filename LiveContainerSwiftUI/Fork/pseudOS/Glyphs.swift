//
//  Glyphs.swift
//  pseudOS
//
//  Line glyphs for stock apps and settings rows: drawn on a 24-unit grid, Paper strokes plus one accent detail.
//

import SwiftUI

struct PGlyph: View {
    enum Kind { case settings, browser, store, library, files, gallery, sign, look, multi, advanced, about, key, phone, wallpaper, refresh }

    let kind: Kind
    var size: CGFloat = 30
    var ink: Color = PTheme.paper
    var accent: Color

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx - r) * s, y: (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
            }
            func lines(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                guard let first = pts.first else { return path }
                path.move(to: p(first.0, first.1))
                for pt in pts.dropFirst() { path.addLine(to: p(pt.0, pt.1)) }
                return path
            }
            func seg(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Path { lines([a, b]) }
            func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: r * s)
            }
            let stroke = StrokeStyle(lineWidth: 1.6 * s, lineCap: .round, lineJoin: .round)
            func draw(_ path: Path) { ctx.stroke(path, with: .color(ink), style: stroke) }
            func drawA(_ path: Path) { ctx.stroke(path, with: .color(accent), style: stroke) }
            func fillA(_ path: Path) { ctx.fill(path, with: .color(accent)) }

            switch kind {
            case .settings:
                draw(circle(12, 12, 6.2))
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    draw(seg((12 + cos(a) * 6.8, 12 + sin(a) * 6.8), (12 + cos(a) * 9.2, 12 + sin(a) * 9.2)))
                }
                fillA(circle(12, 12, 2.4))
            case .browser:
                draw(circle(12, 12, 9))
                var top = lines([(12, 4.6), (14.2, 12), (9.8, 12)]); top.closeSubpath(); fillA(top)
                var bottom = lines([(9.8, 12), (14.2, 12), (12, 19.4)]); bottom.closeSubpath()
                ctx.stroke(bottom, with: .color(ink), style: StrokeStyle(lineWidth: 1.2 * s, lineJoin: .round))
            case .store:
                var bag = lines([(5, 9), (19, 9), (17.8, 20), (6.2, 20)]); bag.closeSubpath(); draw(bag)
                var handle = Path()
                handle.move(to: p(9, 9)); handle.addLine(to: p(9, 7.2))
                handle.addArc(center: p(12, 7.2), radius: 3 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                handle.addLine(to: p(15, 9)); drawA(handle)
            case .library:
                var top = lines([(12, 4), (20, 8), (12, 12), (4, 8)]); top.closeSubpath(); drawA(top)
                draw(lines([(4, 12), (12, 16), (20, 12)]))
                draw(lines([(4, 16), (12, 20), (20, 16)]))
            case .files:
                var folder = Path()
                folder.move(to: p(3.5, 7)); folder.addLine(to: p(3.5, 17.5))
                folder.addQuadCurve(to: p(5.2, 19.2), control: p(3.5, 19.2))
                folder.addLine(to: p(18.8, 19.2)); folder.addQuadCurve(to: p(20.5, 17.5), control: p(20.5, 19.2))
                folder.addLine(to: p(20.5, 9.2)); folder.addQuadCurve(to: p(18.8, 7.5), control: p(20.5, 7.5))
                folder.addLine(to: p(11.2, 7.5)); folder.addLine(to: p(9.2, 5.5)); folder.addLine(to: p(5.2, 5.5))
                folder.addQuadCurve(to: p(3.5, 7), control: p(3.5, 5.5)); draw(folder)
                drawA(seg((7, 13), (12, 13)))
            case .gallery, .wallpaper:
                draw(rrect(3.5, 5, 17, 14, 2.5))
                draw(lines([(4, 17), (9, 12), (13, 16), (16, 13), (20, 17)]))
                fillA(circle(16, 9.2, 1.7))
            case .sign:
                var shield = Path()
                shield.move(to: p(12, 3)); shield.addLine(to: p(19, 6)); shield.addLine(to: p(19, 11))
                shield.addQuadCurve(to: p(12, 20.5), control: p(19, 18)); shield.addQuadCurve(to: p(5, 11), control: p(5, 18))
                shield.addLine(to: p(5, 6)); shield.closeSubpath(); draw(shield)
                drawA(lines([(9, 12), (11, 14), (15, 10)]))
            case .look:
                draw(circle(12, 12, 8.5))
                var half = Path()
                half.addArc(center: p(12, 12), radius: 8.5 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                half.closeSubpath(); fillA(half)
            case .multi:
                draw(rrect(4, 5, 9, 14, 2))
                drawA(lines([(16, 7), (18.5, 7), (20, 8.5), (20, 15.5), (18.5, 17), (16, 17)]))
            case .advanced:
                draw(seg((5, 7), (19, 7))); draw(seg((5, 12), (19, 12))); draw(seg((5, 17), (19, 17)))
                fillA(circle(9, 7, 1.8)); fillA(circle(15, 12, 1.8)); fillA(circle(8, 17, 1.8))
            case .about:
                draw(circle(12, 12, 8.5)); draw(seg((12, 11), (12, 16))); fillA(circle(12, 7.8, 1.2))
            case .key:
                draw(circle(8, 15, 4)); drawA(seg((11, 12), (19, 4))); drawA(seg((16, 7), (18, 9)))
            case .phone:
                draw(rrect(7, 3, 10, 18, 2.5)); drawA(seg((10, 6), (14, 6)))
            case .refresh:
                var arc = Path()
                arc.addArc(center: p(12, 12), radius: 7 * s, startAngle: .degrees(-40), endAngle: .degrees(250), clockwise: false)
                draw(arc)
                var head = lines([(17.5, 4.5), (17.4, 8.3), (13.7, 8)]); head = head.strokedPath(StrokeStyle(lineWidth: 1.6 * s, lineCap: .round, lineJoin: .round))
                ctx.fill(head, with: .color(accent))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A stock-app tile: graphite with a bevel, glyph in the middle.
struct PTile<Content: View>: View {
    var size: CGFloat = 60
    @ViewBuilder var content: () -> Content

    var body: some View {
        let r = size * 0.25
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [PTheme.tileTop, PTheme.tileBottom], startPoint: .top, endPoint: .bottom))
            content()
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .overlay(PBevel(cornerRadius: r))
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
    }
}

/// The machined edge: a light top line and a dark bottom line, shared by stock and guest icons.
struct PBevel: View {
    let cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.22), location: 0),
                    .init(color: .white.opacity(0.04), location: 0.12),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.35), location: 1),
                ], startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// Icon for any home item: stock tile or the guest app's own icon masked to the same shape.
struct PAppIcon: View {
    let item: HomeItem
    var size: CGFloat = 60
    let accent: Color
    var darkIcon = false

    var body: some View {
        switch item {
        case .system(let s):
            PTile(size: size) { PGlyph(kind: s.glyph, size: size * 0.5, accent: accent) }
        case .guest(let path):
            let r = size * 0.25
            Group {
                if let img = ShellModel.shared.appModel(for: path)?.appInfo.iconIsDarkIcon(darkIcon) {
                    Image(uiImage: img).resizable().interpolation(.high)
                } else {
                    PTheme.tileBottom
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay(PBevel(cornerRadius: r))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
        }
    }
}
