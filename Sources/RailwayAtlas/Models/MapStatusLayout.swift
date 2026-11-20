import Foundation

/// Fits a floating card into measured free space. Narrow maps use a shorter
/// scrollable card below the controls instead of covering the scale.
struct MapStatusLayout {
    let frame: CGRect
    private(set) var anchor: CGPoint

    init(viewport: CGSize, desired: CGSize, scale: Double, offset: CGSize, obstacles: [CGRect]) {
        let margin = 20 * scale, gap = 8 * scale
        let area = CGRect(origin: .zero, size: viewport).insetBy(dx: margin, dy: margin)
        let width = max(0, min(desired.width, area.width))
        anchor = CGPoint(x: area.maxX - width, y: area.minY)
        let wanted = CGPoint(x: anchor.x + offset.width, y: anchor.y + offset.height)
        guard width > 0, area.height > 0 else { frame = .zero; return }
        let blocked = obstacles.filter { !$0.isEmpty }.map {
            $0.insetBy(dx: -gap, dy: -gap).intersection(area)
        }.filter { !$0.isNull && !$0.isEmpty }
        func clampX(_ x: Double) -> Double { max(area.minX, min(area.maxX - width, x)) }
        let xs = Set([clampX(wanted.x), area.minX, area.maxX - width]
            + blocked.flatMap { [clampX($0.minX - width), clampX($0.maxX)] })
        var spaces: [CGRect] = []
        for x in xs.sorted() {
            let intervals = blocked.filter { $0.minX < x + width - 0.01 && $0.maxX > x + 0.01 }
                .sorted { $0.minY < $1.minY }
            var top = area.minY
            for rect in intervals {
                if rect.minY > top { spaces.append(CGRect(x: x, y: top, width: width, height: rect.minY - top)) }
                top = max(top, rect.maxY)
            }
            if top < area.maxY { spaces.append(CGRect(x: x, y: top, width: width, height: area.maxY - top)) }
        }
        let height = max(0, min(desired.height, spaces.map(\.height).max() ?? 0))
        if height < min(desired.height, 100 * scale), width > 120 * scale {
            let narrower = MapStatusLayout(viewport: viewport,
                desired: CGSize(width: max(120 * scale, width * 0.75), height: desired.height),
                scale: scale, offset: offset, obstacles: obstacles)
            if narrower.frame.height > height { self = narrower; return }
        }
        let candidates = spaces.filter { $0.height >= height }.map {
            CGRect(x: $0.minX, y: max($0.minY, min($0.maxY - height, wanted.y)), width: width, height: height)
        }
        func distance(_ rect: CGRect) -> Double { pow(rect.minX - wanted.x, 2) + pow(rect.minY - wanted.y, 2) }
        frame = candidates.min { distance($0) < distance($1) } ?? .zero
    }
}
