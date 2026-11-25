import RailwayCore
import SwiftUI

struct MetroDirectionInspector: View {
    @EnvironmentObject private var store: RailwayMapStore
    let entry: MetroDirectionCatalog.Entry

    var body: some View {
        let direction = entry.direction
        VStack(alignment: .leading, spacing: 8) {
            Text(direction.name).font(.headline).textSelection(.enabled)
            HStack {
                Button("查看全线") { store.showMetroDirection(entry, fit: true) }
                if let reverse = store.directions.reverse(of: entry) {
                    Button("反方向") { store.focusRelation(reverse.route) }
                }
            }.buttonStyle(.bordered).controlSize(.small)
            Text("\(direction.stopCoverage == "operator" ? "全线站点" : "已收录站点") · \(direction.stops.count)")
                .font(.subheadline)
            if let note = direction.stopNote { Text("\(note)，站表可能不完整。").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(direction.stops.enumerated()), id: \.offset) { index, stop in
                Button {
                    if let pin = store.station(withID: stop.id) { store.select(RailwayMapStore.item(pin)) }
                } label: {
                    HStack {
                        Text(String(format: "%02d", index + 1)).monospacedDigit().foregroundStyle(.secondary)
                        Text(stop.name)
                        Spacer()
                        if store.selection?.id == stop.id { Image(systemName: "mappin") }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let source = direction.stopSource.flatMap(URL.init(string:)) { Link("北京地铁站序", destination: source).font(.caption) }
            Text("\(entry.city) · OSM \(entry.date) · ODbL 1.0").font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("metro-direction-inspector")
    }
}

struct MetroCityBrowser: View {
    @EnvironmentObject private var store: RailwayMapStore
    @State private var cityID = ""
    @State private var routeID = ""
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Picker("城市详情",selection:$cityID) {
                Text("当前地图区域").tag("")
                ForEach(MetroCitySpec.directory) { city in
                    Text(city.name + (city.country.map { " · "+$0 } ?? "")).tag(city.id)
                }
            }
            Button("加载城市线路和站序") {
                let city=MetroCitySpec.directory.first { $0.id == cityID } ?? .at(Coordinate(store.region.center.latitude,store.region.center.longitude))
                if !cityID.isEmpty {store.region=city.area.region;store.cameraRevision+=1}
                store.loadDirections(city,manual:true)
            }
            Text(store.directionStatus).font(.caption).foregroundStyle(.secondary)
            if let city=store.directionCity, !city.routes.isEmpty {
                Picker("线路方向",selection:$routeID) {
                    Text("选择线路").tag("")
                    ForEach(city.routes) { route in Text(route.name).tag(route.id) }
                }
                .onChange(of:city.id) { _,_ in routeID="" }
                .onChange(of:routeID) { _,id in
                    if let entry=store.directions.entries[id] {store.showMetroDirection(entry,fit:true)}
                }
            }
        }.controlSize(.small)
    }
}
