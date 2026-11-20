import MapKit
import RailwayCore
import SwiftUI

enum StationLabelStyle {
    static func emphasized(_ kind: StationKind) -> Bool {
        [.major, .connection, .interchange].contains(kind)
    }
    static func size(_ kind: StationKind, selected: Bool = false) -> Double {
        selected ? 14 : emphasized(kind) ? 13 : 12.5
    }
    static func font(_ kind: StationKind, selected: Bool = false) -> AtlasFont {
        .system(size: size(kind, selected: selected), weight: emphasized(kind) || selected ? .semibold : .medium)
    }
}

/// Glyph radius is in map points, independent of interface text scaling.
enum StationSymbol {
    #if os(macOS)
    typealias Image = NSImage
    #else
    typealias Image = UIImage
    #endif
    @MainActor private static let images: NSCache<NSString, Image> = {
        let cache = NSCache<NSString, Image>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 1000
        return cache
    }()
    @MainActor static func image(_ style: StationAppearance, title: String?,
                                 uiScale: Double = 1, displayScale: Double = 2, lightText: Bool = false) -> Image {
        let side = max(24 * uiScale, ceil(style.radius * 2 + 4))
        let size = CGSize(width: side + (title == nil ? 0 : 148 * uiScale), height: side)
        let density = max(1, displayScale)
        let key = "\(style.kind)|\(style.radius)|\(style.filled)|\(style.doubleRing)|\(style.colors.map(\.hex).joined())|\(title ?? "")|\(uiScale)|\(density)|\(lightText)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        #if os(macOS)
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * density)), pixelsHigh: Int(ceil(size.height * density)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        // Bitmap contexts use pixels. Draw directly at the target density.
        graphics.cgContext.scaleBy(x: density, y: density)
        draw(style, title: title, context: graphics.cgContext, scale: uiScale, side: side, lightText: lightText)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = density
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            draw(style, title: title, context: renderer.cgContext, scale: uiScale, side: side, lightText: lightText)
        }
        #endif
        images.setObject(image, forKey: key, cost: Int(ceil(size.width * density) * ceil(size.height * density)) * 4)
        return image
    }

    @MainActor private static func draw(_ style: StationAppearance, title: String?, context: CGContext,
                                       scale: Double, side: Double, lightText: Bool) {
        let center = CGPoint(x: side / 2, y: side / 2), radius = style.radius
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(CGColor(gray: 1, alpha: 0.97))
        context.fillEllipse(in: rect)
        if style.filled {
            let color = style.colors[0].rgb
            context.setFillColor(CGColor(red: color.red, green: color.green, blue: color.blue, alpha: 1))
            context.fillEllipse(in: rect)
        }
        context.setLineWidth(style.ringWidth)
        for (index, colour) in style.colors.enumerated() {
            let rgb = colour.rgb
            context.setStrokeColor(CGColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1))
            context.addArc(center: center, radius: radius - style.ringWidth / 2,
                           startAngle: Double(index) / Double(style.colors.count) * 2 * .pi,
                           endAngle: Double(index + 1) / Double(style.colors.count) * 2 * .pi, clockwise: false)
            context.strokePath()
        }
        if style.doubleRing {
            context.setStrokeColor(CGColor(gray: style.filled ? 1 : 0.3, alpha: 1))
            context.setLineWidth(style.ringWidth * 0.5)
            context.strokeEllipse(in: rect.insetBy(dx: radius * 0.55, dy: radius * 0.55))
        }
        if let title {
            let font = PlatformFont.systemFont(ofSize: StationLabelStyle.size(style.kind) * scale,
                                              weight: StationLabelStyle.emphasized(style.kind) ? .semibold : .medium)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let shadow = NSShadow()
            shadow.shadowColor = (lightText ? PlatformColor.black : .white).withAlphaComponent(lightText ? 0.65 : 0.75)
            shadow.shadowBlurRadius = 1.5 * scale
            shadow.shadowOffset = .zero
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: lightText ? PlatformColor.lightStationLabel : .darkStationLabel,
                .paragraphStyle: paragraph,
                .shadow: shadow
            ]
            let text = title as NSString
            let height = ceil(text.size(withAttributes: attributes).height)
            let frame = CGRect(x: center.x + radius + 4 * scale, y: center.y - height / 2,
                               width: 140 * scale, height: height)
            // Solid glyphs only. A soft shadow supplies local contrast without
            // a box, speech bubble or stroke inside the letter shapes.
            text.draw(in: frame, withAttributes: attributes)
        }
    }
}

#if os(macOS)
private typealias PlatformFont = NSFont
extension NSColor {
    fileprivate static var darkStationLabel: NSColor { NSColor(calibratedWhite: 0.18, alpha: 1) }
    fileprivate static var lightStationLabel: NSColor { NSColor(calibratedWhite: 0.9, alpha: 1) }
}
#else
private typealias PlatformFont = UIFont
extension UIColor {
    fileprivate static var darkStationLabel: UIColor { UIColor(white: 0.18, alpha: 1) }
    fileprivate static var lightStationLabel: UIColor { UIColor(white: 0.9, alpha: 1) }
}
#endif
