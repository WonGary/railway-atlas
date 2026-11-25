import CryptoKit
import RailwayCore
import SwiftUI

struct CardGeography: Decodable, Sendable {
    struct City: Decodable, Sendable { let name: String; let lat, lon: Double }
    struct Province: Decodable, Sendable {
        let name: String
        let lat, lon: Double
        let bounds: [Double], anchors: [[Double]], rings: [[[Double]]]
        func contains(_ latitude: Double, _ longitude: Double) -> Bool {
            guard bounds.count == 4, (bounds[0]...bounds[2]).contains(latitude),
                  (bounds[1]...bounds[3]).contains(longitude) else { return false }
            var inside = false
            for ring in rings {
                for (a,b) in zip(ring,ring.dropFirst()) where (a[0]>latitude) != (b[0]>latitude) {
                    if longitude < a[1]+(b[1]-a[1])*(latitude-a[0])/(b[0]-a[0]) { inside.toggle() }
                }
            }
            return inside
        }
    }
    let cities: [City]
    let coastLines, hainan: [Contours.Run]
    static var credit: String {
        Contours.shared == nil ? "Natural Earth" : "天地图 / 干旱区生态与资源科学数据中心 · Natural Earth"
    }
    struct Contours: Decodable, Sendable {
        struct Run: Decodable, Sendable { let bounds: [Double]; let points: [[Double]] }
        struct Source: Decodable, Sendable { let inputSHA256: String }
        let edition: String
        let source: Source
        let settled, undelimited, provinceLines, coastLines, hainan: [Run]
        let provinces: [Province]
        static let shared: Self? = {
            let url = MapContextFiles.directory.appendingPathComponent("card-contours.json")
            guard let data = try? Data(contentsOf: url), data.count == 1_368_598,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() ==
                    "bc57f2b0b12869061a936ddac2167d32c661807bd4d1b44e8923dea40a0ce6be",
                  let item = try? JSONDecoder().decode(Self.self, from: data),
                  item.edition == "tdt-2026-10-route-1",
                  item.source.inputSHA256 == "3af8294f9ad61cc2bf84c1bb7e4bbf86a6336c68d754b699a0e6ddc33ef81486"
            else { return nil }
            return item
        }()
    }
    static let shared: CardGeography? = {
        let url = MapContextFiles.directory.appendingPathComponent("card-geography.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }()
}

struct JourneyContextMap: View {
    let legs: [[Coordinate]]
    let from, to: String
    let ink, paper: Color
    var stations: [String] = []

    var body: some View {
        Canvas { context, size in
            guard let start = legs.first?.first, let end = legs.last?.last else { return }
            let points = legs.flatMap { $0 }
            let bounds = MapBounds(points: points)
            let center = bounds.center
            let cosine = max(0.1, cos(center.latitude * .pi / 180))
            let small = size.width < 215 || size.height < 90
            let scale = min((size.width-(small ? 20 : 54))/max(0.012,(bounds.east-bounds.west)*cosine),
                            (size.height-(small ? 17 : 36))/max(0.012,bounds.north-bounds.south))
            guard scale > 0 else { return }
            func project(_ lat: Double, _ lon: Double) -> CGPoint {
                CGPoint(x:size.width/2+(lon-center.longitude)*cosine*scale,
                        y:size.height/2-(lat-center.latitude)*scale)
            }
            let screen = CGRect(origin:.zero,size:size)
            context.clip(to:Path(screen))
            func path(_ parts: [[CGPoint]]) -> Path {
                Path { output in
                    for part in parts {
                        guard let first = part.first else { continue }
                        output.move(to:first)
                        for p in part.dropFirst() { output.addLine(to:p) }
                    }
                }
            }
            let geography = CardGeography.shared
            let contours = CardGeography.Contours.shared
            let halfLat = size.height / (2 * scale), halfLon = size.width / (2 * scale * cosine)
            func geographyPath(_ runs: [CardGeography.Contours.Run]) -> Path {
                path(runs.compactMap { run in
                    let b = run.bounds
                    guard b[0] <= center.latitude + halfLat, b[2] >= center.latitude - halfLat,
                          b[1] <= center.longitude + halfLon, b[3] >= center.longitude - halfLon else { return nil }
                    return run.points.map { project($0[0], $0[1]) }
                })
            }
            let coastWidth: CGFloat = small ? 0.65 : 0.9
            if let coast = contours?.coastLines ?? geography?.coastLines,
               let hainan = contours?.hainan ?? geography?.hainan {
                context.stroke(geographyPath(coast), with:.color(ink.opacity(0.46)), lineWidth:coastWidth)
                var shore = context
                if center.latitude-halfLat <= 18.163 && center.latitude+halfLat >= 20.16 &&
                    center.longitude-halfLon <= 108.615 && center.longitude+halfLon >= 111.03 {
                    let top = project(bounds.north+0.018,center.longitude).y
                    let bottom = project(bounds.south-0.018,center.longitude).y
                    shore.clip(to:Path(CGRect(x:0,y:top,width:size.width,height:bottom-top)))
                }
                shore.stroke(geographyPath(hainan), with:.color(ink.opacity(0.58)), lineWidth:coastWidth)
            }
            if let contours {
                context.stroke(geographyPath(contours.provinceLines), with:.color(ink.opacity(0.41)),
                               style:StrokeStyle(lineWidth:coastWidth,dash:small ? [2,2] : [3,3]))
                let weight: CGFloat = small ? 1.05 : 1.45
                context.stroke(geographyPath(contours.settled), with:.color(ink.opacity(0.82)),
                               style:StrokeStyle(lineWidth:weight,lineCap:.round,lineJoin:.round,dash:small ? [5,2,1,2] : [7,2,1.2,2]))
                context.stroke(geographyPath(contours.undelimited), with:.color(ink.opacity(0.82)),
                               style:StrokeStyle(lineWidth:weight,lineCap:.round,lineJoin:.round,dash:small ? [4,3] : [6,4]))
            }
            let tracks = legs.map { $0.map { project($0.latitude,$0.longitude) } }
            let route = path(tracks), weight: CGFloat = small ? 1.9 : 3
            context.stroke(route, with:.color(paper),style:StrokeStyle(lineWidth:weight+2,lineCap:.round,lineJoin:.round))
            context.stroke(route, with:.color(ink),style:StrokeStyle(lineWidth:weight,lineCap:.round,lineJoin:.round))
            let first = project(start.latitude,start.longitude), last = project(end.latitude,end.longitude)
            func dot(_ p: CGPoint, _ radius: CGFloat, _ fill: Color) {
                let ring = Path(ellipseIn:CGRect(x:p.x-radius,y:p.y-radius,width:2*radius,height:2*radius))
                context.fill(ring,with:.color(fill)); context.stroke(ring,with:.color(ink),lineWidth:1.3)
            }
            dot(first,small ? 2.4 : 3.7,paper); dot(last,small ? 2.4 : 3.7,ink)
            var used = [CGRect](), labels = Set<String>()
            let font: CGFloat = small ? 8.5 : 12.5
            @discardableResult func label(_ name: String, at p: CGPoint) -> Bool {
                guard !name.isEmpty, !labels.contains(name) else { return false }
                let text = Text(verbatim:name).font(.system(size:font,weight:.semibold))
                let resolved = context.resolve(text.foregroundStyle(ink))
                let measured = resolved.measure(in: size)
                for delta in [CGPoint(x:6,y:0),CGPoint(x:-measured.width-6,y:0),
                              CGPoint(x:4,y:-font-2),CGPoint(x:-measured.width-4,y:font+2)] {
                    let x = max(2,min(size.width-measured.width-2,p.x+delta.x))
                    let y = max(1,min(size.height-measured.height-1,p.y+delta.y-measured.height/2))
                    let rect = CGRect(origin:CGPoint(x:x,y:y),size:measured)
                    guard !used.contains(where: { $0.intersects(rect.insetBy(dx:-2,dy:-1)) }) else { continue }
                    used.append(rect); labels.insert(name)
                    let halo=context.resolve(text.foregroundStyle(paper))
                    for offset in [CGPoint(x:0,y:1),CGPoint(x:0,y:-1),CGPoint(x:1,y:0),CGPoint(x:-1,y:0)] {
                        context.draw(halo,at:CGPoint(x:x+offset.x,y:y+offset.y),anchor:.topLeading)
                    }
                    context.draw(resolved,at:rect.origin,anchor:.topLeading)
                    return true
                }
                return false
            }
            label(from,at:first); label(to,at:last)
            if !small && max(bounds.north-bounds.south,(bounds.east-bounds.west)*cosine)<0.85
                && stations.count == legs.count+1 {
                for i in legs.indices.dropFirst() where labels.count < 8 {
                    if let p=tracks[i].first, label(stations[i],at:p) { dot(p,2.5,paper) }
                }
            }
            func nearRoute(_ p: CGPoint, within distance: Double) -> Bool {
                tracks.contains { line in
                    zip(line,line.dropFirst()).contains { a,b in
                        let dx=b.x-a.x, dy=b.y-a.y
                        let t=max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/max(0.000001,dx*dx+dy*dy)))
                        return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy) <= distance
                    }
                }
            }
            if !small {
                let stride = max(1,(points.count+39)/40)
                let sample = points.enumerated().compactMap { i,p in i%stride == 0 || i == points.count-1 ? p : nil }
                for province in contours?.provinces ?? [] {
                    let visited = sample.filter { province.contains($0.latitude,$0.longitude) }
                    guard !visited.isEmpty else { continue }
                    let text = context.resolve(Text(verbatim:province.name).font(.system(size:font+1,design:.serif)).foregroundStyle(ink.opacity(0.77)))
                    let dim = text.measure(in:size)
                    var anchors = [[province.lat,province.lon]] + province.anchors
                    let mid = visited[visited.count/2]
                    for (dx,dy): (Double,Double) in [(-1,1),(1,1),(-1,-1),(1,-1),(0,1),(0,-1)] {
                        let a=mid.latitude+dy*(font+12)/scale, b=mid.longitude+dx*(dim.width/2+16)/(scale*cosine)
                        if province.contains(a,b) { anchors.append([a,b]) }
                    }
                    for anchor in anchors {
                        let pos = project(anchor[0],anchor[1])
                        let rect = CGRect(x:pos.x-dim.width/2,y:pos.y-dim.height/2,width:dim.width,height:dim.height).insetBy(dx:-3,dy:-1)
                        if screen.contains(rect) && !used.contains(where: { $0.intersects(rect) }) && !nearRoute(pos,within:font+3) {
                            used.append(rect); context.draw(text,at:pos); break
                        }
                    }
                }
            }
            let range = min(small ? 12.0 : 30.0,max(6,scale*0.55))
            for city in geography?.cities ?? [] {
                if labels.count >= (small ? 3 : 10) { break }
                let p = project(city.lat,city.lon)
                guard screen.insetBy(dx:3,dy:3).contains(p) else { continue }
                let name = city.name.hasSuffix("市") ? String(city.name.dropLast()) : city.name
                if (from.hasPrefix(name) || to.hasPrefix(name)) &&
                    min(hypot(first.x-p.x,first.y-p.y),hypot(last.x-p.x,last.y-p.y)) < 18 { continue }
                if nearRoute(p,within:range) && label(name,at:p) { dot(p,small ? 1.2 : 1.8,paper) }
            }
        }
        .clipped().accessibilityLabel("乘车区间图，\(from)至\(to)")
    }
}
