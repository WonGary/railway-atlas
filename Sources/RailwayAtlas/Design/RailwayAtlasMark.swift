import SwiftUI

/// Shared vector drawing for the application icon and the in-app mark.
struct RailwayAtlasMark: View {
    var size: CGFloat = 42
    var square = false

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 1024
            context.scaleBy(x: s, y: s)
            let navy = Color(red: 0.055, green: 0.15, blue: 0.25)
            let gold = Color(red: 1, green: 0.73, blue: 0.30)
            let background = square
                ? Path(CGRect(x: 0, y: 0, width: 1024, height: 1024))
                : Path(roundedRect: CGRect(x: 56, y: 56, width: 912, height: 912), cornerRadius: 204)
            context.fill(background, with: .linearGradient(
                Gradient(colors: [Color(red: 0.10, green: 0.25, blue: 0.38), navy]),
                startPoint: CGPoint(x: 100, y: 60), endPoint: CGPoint(x: 800, y: 1000)
            ))
            var route = Path()
            route.move(to: CGPoint(x: 230, y: 800))
            route.addLine(to: CGPoint(x: 613, y: 800))
            route.addCurve(to: CGPoint(x: 802, y: 610),
                           control1: CGPoint(x: 739, y: 800), control2: CGPoint(x: 802, y: 737))
            route.addLine(to: CGPoint(x: 802, y: 297))
            context.stroke(route, with: .color(gold),
                           style: StrokeStyle(lineWidth: 46, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 751, y: 226, width: 102, height: 102)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: 778, y: 253, width: 48, height: 48)), with: .color(gold))

            var train = Path()
            train.move(to: CGPoint(x: 269, y: 302))
            train.addQuadCurve(to: CGPoint(x: 349, y: 222), control: CGPoint(x: 269, y: 222))
            train.addLine(to: CGPoint(x: 529, y: 222))
            train.addQuadCurve(to: CGPoint(x: 609, y: 302), control: CGPoint(x: 609, y: 222))
            train.addLine(to: CGPoint(x: 631, y: 539))
            train.addCurve(to: CGPoint(x: 439, y: 685),
                           control1: CGPoint(x: 640, y: 641), control2: CGPoint(x: 532, y: 685))
            train.addCurve(to: CGPoint(x: 247, y: 539),
                           control1: CGPoint(x: 346, y: 685), control2: CGPoint(x: 238, y: 641))
            train.closeSubpath()
            context.fill(train, with: .color(.white))

            var window = Path()
            window.move(to: CGPoint(x: 327, y: 321))
            window.addQuadCurve(to: CGPoint(x: 349, y: 299), control: CGPoint(x: 327, y: 299))
            window.addLine(to: CGPoint(x: 529, y: 299))
            window.addQuadCurve(to: CGPoint(x: 551, y: 321), control: CGPoint(x: 551, y: 299))
            window.addLine(to: CGPoint(x: 561, y: 407))
            window.addQuadCurve(to: CGPoint(x: 439, y: 435), control: CGPoint(x: 515, y: 435))
            window.addQuadCurve(to: CGPoint(x: 317, y: 407), control: CGPoint(x: 363, y: 435))
            window.closeSubpath()
            context.fill(window, with: .color(navy))
            for x in [315.0, 525.0] {
                context.fill(Path(roundedRect: CGRect(x: x, y: 497, width: 38, height: 23), cornerRadius: 11),
                             with: .color(gold))
            }
            var nose = Path()
            nose.move(to: CGPoint(x: 379, y: 586))
            nose.addQuadCurve(to: CGPoint(x: 499, y: 586), control: CGPoint(x: 439, y: 611))
            context.stroke(nose, with: .color(navy.opacity(0.75)), style: StrokeStyle(lineWidth: 14, lineCap: .round))
            for x in [352.0, 526.0] {
                var rail = Path()
                rail.move(to: CGPoint(x: x, y: 679))
                rail.addLine(to: CGPoint(x: x + (x < 439 ? -26 : 26), y: 730))
                context.stroke(rail, with: .color(.white), style: StrokeStyle(lineWidth: 22, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("铁道图鉴，高铁与线路")
    }
}
