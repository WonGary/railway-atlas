import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The two providers use OpenMapTiles and Shortbread respectively. Keep the
/// drawing order independent of how layers were serialized in the MVT.
public struct StreetBasemapTile: Sendable {
    private static let areas = ["land", "landuse", "landcover", "park", "sites", "ocean", "water", "water_polygons", "street_polygons", "building", "buildings"]
    private static let lines = ["waterway", "water_lines", "ferries", "boundary", "boundaries", "transportation", "streets"]
    private static let names = ["place", "place_labels", "water_name", "water_polygons_labels", "water_lines_labels", "transportation_name", "street_labels", "street_labels_points"]
    private struct Shape: Sendable {
        let paths: [[CGPoint]]
        let bounds: CGRect
        let kind: String
        let label: String
        let rank: Int
    }
    private var layers: [String: [Shape]] = [:]
    public private(set) var pointCount = 0
    private static let invalid = DataError.invalid("街道底图瓦片损坏或过大")
    public init(_ data: Data) throws {
        guard data.count <= VectorTileDecoder.maxBytes else { throw Self.invalid }
        var tile = ProtoReader(data)
        while let field = try tile.field() {
            if field == 26 { try readLayer(tile.bytes()) }
            else { try tile.skip(field & 7) }
        }
    }
    private mutating func readLayer(_ bytes: Data) throws {
        var r = ProtoReader(bytes), name = "", extent = 4096
        var keys = [String](), values = [String](), features = [Data]()
        while let field = try r.field() {
            switch field {
            case 10: name = try r.string()
            case 18: features.append(try r.bytes())
            case 26: keys.append(try r.string())
            case 34: values.append(try VectorTileDecoder.value(r.bytes()))
            case 40:
                let n = try r.varint()
                guard (1...65536).contains(n) else { throw Self.invalid }
                extent = Int(n)
            default: try r.skip(field & 7)
            }
            guard features.count <= 100_000, keys.count <= 10_000, values.count <= 500_000 else { throw Self.invalid }
        }
        let area = Self.areas.contains(name), line = Self.lines.contains(name), label = Self.names.contains(name)
        guard area || line || label else { return }
        for feature in features {
            var item = ProtoReader(feature), tags = [String:String](), kind: UInt64 = 0, bytes = Data()
            while let field = try item.field() {
                switch field {
                case 18:
                    var pairs = ProtoReader(try item.bytes())
                    while !pairs.isAtEnd {
                        let k = try pairs.varint(), v = try pairs.varint()
                        guard k < keys.count, v < values.count else { throw Self.invalid }
                        tags[keys[Int(k)]] = values[Int(v)]
                    }
                case 24: kind = try item.varint()
                case 34: bytes = try item.bytes()
                default: try item.skip(field & 7)
                }
            }
            guard label || (area && kind == 3) || (line && kind == 2) else { continue }
            let text = ["name:zh-Hans","name_zh-Hans","name:zh","name_zh","name","name:en","name_en"].compactMap { tags[$0] }.first ?? ""
            if label && text.isEmpty { continue }
            var geometry = ProtoReader(bytes), paths = [[CGPoint]](), path = [CGPoint](), bounds = CGRect.null
            var x: Int64 = 0, y: Int64 = 0
            while !geometry.isAtEnd {
                let command = try geometry.varint(), count = command >> 3, op = command & 7
                if op == 7 && count == 1 { continue }
                guard (op == 1 || op == 2), count > 0, count <= 600_000 - pointCount else { throw Self.invalid }
                for _ in 0..<count {
                    if op == 1 && !path.isEmpty { paths.append(path); path = [] }
                    let dx = try geometry.signed(), dy = try geometry.signed()
                    guard absBound(dx), absBound(dy) else { throw Self.invalid }
                    x += dx; y += dy
                    guard absBound(x), absBound(y) else { throw Self.invalid }
                    let point = CGPoint(x: Double(x) / Double(extent), y: Double(y) / Double(extent))
                    bounds = bounds.union(CGRect(origin: point, size: .zero))
                    path.append(point)
                    pointCount += 1
                }
            }
            if !path.isEmpty { paths.append(path) }
            if !paths.isEmpty {
                let category = tags["class"] ?? tags["subclass"] ?? tags["kind"] ?? tags["type"] ?? name
                layers[name, default: []].append(Shape(paths: paths, bounds: bounds, kind: category,
                    label: String(text.prefix(100)), rank: Int(tags["rank"] ?? "") ?? 20))
            }
        }
    }
    private func absBound(_ n: Int64) -> Bool { (-10_000_000...10_000_000).contains(n) }

    public func png(zoom: Int, column: Int, row: Int, dark: Bool, retina: Bool) throws -> Data {
        guard (0...19).contains(zoom), column >= 0, row >= 0,
              column < 1 << zoom, row < 1 << zoom else { throw Self.invalid }
        let subdivisions = 1 << max(0, zoom - 14), side = CGFloat(256 * subdivisions)
        let origin = CGPoint(x: (column % subdivisions) * 256, y: (row % subdivisions) * 256)
        let clip = CGRect(x:(origin.x - 8)/side, y:(origin.y - 8)/side, width:272/side, height:272/side)
        let pixels = retina ? 512 : 256, density = CGFloat(pixels) / 256
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data:nil, width:pixels, height:pixels, bitsPerComponent:8, bytesPerRow:pixels * 4,
                                  space:space, bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Self.invalid }
        ctx.translateBy(x:0,y:CGFloat(pixels)); ctx.scaleBy(x:density,y:-density)
        func color(_ light: UInt32, _ night: UInt32) -> CGColor {
            let c = dark ? night : light
            return CGColor(srgbRed:CGFloat(c >> 16)/255, green:CGFloat(c >> 8 & 255)/255, blue:CGFloat(c & 255)/255, alpha:1)
        }
        let land = color(0xedf0eb,0x27312f), park = color(0xdcebd3,0x2d4a3b), water = color(0xb9d7e6,0x1e4556)
        let residential = color(0xece9e4,0x353a38), road = color(0xfffdf8,0x6f7772), casing = color(0xd8d4ce,0x1b2424)
        ctx.setFillColor(land); ctx.fill(CGRect(x:0,y:0,width:256,height:256))
        func position(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x * side - origin.x,y:p.y * side - origin.y) }
        func path(_ f: Shape, close: Bool) -> CGPath {
            let path = CGMutablePath()
            for part in f.paths where !part.isEmpty {
                path.move(to:position(part[0]))
                for p in part.dropFirst() { path.addLine(to:position(p)) }
                if close { path.closeSubpath() }
            }
            return path
        }
        for layer in Self.areas {
            for shape in layers[layer] ?? [] where clip.intersects(shape.bounds.insetBy(dx:-0.000001,dy:-0.000001)) {
                let c: CGColor
                switch (layer,shape.kind) {
                case ("ocean",_): c = color(0xc7dce7,0x182c39)
                case ("water",_),("water_polygons",_): c = water
                case ("building",_),("buildings",_): c = color(0xd8d5d0,0x555550)
                case (_,"forest"),(_,"wood"): c = color(0xd3e5c8,0x345342)
                case ("park",_),(_,"grass"),(_,"park"),(_,"scrub"),(_,"wetland"),(_,"grassland"): c = park
                case (_,"farmland"),(_,"orchard"),(_,"meadow"): c = color(0xe9edcf,0x4a4b38)
                case (_,"commercial"),(_,"industrial"),(_,"retail"): c = color(0xe4e0d9,0x41403b)
                case ("landuse",_),(_,"residential"): c = residential
                default: c = land
                }
                ctx.setFillColor(c); ctx.addPath(path(shape,close:true)); ctx.drawPath(using:.eoFill)
            }
        }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for layer in Self.lines {
            for shape in layers[layer] ?? [] where clip.intersects(shape.bounds.insetBy(dx:-0.000001,dy:-0.000001)) {
                let c: CGColor, width: CGFloat
                let z = CGFloat(zoom)
                switch (layer,shape.kind) {
                case ("boundaries",_),("boundary",_): c = color(0xa99e9a,0x8e9b96); width = 0.8
                case ("waterway",_),("water_lines",_),("ferries",_): c = color(0x77aec4,0x6da8bb); width = max(0.7,(z-4)*0.14)
                case (_,"motorway"),(_,"trunk"): c = color(0xedb36c,0xc18d55); width = min(4.1,1.5+(z-5)*0.22)
                case (_,"primary"): c = color(0xf0cc8f,0xc7a46e); width = min(3.4,1.2+(z-5)*0.19)
                case (_,"secondary"),(_,"tertiary"): c = color(0xf7e0ad,0x9a9c8e); width = min(2.6,0.9+(z-6)*0.15)
                case (_,"rail"),(_,"subway"),(_,"transit"): c = color(0xb98b79,0xc79b82); width = 1
                default: c = road; width = max(0.5,min(2.2,0.55+(z-7)*0.12))
                }
                let line = path(shape,close:false)
                ctx.addPath(line); ctx.setStrokeColor(casing); ctx.setLineWidth(width+0.65); ctx.strokePath()
                ctx.addPath(line); ctx.setStrokeColor(c); ctx.setLineWidth(width); ctx.strokePath()
            }
        }
        let ink = color(0x39474c,0xe2e7df), halo = color(0xffffff,0x141c1d)
        let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, zoom >= 12 ? 10 : 11,nil)
        var occupied: [CGRect] = []
        for layer in Self.names {
            guard zoom >= (layer.contains("place") ? 4 : layer.contains("water") ? 7 : 10) else { continue }
            for shape in (layers[layer] ?? []).sorted(by:{ $0.rank < $1.rank }) where occupied.count < 32 {
                guard let part = shape.paths.first else { continue }
                let p = position(part[part.count / 2])
                guard (0..<256).contains(p.x), (8..<248).contains(p.y) else { continue }
                let attrs: [NSAttributedString.Key:Any] = [.init(kCTFontAttributeName as String):font,
                    .init(kCTForegroundColorFromContextAttributeName as String):true]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string:shape.label,attributes:attrs))
                let w = CTLineGetTypographicBounds(line,nil,nil,nil)
                let box = CGRect(x:p.x - w/2 - 3, y:p.y - 7, width:w + 6, height:14)
                guard box.minX >= 0, box.maxX <= 256, !occupied.contains(where:{$0.intersects(box)}) else { continue }
                occupied.append(box)
                ctx.saveGState(); ctx.translateBy(x:p.x-w/2,y:p.y+3); ctx.scaleBy(x:1,y:-1)
                ctx.textMatrix = .identity; ctx.textPosition = .zero; ctx.setTextDrawingMode(.fillStroke)
                ctx.setLineWidth(2); ctx.setStrokeColor(halo); ctx.setFillColor(ink); CTLineDraw(line,ctx)
                ctx.textPosition = .zero; ctx.setTextDrawingMode(.fill); CTLineDraw(line,ctx); ctx.restoreGState()
            }
        }
        let data = NSMutableData()
        guard let image = ctx.makeImage(), let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString,1,nil) else { throw Self.invalid }
        CGImageDestinationAddImage(dst,image,nil)
        guard CGImageDestinationFinalize(dst) else { throw Self.invalid }
        return data as Data
    }
}
