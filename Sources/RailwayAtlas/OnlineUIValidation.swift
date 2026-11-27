#if os(macOS)
import AppKit
import Foundation
import MapKit
import RailwayCore
import ScreenCaptureKit
import SwiftUI
import WebKit

/// Explicit QA mode with an isolated cache. It never runs in a normal launch.
@MainActor
enum OnlineUIValidation {
    private static var started = false

    static func runIfRequested(store: RailwayMapStore, assistant: AssistantStore) async {
        let arguments = CommandLine.arguments
        guard !started, let index = arguments.firstIndex(of: "--ui-smoke"), arguments.count > index + 1 else { return }
        started = true
        // Keep the isolated stores available for interactive checks through the normal windows.
        if arguments.contains("--interactive-check") { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        var observations: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSApp.appearance = NSAppearance(named: .aqua)
            try await Task.sleep(for: .seconds(1))
            let window = NSApp.windows.first { $0.contentView != nil && $0.isVisible }
            window?.setContentSize(NSSize(width: 1240, height: 820))
            window?.center()
            window?.title = "铁道图鉴 · 本地验证"
            if arguments.contains("--journey-guide-check") {
                try await RideGuideValidation.run(store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--check-v604") {
                let model=store.journeyWorkspace
                await model.load()
                let start=ProcessInfo.processInfo.systemUptime
                guard let table=try await NationalJourneyPaths.shared.timetable(train:"V604",date:"2026-11-26") else {
                    throw DataError.invalid("缺少 V604 排图")
                }
                let route=try await model.prepareRoute(table,allowNetwork:false)
                try store.journeyPlayer.start(table,route:route)
                store.journeyPlayer.pause()
                guard table.stops.count==22, route.legs.count==21, store.experienceLines.count==21,
                      store.experienceMarker != nil else {throw DataError.invalid("V604 主地图轨迹不完整")}
                window?.contentView?.layoutSubtreeIfNeeded()
                window?.displayIfNeeded()
                let mapMs=Int((ProcessInfo.processInfo.systemUptime-start)*1000)
                let cardStart=ProcessInfo.processInfo.systemUptime
                var card=table.draftJourney
                card.from="涞源"; card.to="北京西"; card.updateBoardingTime()
                guard let section=try await NationalJourneyPaths.shared.journey(table,from:card.from,to:card.to),
                      section.stations == [card.from,card.to], section.legs.count==1 else {
                    throw DataError.invalid("V604 明信片乘车区间有误")
                }
                let image=ImageRenderer(content:TicketPostcardArt(style:.map,journey:card,caption:"",legs:section.legs,stations:section.stations))
                image.scale=2
                guard let cg=image.cgImage, let png=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else {
                    throw DataError.invalid("V604 明信片导出失败")
                }
                try png.write(to:directory.appendingPathComponent("V604-card.png"))
                let receipt=["stops":table.stops.count,"legs":route.legs.count,"mapMs":mapMs,
                             "postcardMs":Int((ProcessInfo.processInfo.systemUptime-cardStart)*1000),"pngBytes":png.count]
                try JSONEncoder().encode(receipt).write(to:directory.appendingPathComponent("V604.json"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--metro-direction-check") {
                try await checkMetroDirection(store, window: window, directory: directory)
                if arguments.contains("--live-city-check"),
                   let spec=MetroCitySpec.directory.first(where:{ $0.name=="维也纳" && $0.data==nil }) {
                    let center=spec.area.center
                    store.changeMode(.apple)
                    store.goTo(AtlasPlace(name:spec.name,coordinate:center,span:0.08))
                    func findMap(_ view:NSView)->MKMapView? {
                        if let map=view as? MKMapView { return map }
                        return view.subviews.lazy.compactMap(findMap).first
                    }
                    for tick in 0..<1000 {
                        if store.directionCity?.id==spec.id {break}
                        if tick<30,tick.isMultiple(of:5),let map=window?.contentView.flatMap(findMap),
                           abs(map.region.center.longitude-center.longitude)>0.15 {
                            map.setRegion(MKCoordinateRegion(center:center.location,span:.init(latitudeDelta:0.08,longitudeDelta:0.12)),animated:false)
                        }
                        try await Task.sleep(for:.milliseconds(150))
                    }
                    guard let city=store.directionCity,city.id==spec.id,
                          let route=city.routes.first(where:{$0.stops.count>=5 && !$0.parts.isEmpty}) else {
                        throw DataError.invalid("维也纳视野自动加载失败 \(store.directionStatus)")
                    }
                    let offline=try await MetroCityReader().load(spec,online:false,refresh:false)
                    guard offline.routes.count==city.routes.count else {throw DataError.invalid("离线站序缺失")}
                    store.showMetroDirection(.init(city:city.name,date:city.sourceDate,direction:route),fit:true)
                    _ = try await capture("vienna-live",directory:directory,window:window)
                    try Data("\(city.name) \(city.sourceDate) · \(city.routes.count) 个方向 · \(route.name) \(route.stops.count) 站 · 已从独立读取器离线回读\n".utf8)
                        .write(to:directory.appendingPathComponent("live-city.txt"))
                }
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--line-focus-check") {
                try await checkFocusAndCards(store, window:window, directory:directory)
                NSApp.terminate(nil)
                return
            }
            if let flag = arguments.firstIndex(of:"--journey-frame-benchmark"), arguments.indices.contains(flag+1) {
                try await benchmarkJourneyFrames(store, window:window, directory:directory, libraryFile:arguments[flag+1])
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--station-directory-check") {
                try await checkStationDirectory(store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--station-layout-check") {
                try await checkStationLayouts(store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--world-stations-check") {
                try await checkWorldStationTiles(RailwayMapStore(), directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--scale-check") {
                try await ViewportValidation.scaleCheck(store: store, directory: directory, window: window)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--urban-lifecycle-check") {
                try await ViewportValidation.urbanLifecycleCheck(store: store, directory: directory, window: window)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(ExperienceValidation.flag) {
                try await ExperienceValidation.run(directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(NationalMetroUIValidation.flag) {
                try await NationalMetroUIValidation.run(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(InterchangeUIValidation.flag) {
                try await InterchangeUIValidation.run(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(AssistantUIValidation.flag) {
                try await AssistantUIValidation.run(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--assistant-personalization-check") {
                try await AssistantPersonalizationValidation.run(map: store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(PanelLayoutValidation.flag) {
                try await PanelLayoutValidation.run(store: store, assistant: assistant, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--v020-discovery-check") {
                try await SeriesUIValidation.discovery(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--v020-check") {
                try await SeriesUIValidation.run(store: store, assistant: assistant, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--panels-check") {
                try await PanelUIValidation.run(store: store, assistant: assistant, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--render-performance") {
                try await RenderPerformanceValidation.run(store: store, directory: directory)
                if arguments.contains("--expect-render-optimized") {
                    try await RenderPipelineValidation.run(store: store, directory: directory)
                }
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--beijing-check") {
                try await MetroCoverageValidation.run(store: store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if let index = arguments.firstIndex(of: "--hongkong-check"), arguments.count > index + 1 {
                try await BorderUIValidation.inspectMacao(data: URL(fileURLWithPath: arguments[index + 1]), directory: directory,
                                                        hongKong: true, satellite: arguments.contains("--satellite-probe"))
                NSApp.terminate(nil)
                return
            }
            if let index = arguments.firstIndex(of: "--macao-check"), arguments.count > index + 1 {
                try await BorderUIValidation.inspectMacao(data: URL(fileURLWithPath: arguments[index + 1]), directory: directory,
                                                        satellite: arguments.contains("--satellite-probe"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--interface-check") {
                try await InterfaceValidation.run(directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--viewport-check") {
                try await ViewportValidation.run(store: store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--settings-check") {
                try await SettingsValidation.run(store: store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--loading-check") {
                let notes = try await MetroLoadingValidation.run()
                try Data(notes.utf8).write(to: directory.appendingPathComponent("loading-qa.txt"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--retina-check") {
                try await RetinaUIValidation.run(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--border-check") {
                let notes = try await BorderUIValidation.run(repository: store.tileRepository, directory: directory)
                try Data(notes.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("border-ui.txt"))
                print(notes.joined(separator: "\n"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--v013-check") {
                try await renderingRevisionCheck(store, directory: directory, window: window)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--metro-check") {
                store.changeMode(.cached)
                store.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.57, longitude: 127.01),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.24))
                store.cameraRevision += 1
                store.refreshViewport()
                try await settle(store, seconds: 30)
                try await waitAssembly(store)
                store.selectedTab = 1
                guard store.urbanRoutes.filter({ $0.color != nil }).count >= 10 else {
                    throw DataError.invalid("Seoul actual cached coloured routes missing")
                }
                try await capture("seoul-cache-colours", directory: directory, window: window)
                let rows = store.urbanRoutes.map { "\($0.visibilityKey): \($0.color?.hex ?? "unknown") · \($0.name)" }
                let note = "Seoul real cache, no network needed: \(store.urbanRoutes.count) line identities, \(store.onlineStations.count) independent station objects.\n" + rows.joined(separator: "\n")
                try Data(note.utf8).write(to: directory.appendingPathComponent("metro-qa.txt"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--revision-check") {
                try await revisionCheck(store, directory: directory, window: window)
                NSApp.terminate(nil)
                return
            }
            store.fitDataset()
            try await settle(store, seconds: 150)
            try await capture("01-national-online", directory: directory, window: window)
            guard store.onlineLines.count > 1000 else { throw DataError.invalid("Nationwide map did not load: \(store.onlineStatus)") }
            observations.append("National view: \(store.onlineLines.count) fragments; \(store.tilesReady)/\(store.tilesExpected) tiles; \(store.failedTiles) failures.")

            for name in ["北京", "广州"] {
                store.goTo(AtlasPlace.presets.first { $0.name == name }!)
                if store.mapMode != .apple { store.changeMode(.apple) }
                try await settle(store, seconds: 150)
                try await capture(name == "北京" ? "02-beijing-online" : "03-guangzhou-online", directory: directory, window: window)
                guard store.onlineLines.contains(where: { $0.category == .urban }) else {
                    throw DataError.invalid("\(name) urban tracks did not load")
                }
                guard store.urbanRoutes.count >= 2 else {
                    throw DataError.invalid("\(name) route colours did not load; a grey metro map is not a colour-test pass")
                }
                observations.append("\(name): \(store.onlineLines.count) fragments, \(store.onlineStations.count) stations, \(store.urbanRoutes.count) coloured routes; \(store.tilesReady)/\(store.tilesExpected) tiles.")
                store.selectedTab = 1
                store.changeMode(.cached)
                try await settle(store, seconds: 10)
                try await capture(name == "北京" ? "02b-beijing-cached-colours" : "03b-guangzhou-cached-colours",
                                  directory: directory, window: window)
                guard store.renderGroups.contains(where: { !$0.appearance.colors.isEmpty }) else {
                    throw DataError.invalid("Cached metro colours were lost")
                }
            }
            store.selectedTab = 1
            store.networks = [.metro]
            store.showsStations = false
            store.showsLabels = false
            guard !store.visibleLines.isEmpty, store.visibleLines.allSatisfy({ RailNetwork.classify($0.tags) == .metro }),
                  store.visibleStations.isEmpty else { throw DataError.invalid("Network/station filters failed") }
            try await Task.sleep(for: .seconds(1))
            try await capture("04-metro-filter", directory: directory, window: window)
            observations.append("Metro-only filter excludes railways and station markers.")
            store.showsMetroColors = false
            guard store.renderGroups.allSatisfy({ $0.appearance.colors.isEmpty }) else {
                throw DataError.invalid("Metro colour toggle failed")
            }
            store.showsMetroColors = true
            guard store.renderGroups.contains(where: { !$0.appearance.colors.isEmpty }) else {
                throw DataError.invalid("Metro colours were not restored")
            }
            observations.append("Beijing/Guangzhou coloured metro geometry survives cache reload and colour toggle.")

            store.networks = Set(RailNetwork.allCases)
            store.showsStations = true
            store.showsLabels = true
            store.selectedTab = 2
            store.changeMode(.cached)
            try await settle(store, seconds: 10)
            guard !store.onlineLines.isEmpty, !store.onlineLoading else { throw DataError.invalid("Offline cache reload failed") }
            try await capture("05-cached-offline", directory: directory, window: window)
            observations.append("Cached mode reloaded \(store.onlineLines.count) fragments.")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(500))
            try await capture("06-dark-cache", directory: directory, window: window)

            let database = directory.appendingPathComponent("Nationwide-and-cities.railcache")
            try await store.tileRepository.exportCache(to: database)
            let report = "UI smoke passed (network completeness recorded below):\n" + observations.joined(separator: "\n")
                + "\nScreenshots still require visual inspection. The cache covers these views and zooms, not every level of China.\n"
            try Data(report.utf8).write(to: directory.appendingPathComponent("ui-smoke.txt"), options: .atomic)
            print(report)
            NSApp.terminate(nil)
        } catch {
            let report = "UI smoke FAILED: \(error.localizedDescription)\n" + observations.joined(separator: "\n")
                + "\n" + store.sourceStates.map { "\($0.name): \($0.status)" }.joined(separator: "\n")
                + "\n" + (store.onlineError ?? "")
            try? Data(report.utf8).write(to: directory.appendingPathComponent("ui-smoke.txt"), options: .atomic)
            print(report)
            exit(1)
        }
    }

    private static func checkMetroDirection(_ store: RailwayMapStore, window: NSWindow?, directory: URL) async throws {
        let expected = ["马连洼","上地软件园","东北旺","龙泽西","回龙观西大街","文华路","回龙观东大街","霍营东","天通苑","太平庄","天通苑东"]
        func load(_ id:String) async throws -> MetroDirectionCatalog.City {
            guard let city=MetroCitySpec.directory.first(where:{ $0.id==id }) else {throw DataError.invalid("城市目录缺少 \(id)")}
            store.chooseDirectionCity(city,centerMap:true)
            for _ in 0..<200 {
                if let loaded=store.directionCity, loaded.id==id {return loaded}
                try await Task.sleep(for:.milliseconds(50))
            }
            throw DataError.invalid(store.directionStatus)
        }
        var counts=[String]()
        for id in ["shanghai","paris","singapore","beijing"] {
            let city=try await load(id)
            guard let route=city.routes.first(where:{ $0.stops.count>3 && !$0.parts.isEmpty }) else {throw DataError.invalid("线路详情缺失：\(id)")}
            store.focusRelation(route.route)
            guard store.lineFocus?.directionID == route.id, store.stationBoardPins.count>3 else { throw DataError.invalid("选线失败：\(id)") }
            counts.append("\(city.name) \(city.routes.count)")
        }
        guard let entry = store.directions.entries["relation/20010805"],
              entry.direction.stops.map(\.name) == expected,
              let reverse = store.directions.reverse(of:entry),
              reverse.stops.map(\.name) == Array(expected.reversed()),
              MetroCitySpec.directory.count > 80 else { throw DataError.invalid("随包线路或站序缺失") }
        store.focusRelation(entry.direction.route)
        guard let stop = store.stationBoardPins.first(where: { $0.name == "东北旺" }) else { throw DataError.invalid("缺少东北旺定位点") }
        store.select(RailwayMapStore.item(stop))
        guard store.selection?.id == stop.id, store.lineFocus?.directionID == entry.direction.id,
              store.lineFocus?.pathColor?.hex.lowercased() == entry.direction.color.lowercased() else { throw DataError.invalid("点站后线路高亮丢失") }
        store.focusRelation(reverse.route)
        guard store.lineFocus?.directionID == reverse.id, store.stationBoardPins.map(\.name) == Array(expected.reversed()),
              let focus=store.lineFocus, !focus.paths.isEmpty else { throw DataError.invalid("反方向线路或站点未加载") }
        store.inspectorWidth = 380
        try await Task.sleep(for:.milliseconds(900))
        _ = try await capture("metro-direction", directory: directory, window: window)
        try Data("PASS \(MetroCitySpec.directory.count) cities; \(counts.joined(separator:", ")); Beijing 18 both directions, 11 pins, station selection, route colour and full geometry.\n".utf8)
            .write(to:directory.appendingPathComponent("metro-direction.txt"))
    }

    private static func benchmarkJourneyFrames(_ store: RailwayMapStore, window: NSWindow?, directory: URL, libraryFile: String) async throws {
        guard let view=window?.contentView else { throw DataError.invalid("主地图窗口未打开") }
        let library=try LuluTimetableSnapshot.read(Data(contentsOf:URL(fileURLWithPath:libraryFile)))
        let args = CommandLine.arguments
        func option(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i+1) else { return nil }
            return args[i+1]
        }
        let day = option("--journey-day") ?? "2026-11-25", model=store.journeyWorkspace
        let sample = option("--journey-sample")?.components(separatedBy: ",") ??
            ["Z336","N147","Z58","C273","D2236","V6461","S8140","G3703","C2730","C442","G3888"]
        await model.load()
        var results=[[String:Any]]()
        for train in sample {
            let rows=library.services.filter { $0.validFrom<=day && day<=$0.validThrough && LuluRouteDatabase.trainNames($0.train).contains(train) }
            store.journeyPlayer.stop()
            let start=DispatchTime.now().uptimeNanoseconds
            var row:[String:Any]=["train":train]
            do {
                let timetable:RailTimetable?
                if rows.count==1 { timetable=try library.timetable(rows[0],on:day) }
                else { timetable=try await NationalJourneyPaths.shared.timetable(train:train,date:day) }
                if let timetable {
                    let route=try await model.prepareRoute(timetable,allowNetwork:false)
                    try store.journeyPlayer.start(timetable,route:route)
                    store.journeyPlayer.pause()
                    guard store.experienceLines.count==route.legs.count, store.experienceMarker != nil else {
                        throw DataError.invalid("主地图缺少车次轨迹")
                    }
                    try await Task.sleep(for:.milliseconds(34))
                    view.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
                    guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {
                        throw DataError.invalid("主地图画面读取失败")
                    }
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    row["ms"]=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
                    row["legs"]=route.legs.count; row["status"]="full"
                    let midLeg = route.legs.count / 2
                    let departure = timetable.stops[midLeg].departure!, arrival = timetable.stops[midLeg+1].arrival!
                    let moment = Double(departure + arrival) * 30
                    store.journeyPlayer.seek(moment)
                    guard let marker = store.experienceMarker, let expected = route.coordinate(at:timetable.position(at:moment)),
                          RailTrackJourney.metres(marker, expected) < 1 else { throw DataError.invalid("播放位置偏离轨迹") }
                    let cardStart = ProcessInfo.processInfo.systemUptime
                    var card = timetable.draftJourney
                    let a: Int, b: Int
                    if train == "D174", let i=timetable.stops.firstIndex(where:{ $0.station == "陇南" }) { a=i; b=i+1 }
                    else if train == "V571", let i=timetable.stops.firstIndex(where:{ $0.station == "菏泽" }),
                            let j=timetable.stops.firstIndex(where:{ $0.station == "浠水" }) { a=i; b=j }
                    else { a=midLeg; b=midLeg+1 }
                    card.from=timetable.stops[a].station; card.to=timetable.stops[b].station; card.updateBoardingTime()
                    let section = try await model.passengerRoute(card,allowNetwork:false)
                    guard section.legs == Array(route.legs[a..<b]) else { throw DataError.invalid("明信片与主地图的区间不同") }
                    let art=ImageRenderer(content:TicketPostcardArt(style:.map,journey:card,caption:"",legs:section.legs,stations:section.stations))
                    art.scale = 2
                    guard let image=art.cgImage, let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {
                        throw DataError.invalid("明信片 PNG 导出失败")
                    }
                    try png.write(to:directory.appendingPathComponent("\(train)-section.png"))
                    row["cardMs"]=Int((ProcessInfo.processInfo.systemUptime-cardStart)*1000)
                    row["section"]=[card.from,card.to]; row["pngBytes"]=png.count
                    if train=="Z58" { try bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("Z58-map.png")) }
                } else { row["status"]="absent" }
            } catch { row["status"]="unavailable";row["detail"]=error.localizedDescription }
            if row["ms"]==nil {row["ms"]=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000}
            results.append(row)
        }
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("native-window.json"),options:.atomic)
    }

    private static func checkFocusAndCards(_ store: RailwayMapStore, window: NSWindow?, directory: URL) async throws {
        guard let root = window?.contentView else { throw DataError.invalid("未找到主窗口") }
        func child<T:NSView>(_ v:NSView,_ t:T.Type) -> T? { (v as? T) ?? v.subviews.lazy.compactMap { child($0,t) }.first }
        guard let west = NationalDirectoryPins.all.first(where: { $0.name == "北京西" }) else { throw DataError.invalid("缺少北京西站坐标") }
        store.changeMode(.apple); store.panelVisible=false; store.select(RailwayMapStore.item(west))
        var board: WKWebView?
        for _ in 0..<65 {
            try await Task.sleep(for:.milliseconds(150))
            if let web = child(root,WKWebView.self), (try? await web.evaluateJavaScript("!!document.querySelector('details summary')") as? Bool) == true {
                board=web; break
            }
        }
        guard let board else { throw DataError.invalid("车站侧栏未载入") }
        _ = try await board.evaluateJavaScript("[...document.querySelectorAll('summary')].find(s=>s.textContent.startsWith('京九线 ·')).click()")
        for _ in 0..<40 where store.lineFocus?.title != "京九线" { try await Task.sleep(for:.milliseconds(80)) }
        guard let focus=store.lineFocus, !focus.paths.isEmpty, focus.includes(west), !store.stationBoardPins.isEmpty else {
            throw DataError.invalid("从车站展开线路后缺少轨迹或站点")
        }
        store.region=MKCoordinateRegion(center:.init(latitude:35.4,longitude:115.6),span:.init(latitudeDelta:2.4,longitudeDelta:3.0))
        store.cameraRevision += 1
        try await Task.sleep(for:.milliseconds(650))
        guard let map=child(root,MKMapView.self),
              let veil=map.overlays.compactMap({$0 as? MKPolygon}).first(where:{$0.title=="focus-shade"}),
              let base=map.overlays.compactMap({$0 as? MKPolygon}).first(where:{$0.title=="basemap-shade"}),
              let track=map.overlays.compactMap({$0 as? MKMultiPolyline}).first(where:{$0.title=="focus-rail" && $0.polylines.count>1})
        else { throw DataError.invalid("主地图未绘出高亮") }
        let initial=map.region
        for (offset,scale) in [(0.15,0.9),(-0.35,0.7),(0,1.0)] {
            var next=initial
            next.center.longitude+=offset; next.span.longitudeDelta*=scale; next.span.latitudeDelta*=scale
            map.setRegion(next,animated:true)
            try await Task.sleep(for:.milliseconds(420))
            let layers=map.overlays(in:.aboveLabels).map(ObjectIdentifier.init)
            guard let a=layers.firstIndex(of:ObjectIdentifier(base)), let b=layers.firstIndex(of:ObjectIdentifier(veil)),
                  let c=layers.firstIndex(of:ObjectIdentifier(track)), a<b,b<c else { throw DataError.invalid("移动时替换了高亮或暗化层") }
        }
        _ = try await capture("native-line-focus",directory:directory,window:window)
        _ = try await board.evaluateJavaScript("[...document.querySelectorAll('summary')].find(s=>s.textContent.startsWith('京西联络线 ·')).click()")
        for _ in 0..<40 where store.lineFocus?.title != "京西联络线" { try await Task.sleep(for:.milliseconds(80)) }
        guard store.lineFocus?.title=="京西联络线" else { throw DataError.invalid("线路没有切换") }
        store.inspectorVisible=false
        try await Task.sleep(for:.milliseconds(180))
        guard store.lineFocus==nil,store.stationBoardPins.isEmpty,!map.overlays.contains(where:{($0 as? MKPolygon)?.title=="focus-shade"}) else { throw DataError.invalid("关闭后地图仍然暗化") }
        store.basemapDarkness=0.42
        map.setCenter(CLLocationCoordinate2D(latitude:35.5,longitude:115.9),animated:true)
        try await Task.sleep(for:.milliseconds(500))
        guard let shade=map.renderer(for:base) as? MKPolygonRenderer, abs(shade.alpha-0.42)<0.001,
              !shade.shouldRasterize else { throw DataError.invalid("移动后底图暗化失效") }
        store.basemapDarkness=0
        guard let geo = CardGeography.shared, !geo.cities.isEmpty,
              let contours = CardGeography.Contours.shared, contours.provinces.count == 34,
              !contours.provinceLines.isEmpty, !contours.coastLines.isEmpty, !contours.hainan.isEmpty,
              !contours.settled.isEmpty, !contours.undelimited.isEmpty
        else { throw DataError.invalid("乘车区间的地理轮廓或城市资料缺失") }
        var timings = [String:Double]()
        for (train,from,to) in [("G337","石家庄","武汉"),("Z58","北京西","三亚"),("S8140","海口东","海口")] {
            let start=ProcessInfo.processInfo.systemUptime
            guard let table=try await NationalJourneyPaths.shared.timetable(train:train,date:"2026-11-25"),
                  let route=try await NationalJourneyPaths.shared.journey(table,from:from,to:to),
                  route.stations.first==from,route.stations.last==to else { throw DataError.invalid("样本区间缺失") }
            var journey=table.draftJourney
            journey.from=from; journey.to=to; journey.updateBoardingTime()
            if train=="G337", journey.departure != "17:58" { throw DataError.invalid("石家庄上车时刻不符") }
            let image=ImageRenderer(content:TicketPostcardArt(style:.map,journey:journey,caption:"一路山河",legs:route.legs,stations:route.stations))
            image.scale=2
            guard let cg=image.cgImage, let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else { throw DataError.invalid("明信片无法导出") }
            try data.write(to:directory.appendingPathComponent("\(train)-native.png"))
            timings[train]=((ProcessInfo.processInfo.systemUptime-start)*1000).rounded()
        }
        try JSONEncoder().encode(timings).write(to:directory.appendingPathComponent("native-ms.json"))
    }

    private static func checkStationDirectory(_ store: RailwayMapStore, window: NSWindow?, directory: URL) async throws {
        guard let root = window?.contentView else { throw DataError.invalid("验证窗口未打开") }
        func child<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
            (view as? T) ?? view.subviews.lazy.compactMap { child($0,type) }.first
        }
        store.changeMode(.apple); store.panelVisible = false; store.inspectorVisible = false
        store.showsStations = true; store.automaticDetail = false; store.networks.insert(.railway)
        var verified: [String] = []
        for (name, count) in [("北京西",350),("虎门",132),("杜家坎所",0)] {
            guard let station = NationalDirectoryPins.all.first(where: { $0.name == name }) else {
                throw DataError.invalid("缺少全国站点 \(name)")
            }
            store.region = MKCoordinateRegion(center: station.coordinate.location,
                span: MKCoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.06))
            store.cameraRevision += 1
            var picked = false
            for _ in 0..<80 {
                try await Task.sleep(for:.milliseconds(200))
                if let map = child(root,MKMapView.self),
                   let pin = map.annotations.compactMap({ $0 as? StationAnnotation }).first(where: {
                       $0.station.name == name && map.view(for: $0) != nil
                   }) {
                    map.selectAnnotation(pin, animated:false); picked = true; break
                }
            }
            guard picked else { throw DataError.invalid("地图上未找到 \(name) 的可选标记") }
            var contents = ""
            for _ in 0..<100 {
                try await Task.sleep(for:.milliseconds(200))
                guard store.selection?.name == name, let web = child(root,WKWebView.self),
                      let text = try? await web.evaluateJavaScript("""
                    (() => { const d=document.querySelector('input[type=date]'); if (!d) return '';
                      if(d.value!=='2026-11-24'){d.value='2026-11-24';d.dispatchEvent(new Event('change'));}
                      return document.body.innerText; })()
                    """) as? String, text.contains("本站车次") else { continue }
                contents = text; break
            }
            guard store.inspectorVisible, contents.contains(count == 0 ? "没有匹配的车次记录" : "\(count) 条记录") else {
                throw DataError.invalid("\(name) 右栏未显示预期站表 \(contents.prefix(200))")
            }
            if name == "北京西", let web = child(root,WKWebView.self) {
                let result = try await web.callAsyncJavaScript("""
                    const select = document.querySelector('select'), filter = document.querySelector('input[type=search]');
                    [...document.querySelectorAll('button')].find(b=>b.textContent==='末页').click();
                    if(!document.body.innerText.includes('第 12 / 12 页')) return false;
                    filter.value='G337';filter.dispatchEvent(new Event('input'));
                    [...document.querySelectorAll('summary')].find(s=>s.textContent.startsWith('G337')).click();
                    await new Promise(r=>setTimeout(r,120));
                    if(!document.body.innerText.includes('7 个停站')) return false;
                    select.value='original';select.dispatchEvent(new Event('change'));
                    [...document.querySelectorAll('summary')].find(s=>s.textContent.includes('京西联络线')).click();
                    await new Promise(r=>setTimeout(r,120));
                    return document.body.innerText.includes('杜家坎所') && document.body.innerText.includes('426 条记录');
                    """, arguments:[:],in:nil,contentWorld:.page)
                guard result as? Bool == true else { throw DataError.invalid("车次全表或原站线路缺失") }
            }
            verified.append("\(name) · \(count) 条 · 地图标记 → 右栏")
        }
        try verified.joined(separator:"\n").write(to: directory.appendingPathComponent("station-directory-check.txt"), atomically:true, encoding:.utf8)
    }

    private static func checkWorldStationTiles(_ store: RailwayMapStore, directory: URL) async throws {
        store.mapMode = .cached
        store.showsStationLayouts = true
        store.showsPlatforms = true
        store.showsPassengerPassages = true
        store.showsStationEntrances = true
        store.viewportWidth = 1050
        store.viewportHeight = 700
        let sites: [(String, Coordinate, StationLayoutKind, String?)] = [
            ("巴黎 Vavin", Coordinate(48.8422,2.3288), .passage,"node/790499201"),
            ("纽约 Astor Place", Coordinate(40.7301,-73.9910), .platform,"way/907561796"),
            ("东京银座", Coordinate(35.6719,139.7643), .passage,"node/1195197149"),
            ("悉尼 Crows Nest", Coordinate(-33.8268,151.201), .platform,"way/1245422813"),
            ("圣保罗 Ana Rosa", Coordinate(-23.5815,-46.6388), .entrance,nil),
            ("开罗 Sadat", Coordinate(30.04446,31.23568), .entrance,nil),
            ("新加坡 Queenstown", Coordinate(1.29485,103.80592), .entrance,"sg-lta/25149")
        ]
        var lines = ["缓存地图模式。计时从设置车站视野到图层几何可用，单位为毫秒。"]
        for visit in 1...2 {
            for (name,point,kind,id) in sites {
                let start = ProcessInfo.processInfo.systemUptime
                store.region = MKCoordinateRegion(center: point.location, span: .init(latitudeDelta: 0.0028, longitudeDelta: 0.0042))
                store.scheduleStationLayouts()
                await store.worldStationWork?.value
                let features = store.stationLayouts(in: store.viewportBounds, zoom: 18)
                guard store.stationLayoutTarget == nil, features.contains(where: { $0.kind == kind }),
                      id.map({ sample in features.contains { $0.id == sample } && !store.layoutIDs.contains(sample) }) ?? true else {
                    throw DataError.invalid("站区读取失败 \(name) \(store.worldStationKeys) \(features.count)")
                }
                let milliseconds = (ProcessInfo.processInfo.systemUptime-start)*1000
                let drawables = features.map { $0.overlay(alignment: .wgs84) }
                guard drawables.allSatisfy({ !$0.boundingMapRect.isNull }) else { throw DataError.invalid("地图形状缺失 \(name)") }
                lines.append("\(visit)\t\(name)\t\(String(format:"%.1f",milliseconds))\t\(drawables.count)")
            }
        }
        store.showsStationEntrances = false
        guard !store.stationLayouts(in: store.viewportBounds, zoom: 18).contains(where: { $0.kind == .entrance }) else {
            throw DataError.invalid("出入口开关")
        }
        store.mapMode = .offline
        store.showsStationEntrances = true
        store.uiScale = 1
        let size = CGSize(width: 1000, height: 680)
        let screen = CGRect(origin: .zero, size: size)
        let point = sites[0].1
        let span = size.width * 360 / (256 * exp2(17.0))
        let latSpan = span * size.height / size.width * cos(point.latitude * .pi / 180)
        store.viewportChanged(MKCoordinateRegion(center: point.location, span: .init(latitudeDelta: latSpan*16, longitudeDelta: span*16)),
                              width: size.width, height: size.height)
        // Enter the detail zoom using the real offline zoom command, without a manual tile refresh.
        guard store.worldStationKeys.isEmpty else { throw DataError.invalid("低倍视野应关闭站区读取") }
        store.zoom(1/16)
        await store.worldStationWork?.value
        let projection = RailProjection(region: store.region, size: size)
        let actualZoom = RailDisplayPolicy.zoom(longitudeSpan: projection.visibleRegion.span.longitudeDelta, width: size.width)
        guard abs(actualZoom - 17) < 0.1 else { throw DataError.invalid("巴黎画布实际比例尺 Z\(actualZoom)") }
        let placements = store.layoutLabels(in: projection.visibleBounds, zoom: actualZoom,
                                           screen: screen, project: projection.screen)
        let vavin: Set<String> = ["node/790498979","node/790499201","node/790499285","node/790499310"]
        let exits = placements.filter { vavin.contains($0.id) }
        guard Set(exits.map(\.text)) == Set(["1","2","3","4"]),
              exits.contains(where: { $0.leaderStart != nil }),
              exits.allSatisfy({ a in exits.allSatisfy { b in a.id == b.id || !a.frame.intersects(b.frame) } })
        else { throw DataError.invalid("Vavin 出口标签 \(exits.map(\.text))") }
        let window = NSWindow(contentRect: screen, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: OfflineRailwayMap().environmentObject(store))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await capture("vavin-z17-offline", directory: directory, window: window)
        window.contentView = NSHostingView(rootView: AppleRailwayMap(store: store))
        try await Task.sleep(for: .milliseconds(350))
        func findMap(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap(findMap).first
        }
        guard let map = window.contentView.flatMap(findMap),
              let coordinator = map.delegate as? AppleRailwayMap.Coordinator else { throw DataError.invalid("缺少 MapKit 视图") }
        map.setRegion(store.displayRegion, animated:false)
        try await Task.sleep(for: .milliseconds(350))
        coordinator.updateStationLabels(map)
        guard vavin.allSatisfy({ id in
            guard let item = coordinator.platformAnnotations[id] else { return false }
            return map.view(for:item)?.image != nil
        }) else { throw DataError.invalid("MapKit 未绘出 Vavin 的四个出口圆标") }
        _ = try await capture("vavin-mapkit", directory: directory, window: window)
        lines.append("巴黎 Vavin，离线画布 Z17 和 MapKit 均显示 1、2、3、4 号出口。")
        try lines.joined(separator:"\n").write(to:directory.appendingPathComponent("world-stations.txt"),atomically:true,encoding:.utf8)
    }

    private static func checkStationLayouts(_ store: RailwayMapStore, directory: URL) async throws {
        let western = Coordinate(39.8935,116.3151), metro = Coordinate(39.9403,116.3491)
        store.showsStationLayouts = true
        store.showsStations = true
        store.historyMapActive = false
        store.networks = [.metro, .lightRail, .tram]
        store.categories.remove(.urban)
        let window = NSWindow(contentRect: CGRect(x: 100,y: 100,width: 1000,height: 690),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Use real Apple/Canvas renderers with the offline QA store to isolate the geometry from live track providers.
        store.mapMode = .offline
        store.viewportWidth = 1000
        store.viewportHeight = 690
        window.contentView = NSHostingView(rootView: AppleRailwayMap(store: store))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        func findMap(_ v: NSView) -> MKMapView? {
            if let map = v as? MKMapView { return map }
            return v.subviews.lazy.compactMap(findMap).first
        }
        guard let map = window.contentView.flatMap(findMap), let coordinator = map.delegate as? AppleRailwayMap.Coordinator else {
            throw DataError.invalid("Missing native map")
        }
        func focus(_ p: Coordinate, _ z: Double) async throws {
            let width = store.viewportWidth * 360 / (256 * exp2(z+0.1))
            store.region = MKCoordinateRegion(center: p.location, span: .init(latitudeDelta: width*0.53, longitudeDelta: width))
            store.cameraRevision += 1
            store.rebuildVisible()
            try await Task.sleep(for: .milliseconds(120))
            let target=store.displayRegion
            for attempt in 0..<30 {
                if attempt.isMultiple(of: 5) {
                    map.setCenter(target.center, animated: false)
                    map.setRegion(target, animated: false)
                }
                try await Task.sleep(for:.milliseconds(160))
                if abs(map.region.center.latitude-target.center.latitude) < target.span.latitudeDelta / 10 &&
                    abs(map.region.center.longitude-target.center.longitude) < target.span.longitudeDelta / 10 &&
                    abs(RailDisplayPolicy.zoom(longitudeSpan:map.region.span.longitudeDelta,width:map.bounds.width)-z)<0.4 {
                    try await Task.sleep(for:.milliseconds(350))
                    return
                }
            }
            throw DataError.invalid("MapKit camera did not reach \(target.center) at Z\(z), actual \(map.region.center)")
        }
        func counts() -> [Int] { [StationLayoutKind.outline,.concourse,.platform,.passage].map { coordinator.overlays(for: $0).count } }
        func require(_ ok: Bool, _ label: String) throws {
            if !ok { throw DataError.invalid("\(label) Z\(store.displayZoom): \(counts())") }
        }
        try await focus(western,13)
        try require(counts() == [0,0,0,0], "Z13")
        try require(coordinator.overlays(for: .entrance).isEmpty, "Z13 entrance layer hidden")
        try await focus(western,14)
        let westOutlineCount = counts()[0]
        try require(westOutlineCount >= 1 && counts() == [westOutlineCount,0,0,0], "Beijing West outline")
        try await focus(western,15)
        try require(counts()[2] >= 10 && counts()[3] == 0 && coordinator.overlays(for: .entrance).isEmpty, "Z15 platforms without entrances or passages")
        let hujialou = Coordinate(39.922,116.4555), qingdao = Coordinate(36.0641,120.3076)
        func badge(_ id: String, _ text: String) -> Bool {
            guard let a = coordinator.platformAnnotations[id] else { return false }
            return a.style.text == text && a.image != nil && map.view(for:a)?.image != nil
        }
        try await focus(hujialou,16)
        try require(badge("node/3450796157","C1") || badge("node/3450796158","C2"), "Hujialou signed entrance on native map")
        _ = try await capture("hujialou-z16-exits", directory: directory, window: window)
        try await focus(qingdao,16)
        _ = try await capture("qingdao-z16-entrances", directory: directory, window: window)
        if !(badge("node/13446134636","西进") && badge("node/13446134640","东进")) {
            let signs = coordinator.platformAnnotations.values.map(\.style.text).sorted()
            let planned = store.layoutLabels(in:store.viewportBounds,zoom:store.displayZoom,screen:map.bounds) {
                map.convert(store.alignment.display($0).location,toPointTo:map)
            }
            let point = map.convert(store.alignment.display(qingdao).location,toPointTo:map)
            try require(false,"Qingdao signs \(signs), planned \(planned.map(\.text)), shapes \(coordinator.overlays(for:.entrance).count), screen \(map.bounds), gate \(point), map \(map.region.center), requested \(store.displayRegion.center)")
        }
        store.showsStationEntrances = false
        try await Task.sleep(for: .milliseconds(250))
        try require(coordinator.overlays(for:.entrance).isEmpty && coordinator.platformAnnotations.values.allSatisfy { $0.style.kind != .entrance }, "Entrance switch")
        try await focus(Coordinate(39.98325,116.47734),16)
        try require(badge("way/330398338","→B2"), "Mapped passage to B2 at Z16")
        store.showsPassageSigns = false
        try await Task.sleep(for:.milliseconds(240))
        try require(coordinator.platformAnnotations.values.allSatisfy { $0.style.kind != .passage } &&
                    !coordinator.overlays(for:.passage).isEmpty, "Passage signs switch leaves path geometry visible")
        store.showsStationEntrances = true
        store.focusStationLayouts(at: qingdao)
        for _ in 0..<35 {
            if badge("node/13446134636","西进") && badge("node/13446134640","东进") { break }
            try await Task.sleep(for:.milliseconds(140))
        }
        try require(badge("node/13446134636","西进") && badge("node/13446134640","东进"),
                    "View station details moves the native camera between cities")
        store.showsStationEntrances = false
        try await focus(western,17)
        let west = counts()
        try require(west[0] >= 1 && west == [west[0],0,10,0], "Beijing West platforms")
        try require(coordinator.overlays(for: .platform).allSatisfy { $0 is MKPolygon }, "Platform polygons")
        _ = try await capture("beijing-west-z17", directory: directory, window: window)
        store.showsStations = false
        store.showsStationOutlines = false
        try await Task.sleep(for: .milliseconds(220))
        try require(counts() == [0,0,10,0], "Platforms independent of outlines, tracks and dots")
        store.showsStationOutlines = true
        try await focus(Coordinate(25.03385,121.52885),17)
        try require(counts() == [1,0,2,0] && coordinator.overlays(for: .platform).allSatisfy { $0 is MKPolygon },
                    "Dongmen metro station and two stacked platform polygons")
        _ = try await capture("dongmen-z17", directory: directory, window: window)
        try await focus(Coordinate(25.0477,121.5171),17)
        let taipei = counts()
        try require(taipei[1] >= 1 && coordinator.overlays(for: .concourse).allSatisfy { $0 is MKPolygon }, "Taipei Main hall")
        _ = try await capture("taipei-hall-z17", directory: directory, window: window)
        store.showsConcourses = false
        try await Task.sleep(for: .milliseconds(220))
        try require(counts() == [taipei[0],0,taipei[2],taipei[3]], "Hall switch independent of other geometry")
        store.showsConcourses = true
        try await focus(Coordinate(39.9217,116.4960),18)
        try require(counts()[0] > 0 && counts()[3] > 0, "Shilipu outline and passenger paths")
        let passages = coordinator.overlays(for: .passage)
        try require(passages.allSatisfy { (map.renderer(for: $0) as? MKOverlayPathRenderer)?.strokeColor != nil },
                    "Shilipu passages have active path renderers")
        _ = try await capture("shilipu-z18", directory: directory, window: window)
        try await focus(Coordinate(39.922,116.4555),18)
        try require(coordinator.overlays(for: .platform).count == 2 && coordinator.overlays(for: .platform).allSatisfy { $0 is MKMultiPolyline } &&
                    coordinator.platformAnnotations.isEmpty, "Hujialou two unnumbered platform lines")
        try await focus(Coordinate(40.05829,116.3410691),18)
        try require(coordinator.overlays(for: .outline).contains { $0 is MKPolygon }, "Yuxin station footprint")
        try await focus(Coordinate(23.15491,113.30699),18)
        try require(coordinator.overlays(for: .concourse).contains { $0 is MKPolygon }, "Shahe ground-level concourse")
        try await focus(Coordinate(39.896845,116.39179),19)
        let dots = coordinator.overlays(for: .platform).compactMap { $0 as? MKCircle }
        try require(dots.count == 2 && dots.allSatisfy { map.renderer(for: $0) is MKCircleRenderer },
                    "Qianmen tram point platforms")
        let admiralty = Coordinate(22.27848,114.16602)
        func texts() -> [String] { coordinator.platformAnnotations.values.map(\.style.text).sorted() }
        try await focus(admiralty,15)
        try require(texts().isEmpty, "No platform numbers at Z15")
        try await focus(admiralty,18)
        let actualZoom = RailDisplayPolicy.zoom(longitudeSpan: map.region.span.longitudeDelta, width: map.bounds.width)
        let placement = store.layoutLabels(in: store.viewportBounds, zoom: actualZoom, screen: map.bounds) {
            map.convert(store.alignment.display($0).location, toPointTo: map)
        }
        try require(texts() == ["5/6","7","8"], "Admiralty platform numbers \(texts()), map Z\(actualZoom), projected \(placement.map(\.text)), map center \(map.region.center), requested \(store.displayRegion.center), pixels \(map.bounds), pass \(coordinator.labelPasses)")
        try require(coordinator.platformAnnotations.values.allSatisfy { $0.image != nil && map.view(for: $0)?.image != nil }, "Visible number glyphs")
        _ = try await capture("admiralty-z18", directory: directory, window: window)
        store.showsPlatforms = false
        try await Task.sleep(for: .milliseconds(220))
        try require(coordinator.overlays(for: .platform).isEmpty && texts() == ["5/6","7","8"], "Numbers alone")
        store.showsPlatformNumbers = false
        store.showsPlatforms = true
        try await Task.sleep(for: .milliseconds(220))
        try require(!coordinator.overlays(for: .platform).isEmpty && texts().isEmpty, "Shapes alone")
        store.showsPlatformNumbers = true
        try await focus(Coordinate(22.44565,114.03473),19)
        let lightRail = Set(texts())
        try require(Set(["1","2","3","4","5"]).isSubset(of: lightRail), "Yuen Long light rail \(texts())")
        _ = try await capture("yuen-long-z19", directory: directory, window: window)
        try await focus(metro,18)
        let xizhimen = counts()
        try require(xizhimen[0] > 0 && xizhimen[2] > 0 && xizhimen[3] > 0, "Xizhimen passenger passages")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(320))
        _ = try await capture("xizhimen-z18-dark", directory: directory, window: window)
        store.showsPassengerPassages = false
        try await Task.sleep(for: .milliseconds(220))
        try require(counts() == [xizhimen[0],xizhimen[1],xizhimen[2],0], "Passages off")
        store.showsPassengerPassages = true
        store.showsStationLayouts = false
        try await Task.sleep(for: .milliseconds(150))
        try require(counts() == [0,0,0,0], "Hidden detail layer")
        store.showsStationLayouts = true
        store.showsStations = false
        try await Task.sleep(for: .milliseconds(150))
        try require(counts() == xizhimen, "Station dots independent")
        try await focus(admiralty,18)
        try require(texts() == ["5/6","7","8"], "Dark map numbers")
        window.contentView = NSHostingView(rootView: OfflineRailwayMap().environmentObject(store))
        try await Task.sleep(for: .milliseconds(400))
        // The offline view now owns the viewport; set its own Z18 after the MapKit view has detached.
        store.zoom(exp2(store.displayZoom - 18.3))
        try await Task.sleep(for: .milliseconds(250))
        let canvasSize = window.contentView!.bounds.size
        let projection = RailProjection(region: store.region, size: canvasSize)
        let canvasLabels = store.layoutLabels(in: projection.visibleBounds, zoom: store.displayZoom,
            screen: CGRect(origin: .zero, size: canvasSize), project: projection.screen)
        try require(canvasLabels.map(\.text).sorted() == ["5/6","7","8"], "Offline numbers \(canvasLabels.map(\.text)), viewport \(store.viewportWidth)x\(store.viewportHeight), region \(store.region), size \(canvasSize), bounds \(projection.visibleBounds), enabled \(store.showsPlatformNumbers)")
        _ = try await capture("admiralty-z18-offline-dark", directory: directory, window: window)
        store.showsPlatformNumbers = false
        try await Task.sleep(for: .milliseconds(250))
        _ = try await capture("admiralty-z18-offline-no-numbers", directory: directory, window: window)
        store.showsStationLayouts = false
        store.mapMode = .offline
        store.focusStationLayouts(at: Coordinate(39.9217,116.4960))
        try await Task.sleep(for: .milliseconds(400))
        let focusedProjection = RailProjection(region: store.region, size: canvasSize)
        let focusedZoom = RailDisplayPolicy.zoom(longitudeSpan: focusedProjection.visibleRegion.span.longitudeDelta, width: canvasSize.width)
        let shilipu = store.stationLayouts(in: focusedProjection.visibleBounds, zoom: focusedZoom)
        try require(focusedZoom >= 16 && store.showsStationLayouts && shilipu.contains { $0.kind == .passage } &&
                    !store.showsPlatformNumbers, "View station detail action preserves individual switches")
        _ = try await capture("shilipu-offline-detail", directory: directory, window: window)
        store.showsStationEntrances = true
        store.showsPassageSigns = true
        store.focusStationLayouts(at: qingdao)
        try await Task.sleep(for: .milliseconds(300))
        let gatesProjection = RailProjection(region: store.region, size: canvasSize)
        let gates = store.layoutLabels(in: gatesProjection.visibleBounds, zoom: store.displayZoom,
            screen: CGRect(origin:.zero,size:canvasSize), project:gatesProjection.screen)
        try require(Set(["东进","西进"]).isSubset(of:Set(gates.map(\.text))), "Qingdao offline entrance badges")
        _ = try await capture("qingdao-offline-entrances", directory: directory, window: window)
        var receipt = "Dongmen Z17: 1 station, 2 metro platform polygons. Taipei Main Z17: \(taipei), hall switch passed. Yuxin Z18 station polygon. Shahe Z18 concourse polygon. Qianmen Z19 two tram platform circles with active renderers. Shilipu Z18: outlines and rendered passages, station-detail action on offline Canvas. Beijing West Z17 \(west), two unnumbered Hujialou lines, Admiralty Z18 5/6, 7, 8, Yuen Long light rail 1–5, Xizhimen Z18 \(xizhimen)."
        if CommandLine.arguments.contains("--live-station-cell") {
            // Remove the two bundled records from this isolated QA store so only a live query can restore them.
            let online = RailwayMapStore()
            online.viewportWidth = 1000
            online.region = MKCoordinateRegion(center: Coordinate(39.94013,116.45629).location,
                span: .init(latitudeDelta: 0.002, longitudeDelta: 0.004))
            online.mapMode = .apple
            guard let target = online.stationLayoutTarget else { throw DataError.invalid("Missing online test cell") }
            let stationIDs: Set<String> = ["way/120521104","way/120521110"]
            online.layoutBase.removeAll { stationIDs.contains($0.id) }
            online.rebuildStationLayouts()
            await online.layoutWork?.value
            guard let visit = online.layoutVisits[target],
                  stationIDs.isSubset(of: visit.features.filter { $0.network == .metro && $0.kind == .platform }.map(\.id)) else {
                throw DataError.invalid("Live station query: \(online.currentLayoutStatus)")
            }
            online.mapMode = .cached
            await online.layoutWork?.value
            let saved = online.stationLayouts(in: target.bounds, zoom: 18)
            guard stationIDs.isSubset(of: saved.map(\.id)) else { throw DataError.invalid("Cached map lost live platforms") }
            online.mapMode = .apple
            await online.layoutWork?.value
            guard online.layoutVisits[target]?.date == visit.date else { throw DataError.invalid("Duplicate station request") }
            receipt += "\nLive camera query at Nongye Zhanlanguan returned both metro platforms. Cached mode and revisiting the same cell retained the result."
        }
        receipt += "\nZ13 hidden, Z14 outlines, Z15 platforms, Z16 signed Hujialou and Qingdao entrances. The switch removed the entrance dots and glyphs. Offline Canvas retained both Qingdao directions."
        try receipt
            .write(to: directory.appendingPathComponent("station-layout-check.txt"), atomically: true, encoding: .utf8)
    }

    private static func renderingRevisionCheck(_ store: RailwayMapStore, directory: URL, window: NSWindow?) async throws {
        var notes: [String] = []
        store.changeMode(.cached)
        store.goTo(AtlasPlace.presets.first { $0.name == "欧洲" }!)
        try await settle(store, seconds: 30)
        try await waitAssembly(store)
        guard store.visibleLines.count > 1000 else {
            throw DataError.invalid("European actual map data missing: \(store.visibleLines.count), \(store.onlineStatus), \(store.onlineError ?? ""), \(store.region)")
        }
        guard store.renderGroups.allSatisfy({ $0.appearance.strokes(zoom: store.displayZoom).allSatisfy { $0.width < 1.3 } }),
              !store.categoryVisible(.branch), !store.categoryVisible(.urban) else {
            throw DataError.invalid("European scale detail policy failed")
        }
        notes.append("Europe actual cached geometry: \(store.visibleLines.count) visible fragments, Z\(String(format: "%.1f", store.displayZoom)); narrow continent strokes, automatic secondary/metro suppression.")
        store.selectedTab = 1
        store.statusOffset = .zero
        store.basemapDarkness = 0.3
        try await capture("01-europe-light", directory: directory, window: window)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(400))
        try await capture("02-europe-dark", directory: directory, window: window)
        store.uiScale = 1.25
        store.panelWidth = 360
        store.statusOffset = CGSize(width: -180, height: 130)
        try await Task.sleep(for: .seconds(1))
        try await capture("03-europe-scaled-panel", directory: directory, window: window)
        store.panelVisible = false; store.statusVisible = false
        try await Task.sleep(for: .seconds(1))
        try await capture("04-europe-unobstructed", directory: directory, window: window)
        notes.append("UI at 125%, panel width 360, status moved and hidden, sidebar hidden; screenshots require visual review.")
        store.uiScale = 1; store.panelVisible = true; store.panelWidth = 320
        store.statusVisible = true; store.statusOffset = .zero
        NSApp.appearance = NSAppearance(named: .aqua)
        store.goTo(AtlasPlace.presets.first { $0.name == "南昌" }!)
        try await settle(store, seconds: 15)
        try await waitAssembly(store)
        guard store.urbanRoutes.filter({ $0.color != nil }).count >= 4 else { throw DataError.invalid("Nanchang palette missing") }
        let before = Dictionary(store.urbanRoutes.map { ($0.visibilityKey, $0.color?.hex ?? "") }, uniquingKeysWith: { a, _ in a })
        store.zoom(0.65)
        try await settle(store, seconds: 15)
        try await waitAssembly(store)
        let changed = store.urbanRoutes.filter { before[$0.visibilityKey] != nil && before[$0.visibilityKey] != $0.color?.hex }
        guard changed.isEmpty else { throw DataError.invalid("Line palette changed on zoom") }
        store.zoom(1 / 0.65)
        try await settle(store, seconds: 15)
        try await waitAssembly(store)
        try await capture("05-nanchang-consistent", directory: directory, window: window)
        notes.append("Nanchang known line colours unchanged across zoom-in/out; detail visibility independent from palette.")
        let assistant = AssistantStore()
        assistant.scope = .region; assistant.prepare(map: store)
        guard assistant.context.contains("bounds"), assistant.context.contains("loaded_segment_count") else { throw DataError.invalid("Region GPT context missing") }
        if let line = store.visibleLines.first {
            store.selection = RailwayMapStore.item(line)
            assistant.scope = .feature; assistant.prepare(map: store)
            let payload = try JSONSerialization.jsonObject(with: Data(assistant.context.utf8)) as? [String: Any]
            guard (payload?["feature"] as? [String: Any])?["id"] as? String == line.id else {
                throw DataError.invalid("Feature GPT context missing")
            }
        }
        guard let route = store.assistantRoutes.first else { throw DataError.invalid("Route GPT selection missing") }
        assistant.scope = .route; assistant.routeKey = route.id; assistant.prepare(map: store)
        guard assistant.context.contains("segments") else { throw DataError.invalid("Route GPT context missing") }
        notes.append("GPT context: selected feature, viewport, and named/related railway route verified without a paid API call.")
        let assistantWindow = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 720, height: 820),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        let assistantView = NSHostingView(rootView: AtlasInterface(scale: store.uiScale) {
            AtlasAssistantView()
        }.environmentObject(store).environmentObject(assistant)
            .background(Color(nsColor: .windowBackgroundColor)))
        assistantWindow.contentView = assistantView
        assistantWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(1))
        _ = try RetinaUIValidation.capture(assistantView, name: "06-gpt-context", directory: directory)
        guard assistantWindow.isVisible, store.inspectorPane == .feature else {
            throw DataError.invalid("GPT window opened without preserving the feature inspector")
        }
        assistantWindow.orderOut(nil)
        try await Task.sleep(for: .milliseconds(400))
        store.showSettings = true
        try await Task.sleep(for: .seconds(1))
        try await capture("07-settings", directory: directory, window: window)
        store.showSettings = false
        store.selection = nil
        store.basemapStyle = .satellite
        store.changeMode(.apple)
        // Test MapKit's actual satellite provider; no imagery is saved to the
        // RailwayAtlas SQLite database. This file is an explicit QA snapshot.
        let options = MKMapSnapshotter.Options()
        options.region = store.displayRegion
        options.mapType = .satellite
        options.size = CGSize(width: 1200, height: 800)
        let snapshotter = MKMapSnapshotter(options: options)
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(45))
            snapshotter.cancel()
        }
        defer { timeout.cancel() }
        do {
            let snapshot = try await snapshotter.start()
            if let tiff = snapshot.image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("08-satellite-provider.png"))
            }
            notes.append("MapKit satellite snapshot request succeeded; screenshot must be checked for actual imagery.")
        } catch { notes.append("Satellite provider snapshot unavailable: \(error.localizedDescription)") }
        store.changeMode(.cached)
        let report = notes.joined(separator: "\n")
        try Data(report.utf8).write(to: directory.appendingPathComponent("v013-ui.txt"))
        print(report)
    }

    private static func waitAssembly(_ store: RailwayMapStore) async throws {
        for _ in 0..<100 {
            if store.assemblyTask == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard store.assemblyTask == nil else { throw DataError.invalid("Map assembly failed to settle") }
        try await Task.sleep(for: .milliseconds(600))
    }

    private static func revisionCheck(_ store: RailwayMapStore, directory: URL, window: NSWindow?) async throws {
        let started = Date()
        store.goTo(AtlasPlace.presets.first { $0.name == "南昌" }!)
        if let index = CommandLine.arguments.firstIndex(of: "--saved-metro"),
           CommandLine.arguments.count > index + 1 {
            // Explicit, deterministic rendering QA with previously fetched
            // real OSM data; never reported as a live-network success.
            store.viewportWork?.cancel()
            store.viewportGeneration = UUID()
            store.mapMode = .offline
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            var saved = try RailwayCodec.decodeOverpass(data, bounds: MapBounds(south: 28.3, west: 115.5, north: 29.0, east: 116.3),
                                                       name: "南昌 · 实际 OSM 整线数据", sourceURL: DataEndpoint.vk.rawValue)
            saved.stations = try MetroRouteDecoder.decode(data).stations
            store.dataset = saved
            store.onlineLoading = false
            store.rebuildIndex()
            store.rebuildVisible()
        }
        var firstTrack: Double?, firstColour: Double?
        for _ in 0..<160 {
            try await Task.sleep(for: .milliseconds(500))
            if firstTrack == nil && store.activeLines.count > 100 { firstTrack = Date().timeIntervalSince(started) }
            if firstColour == nil && store.urbanRoutes.filter({ $0.color != nil }).count >= 4 {
                firstColour = Date().timeIntervalSince(started)
            }
            if !store.onlineLoading { break }
        }
        let isSaved = CommandLine.arguments.contains("--saved-metro")
        var notes = ["Nanchang \(isSaved ? "saved real geometry (not live)" : "live"): first tracks \(firstTrack.map { String(format: "%.1fs", $0) } ?? "unavailable"), first 4 coloured lines \(firstColour.map { String(format: "%.1fs", $0) } ?? "unavailable").",
                     "Viewport \(store.tilesReady)/\(store.tilesExpected), \(store.onlineStations.count) station objects, \(store.onlineError ?? "no error")."]
        let missing = store.activeLines.filter { $0.category == .urban && $0.appearance.colors.isEmpty }
        notes.append("Urban segments without a known colour: \(missing.count); names: \(Set(missing.map(\.name)).sorted().prefix(12).joined(separator: ", ")).")
        store.selectedTab = 1
        store.dimsBasemap = true
        try await Task.sleep(for: .seconds(1))
        try await capture("01-nanchang-apple-dimmed", directory: directory, window: window)
        guard firstColour != nil else { throw DataError.invalid(notes.joined(separator: "\n")) }
        let p = Coordinate(28.6266186, 115.7882702)
        guard MapAlignment.distance(p, store.alignment.display(p)) > 500 else {
            throw DataError.invalid("Bundled coordinate mask did not load")
        }
        if !isSaved {
            store.changeMode(.cached)
            try await settle(store, seconds: 10)
        }
        try await capture("02-nanchang-cache-colours", directory: directory, window: window)
        guard let route = store.urbanRoutes.first else { throw DataError.invalid("No cached routes") }
        let before = store.visibleLines.count
        store.hiddenRoutes.insert(route.visibilityKey)
        guard store.visibleLines.count < before,
              store.visibleLines.allSatisfy({ !($0.routes ?? []).contains { $0.visibilityKey == route.visibilityKey } }) else {
            throw DataError.invalid("Per-route switch did not hide route geometry")
        }
        notes.append("Per-route switch removed \(before - store.visibleLines.count) fragments; no visible fragment retains hidden line.")
        try await capture("03-single-line-hidden", directory: directory, window: window)
        store.hiddenRoutes = []
        store.categories.remove(.speed350)
        guard !store.visibleLines.contains(where: { $0.category == .speed350 }) else { throw DataError.invalid("Speed switch failed") }
        store.categories = Set(RailCategory.allCases)
        store.showsMetroColors = false
        guard store.renderGroups.allSatisfy({ $0.appearance.colors.isEmpty }) else { throw DataError.invalid("Colour switch failed") }
        store.showsMetroColors = true
        if isSaved {
            store.region.span.latitudeDelta *= 0.3
            store.region.span.longitudeDelta *= 0.3
        } else {
            store.zoom(0.3)
            try await settle(store, seconds: 10)
        }
        try await capture("04-close-stations", directory: directory, window: window)
        if let line = store.visibleLines.first(where: { $0.tags["operator"] != nil }) {
            store.selection = RailwayMapStore.item(line)
            try await Task.sleep(for: .milliseconds(300))
            try await capture("05-metadata", directory: directory, window: window)
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(300))
        try await capture("06-dark", directory: directory, window: window)
        try await store.tileRepository.exportCache(to: directory.appendingPathComponent("Nanchang.railcache"))
        notes.append("Speed, colour, cached mode and bundled alignment checks passed. MapKit Metal capture requires permission; cached Canvas screenshots are available.")
        let report = notes.joined(separator: "\n")
        try Data(report.utf8).write(to: directory.appendingPathComponent("ui-smoke.txt"))
        print(report)
    }

    private static func settle(_ store: RailwayMapStore, seconds: Int) async throws {
        try await Task.sleep(for: .seconds(2))
        for _ in 0..<seconds {
            if !store.onlineLoading && !store.metroLoading { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw DataError.invalid("Viewport loading exceeded QA deadline: \(store.onlineStatus)")
    }

    enum CaptureMethod: String {
        case compositor
        case viewSnapshot
    }

    @discardableResult
    static func capture(_ name: String, directory: URL, window: NSWindow?) async throws -> CaptureMethod {
        let window = window?.attachedSheet ?? window
        // Metal-backed MapKit cannot be captured by NSView.cacheDisplay.
        // Prefer the compositor for MapKit. A locked or headless session may
        // expose the window but decline capture; retain the view snapshot then.
        if let window {
            let content: SCShareableContent?
            if #available(macOS 14.4, *) {
                content = try? await SCShareableContent.currentProcess
            } else if CGPreflightScreenCaptureAccess() {
                content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            } else {
                content = nil
            }
            if let target = content?.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(target.frame.width * window.backingScaleFactor)
                configuration.height = Int(target.frame.height * window.backingScaleFactor)
                configuration.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration),
                   let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try data.write(to: directory.appendingPathComponent("\(name).png"))
                    return .compositor
                }
            }
        }
        guard let view = window?.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DataError.invalid("No visible app window")
        }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw DataError.invalid("Window capture failed")
        }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        return .viewSnapshot
    }
}
#endif
