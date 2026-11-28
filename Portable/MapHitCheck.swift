import AppKit
import MapKit
import RailwayCore
import SwiftUI
@testable import RailwayAtlas

@main @MainActor enum MapHitCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let check = WindowCheck()
            do { try await check.run(); check.note("PASS") }
            catch { check.note("FAIL \(error.localizedDescription)") }
            app.terminate(nil)
        }
        app.run()
    }
}

@MainActor private final class WindowCheck: NSObject {
    let size = CGSize(width: 920, height: 560)
    let map = RailwayMapStore()
    let center = Coordinate(35,115)
    let window = NSWindow(contentRect: CGRect(x: 80,y: 80,width: 920,height: 560), styleMask: [.titled],
                          backing: .buffered, defer: false)
    var host: NSHostingView<AnyView>!
    var logs = [String]()
    var sequence = 1
    var isolatedInput: MapFeatureTap?
    weak var actionTarget: AnyObject?
    var action: Selector?
    var delivered = 0
    @objc func forward(_ tap: MapFeatureTap) {
        delivered += 1
        if let action { NSApp.sendAction(action, to: actionTarget, from: tap) }
    }
    func note(_ message: String) {
        logs.append(message)
        let file = URL(fileURLWithPath: CommandLine.arguments.last!).appendingPathComponent("results.txt")
        try? (logs.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    func expect(_ condition: Bool, _ description: String) throws {
        if !condition { throw NSError(domain: "MapHit", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
    }
    func settle(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    func child(_ view: NSView, _ matches: (NSView) -> Bool) -> NSView? {
        if matches(view) { return view }
        for subview in view.subviews { if let hit = child(subview, matches) { return hit } }
        return nil
    }
    func send(_ type: NSEvent.EventType, _ point: CGPoint) {
        sequence += 1
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: sequence, clickCount: 1,
                                       pressure: type == .leftMouseUp ? 0 : 1)!
        if let isolatedInput {
            switch type {
            case .leftMouseDown: isolatedInput.mouseDown(with:event)
            case .leftMouseDragged: isolatedInput.mouseDragged(with:event)
            case .leftMouseUp: isolatedInput.mouseUp(with:event)
            default: break
            }
        } else { window.sendEvent(event) }
    }
    func click(_ point: CGPoint, excursion: CGFloat = 0) async {
        send(.mouseMoved, point)
        await settle(20)
        send(.leftMouseDown, point)
        await settle(35)
        if excursion != 0 {
            send(.leftMouseDragged, .init(x: point.x + excursion,y: point.y))
            send(.leftMouseDragged, point)
        }
        send(.leftMouseUp, point)
        await settle(620)
    }
    func install(_ stations: [RailStation]) throws {
        let line: [String:Any] = ["id":"hit/track","name":"复核正线","coordinates":[["latitude":35,"longitude":112],["latitude":35,"longitude":118]],
                                  "tags":["railway":"rail","usage":"main","maxspeed":"300"]]
        let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stations))
        let data: [String:Any] = ["schemaVersion":1,"name":"QA","downloadedAt":0,"sourceURL":"fixture","lines":[line],
                                 "stations":rows,"bounds":["south":30,"west":110,"north":40,"east":120]]
        map.dataset = try JSONDecoder().decode(RailwayDataset.self, from: JSONSerialization.data(withJSONObject: data))
        map.rebuildIndex()
    }
    func region(_ zoom: Double) -> MKCoordinateRegion {
        let delta = size.width * 360 / (256 * exp2(zoom))
        return .init(center: center.location, span: .init(latitudeDelta: delta*0.45, longitudeDelta: delta))
    }
    func run() async throws {
        map.mapMode = .offline
        map.automaticAlignment = false; map.alignment = .wgs84
        map.automaticDetail = false; map.showsNationalMetroOverview = false; map.showsStationLayouts = false
        // Same five scales and offsets as the previous line picker review.
        for apple in [true,false] {
            let name = apple ? "MapKit" : "Canvas"
            map.selection = nil; map.showsStations = false; map.showsLabels = false
            try install([])
            map.region = region(7); map.rebuildVisible()
            let root = apple ? AnyView(AppleRailwayMap(store: map)) : AnyView(OfflineRailwayMap().environmentObject(map))
            host = NSHostingView(rootView: root); host.sizingOptions = []
            window.contentView = host; window.setContentSize(size); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await settle(320)
            guard let surface = child(host, { $0.gestureRecognizers.contains { $0 is MapFeatureTap } }) else {
                throw NSError(domain: name,code: 1,userInfo: [NSLocalizedDescriptionKey:"\(name) input surface missing"])
            }
            let native = surface as? MKMapView
            let tap = surface.gestureRecognizers.compactMap { $0 as? MapFeatureTap }.first!
            actionTarget = tap.target as AnyObject?; action = tap.action
            tap.target = self; tap.action = #selector(forward(_:))
            func position(_ zoom: Double, _ offset: CGFloat = 0) async -> CGPoint {
                map.selection = nil; map.clearLineFocus()
                let r = region(zoom)
                map.region = r; map.rebuildVisible()
                native?.setRegion(r, animated: false)
                await settle(100)
                if !apple, let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: image)
                }
                let p = native?.convert(center.location, toPointTo: native)
                    ?? RailProjection(region: map.region, size: surface.bounds.size).screen(center)
                return surface.convert(CGPoint(x: p.x, y: p.y+offset), to: nil)
            }
            if !apple {
                let p = await position(12), previousCount = delivered
                await click(p)
                let session = CGSessionCopyCurrentDictionary() as? [String:Any]
                if delivered == previousCount, session?["CGSSessionScreenIsLocked"] as? Bool == true {
                    isolatedInput = tap
                    note("Canvas: locked WindowServer, replaying NSEvents into the mounted production recognizer")
                }
            }
            for z in CommandLine.arguments.contains("--stations") ? [] : [7,10,12,15,18] {
                var results: [String] = []
                for offset in [0,3,4,5,6,8,10,13] {
                    let p = await position(Double(z),CGFloat(offset))
                    await click(p)
                    let got = map.selection?.id == "hit/track"
                    let target = host.hitTest(host.convert(p,from:nil))
                    try expect(got == (z >= 11 && offset <= (z < 14 ? 3 : 4)), "\(name) Z\(z) +\(offset) hit=\(got), delivered=\(delivered) surface=\(surface.bounds) target=\(String(describing: target.map { type(of:$0) })) features=\(map.visibleLines.count) parts=\(map.clippedGeometry["hit/track"]?.count ?? 0) zoom=\(map.displayZoom)")
                    results.append(got ? "+" : ".")
                }
                note("\(name) Z\(z)  \(results.joined())")
            }
            for excursion: CGFloat in [4,30] {
                let p = await position(15)
                await click(p,excursion: excursion)
                try expect(map.selection == nil,"\(name) drag-return \(excursion)")
            }
            let afterPan = await position(15)
            await settle(350)
            await click(afterPan)
            try expect(map.selection?.id == "hit/track","\(name) next click after pan, delivered \(delivered), at \(afterPan), tap \(tap.pickPoint), lines \(map.visibleLines.count)")
            let minor = RailStation(id:"hit/minor", name:"小站", coordinate:center,tags:["railway":"halt"])
            map.showsStations = true; try install([minor])
            await click(await position(9.5))
            try expect(map.selection == nil,"\(name) unlabelled minor overview dot")
            let detailPoint = await position(15)
            await settle(300)
            if let native, let pin = native.annotations.first(where: { $0 is StationAnnotation }), native.view(for:pin)?.isHidden == true {
                await click(detailPoint)
                try expect(map.selection?.id == "hit/track","hidden MapKit station must yield to visible track")
                note("MapKit window: system hid station view; click reached visible track. Visible symbol/label checked separately.")
            } else {
                await click(detailPoint)
                try expect(map.selection?.id == minor.id,"\(name) detail station above line: \(map.selection?.id ?? "-")")
            }
            let major = RailStation(id:"hit/major",name:"复核总站",coordinate:center,tags:["railway":"station","highspeed":"yes"])
            try install([major]); map.showsLabels = true
            let p = await position(9.5)
            if let native, let pin = native.annotations.first(where: { $0 is StationAnnotation }), native.view(for:pin)?.isHidden == true {
                let style = map.stationAppearance(major)
                let bounds = StationSymbol.titleBounds(major.name, style:style, scale:1)
                for (x, expected) in [(30.0,true),(120.0,false)] {
                    var pick = MapFeatureHit(CGPoint(x:x,y:0),zoom:9.5,touch:false)
                    pick.station(major,at:.zero,style:style,label:bounds,focused:false,dimmed:false)
                    try expect((pick.feature != nil) == expected,"MapKit measured station label")
                }
            } else {
                await click(CGPoint(x:p.x+30,y:p.y))
                try expect(map.selection?.id == major.id,"\(name) actual overview label")
            }
            let blank = await position(9.5)
            await click(CGPoint(x:blank.x+120,y:blank.y))
            try expect(map.selection == nil,"\(name) transparent label tail")
            map.showsLabels = false
            let hidden = await position(9.5)
            await click(CGPoint(x:hidden.x+30,y:hidden.y))
            try expect(map.selection == nil,"\(name) labels switched off")
            note("\(name) \(isolatedInput == nil ? "window" : "recognizer") input: drag-return, next click, minor overview station, transparent tail, labels off")
        }
        let area = try JSONDecoder().decode(StationLayout.self,from:Data("""
        {"id":"way/99","kind":"platform","network":"railway","area":true,"paths":[[[0,0],[20,0],[20,20],[0,20],[0,0]],[[4,4],[8,4],[8,8],[4,8],[4,4]]]}
        """.utf8))
        for (point, expected) in [(CGPoint(x:2,y:2),true),(.init(x:5,y:5),false),(.init(x:22,y:12),false)] {
            var hit = MapFeatureHit(point,zoom:17,touch:true)
            hit.layout(area,pointRadius:0) { .init(x:$0.longitude,y:$0.latitude) }
            try expect((hit.feature != nil) == expected,"station platform \(point)")
        }
        note("Native polygon fill, hole and exterior")
    }
}
