#if os(macOS)
import AppKit
import MapKit
import RailwayCore

@MainActor
enum RideGuideValidation {
    static func run(_ map: RailwayMapStore, directory: URL) async throws {
        func check(_ condition: Bool, _ detail: String) throws {
            if !condition { throw DataError.invalid(detail) }
        }
        let paths = NationalJourneyPaths.shared, player = map.journeyPlayer, guide = player.guide
        guard let table = try await paths.timetable(train:"D174", date:"2026-11-26"),
              let track = try await paths.journey(table),
              let start = track.legs.first?.first else { throw DataError.invalid("D174 径路缺失") }
        try player.start(table, route: track)
        defer { player.stop() }
        player.browse()
        let startTime = player.seconds, originalCamera = map.region
        try await Task.sleep(for:.milliseconds(350))
        try check(player.playing && player.seconds > startTime && !player.follow &&
                  map.region.center.latitude == originalCamera.center.latitude, "观光时播放或相机异常")
        player.resumeFollowing(); player.lockZoom(true)
        let span = map.region.span
        map.zoom(0.5)
        try check(player.holdsZoom && map.region.span.latitudeDelta == span.latitudeDelta, "缩放锁失效")
        player.userPanned()
        try check(!player.follow && player.playing && !player.holdsZoom, "拖图暂离失败")
        map.zoom(0.5)
        player.resumeFollowing(); player.pause()
        try check(player.holdsZoom && map.region.span.latitudeDelta == span.latitudeDelta, "恢复跟随或锁定尺度失败")
        player.seek(Double(table.start*60))
        let locations = try await guide.catalog.nearby(route:track, session:guide.session, leg:0,
            coordinate:start, kinds:RideGuideStore.kinds.map(\.0))
        try check(locations.contains(where:{ $0.name == "西宁" && !$0.url.isEmpty }), "西宁附近站点或来源缺失")
        let onlyCities = try await guide.catalog.nearby(route:track, session:guide.session, leg:0, coordinate:start, kinds:["city"])
        try check(onlyCities.allSatisfy { $0.kind == "city" }, "类别筛选失效")
        guard let place = locations.first else { throw DataError.invalid("没有可定位的地点") }
        player.inspectPlace(place)
        try check(!player.follow && map.region.center.latitude == place.lat && map.ridePlace?.id == place.id, "地点图钉或相机没有移到目标")
        player.resumeFollowing()
        try check(map.ridePlace == nil, "恢复跟随后地点图钉仍在")
        guard let index = table.stops.firstIndex(where:{$0.station == "广元"}) else { throw DataError.invalid("缺广元站") }
        let first = try await guide.connections(player, stop:index, hours:6)
        guard let transfer = first.first(where:{$0.trip=="490000Z31804"}),
              let end = transfer.destinations.first(where:{$0.name=="江油"}) else { throw DataError.invalid("广元站表缺 Z318") }
        try check(transfer.origin == "2026-11-25" && transfer.boardDate == "2026-11-26" && transfer.wait == 14,
                  "Z318 始发日、乘车日或接续时间错配")
        // The same candidate must be rejected if the old train has left this stop.
        player.seek(Double((table.stops[index].departure!+1)*60))
        var rejected = false
        do { try await guide.board(transfer, at:index, through:end.index, player:player) }
        catch { rejected = true }
        try check(rejected && player.timetable?.id == table.id && guide.chain.isEmpty, "已过站的班次改变了当前行程")
        player.seek(Double(table.start*60))
        try await guide.board(transfer, at:index, through:end.index, player:player)
        player.pause()
        try check(player.playbackTrack?.stations == ["广元","江油"] && player.playing == false &&
                  player.timetable?.serviceDate=="2026-11-26" && guide.origin=="2026-11-25","Z318 区间或日期错误")
        let second = try await guide.connections(player, stop:1, hours:6)
        guard let next = second.first(where:{$0.trip=="76000G868909"}),
              let mianyang = next.destinations.first(where:{$0.name=="绵阳"}) else { throw DataError.invalid("江油站表缺 G8689") }
        try await guide.board(next, at:1, through:mianyang.index, player:player)
        try check(player.playbackTrack?.stations == ["江油","绵阳"] && player.playing && player.timetable?.train == "G8689",
                  "第二次接续没有播放所选乘车区间")
        try check(guide.chain.count==2 && guide.chain[0].hasPrefix("D174") && guide.chain[1].hasPrefix("Z318"), "接力顺序错误")
        let receipt = ["PASS", "D174 西宁沿线地点 \(locations.count) 处", "广元 Z318 可选班次 \(first.count)，等待 \(transfer.wait) 分",
                       "江油 G8689 可选班次 \(second.count)，等待 \(next.wait) 分"] + guide.chain + ["G8689 江油 → 绵阳"]
        player.stop()
        try check(guide.chain.isEmpty && map.experienceMarker == nil, "退出后留有接力或列车标记")
        try Data((receipt.joined(separator:"\n") + "\n").utf8).write(to:directory.appendingPathComponent("journey-guide.txt"),options:.atomic)
    }
}
#endif
