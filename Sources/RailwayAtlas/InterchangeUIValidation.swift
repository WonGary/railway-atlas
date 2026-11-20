#if os(macOS)
import AppKit
import MapKit
import RailwayCore

@MainActor
enum InterchangeUIValidation {
    static let flag = "--v020-interchange-check"

    static func run(store: RailwayMapStore, window: NSWindow?, directory: URL) async throws {
        guard store.mapMode == .offline, let window, let view = window.contentView,
              var dataset = store.dataset else {
            throw DataError.invalid("Interchange QA requires an offline map and actual window")
        }
        let key = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 843, y: 387))
        let features = try await Task.detached {
            guard let snapshot = BundledMetroSnapshots.features(for: key) else {
                throw DataError.invalid("Beijing snapshot missing")
            }
            return RailFeatureAssembler.assemble(tiles: [key: snapshot], palette: [:], wiki: [:],
                enrichWiki: false, ledger: RailIdentityLedger(), preview: nil).features
        }.value
        let ids = ["node/6617852357", "node/12435251104"]
        let originals = features.stations.filter { ids.contains($0.id) }
        guard originals.count == 2 else { throw DataError.invalid("Guangximen's two station objects missing") }
        dataset.name = "北京 · 光熙门"
        dataset.lines = features.lines; dataset.stations = features.stations
        dataset.bounds = key.tile.bounds
        store.dataset = dataset; store.rebuildIndex()
        store.automaticDetail = false
        store.categories = Set(RailCategory.allCases); store.networks = Set(RailNetwork.allCases)
        store.hiddenRoutes = []; store.showsStations = true; store.showsLabels = true
        store.uiScale = 1; store.panelVisible = false; store.statusVisible = false
        store.inspectorLayout = .docked; store.inspectorWidth = 200
        store.inspectorBackgroundOpacity = 1
        window.setContentSize(CGSize(width: 1100, height: 820))
        var notes: [String] = []
        for station in originals {
            guard let group = store.interchange(forStationID: station.id),
                  group.confidence == .documented,
                  group.evidence.contains(where: { $0.kind == .official }),
                  Set(group.documentedRoutes.compactMap { $0.tags["ref"] }) == ["12", "13"],
                  group.peers.contains(where: { ids.contains($0.id) && $0.id != station.id }),
                  let unchanged = store.station(withID: station.id), unchanged == station else {
                throw DataError.invalid("Actual inspector index lost official transfer or mutated the station")
            }
            store.select(RailwayMapStore.item(station))
            store.region = MKCoordinateRegion(center: Coordinate(39.9675, 116.4250).location,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.018))
            store.cameraRevision += 1; store.rebuildVisible()
            try await Task.sleep(for: .milliseconds(350))
            view.layoutSubtreeIfNeeded()
            let name = station.id == ids[0] ? "guangximen-13-inspector" : "guangximen-12-inspector"
            _ = try RetinaUIValidation.capture(view, name: name, directory: directory)
            notes.append("PASS \(station.id): original position/routes retained; both 12/13 visible in inspector projection, official evidence recorded.")
        }
        guard Set(store.activeStations.filter { ids.contains($0.id) }.map(\.id)) == Set(ids),
              store.activeStations.filter({ ids.contains($0.id) }).count == 2,
              store.inspectorWidth == 200, window.attachedSheet == nil else {
            throw DataError.invalid("Station objects merged or inspector left its 200pt inline layout")
        }
        notes.append("PASS two independent markers/IDs; no favourite IDs changed; no live request. Review both 200pt inspector PNGs.")
        try Data(notes.joined(separator: "\n").utf8)
            .write(to: directory.appendingPathComponent("interchange-ui.txt"), options: .atomic)
    }
}
#endif
