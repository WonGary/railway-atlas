import Foundation
import MapKit
import RailwayCore
import SwiftUI

/// Only explicit source identities are interchangeable. In particular, neither
/// a station's name nor its distance from another station establishes identity.
enum FavoriteIdentity {
    static func osmID(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ["node", "way", "relation"].contains(String(parts[0])),
              let number = UInt64(parts[1]), number > 0 else { return nil }
        return "\(parts[0])/\(number)"
    }

    static func key(id: String, tags: [String: String]) -> String {
        osmID(tags["atlas:osm"]) ?? osmID(id) ?? id
    }

    static func key(for selection: RailwaySelection) -> String {
        osmID(selection.tags["atlas:osm"]) ?? osmID(selection.osmReference) ?? selection.id
    }
}

struct FavoriteSnapshot: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case station, line, place

        var title: String {
            switch self {
            case .station: "站点"
            case .line: "线路"
            case .place: "地点"
            }
        }

        var icon: String {
            switch self {
            case .station: "tram"
            case .line: "point.topleft.down.to.point.bottomright.curvepath"
            case .place: "mappin"
            }
        }
    }

    private(set) var id: String
    let sourceID: String
    private(set) var name: String
    private(set) var subtitle: String
    private(set) var tags: [String: String]
    let coordinate: Coordinate
    private(set) var kind: Kind
    let savedAt: Date
    var legacyIDs: Set<String>

    init(_ item: RailwaySelection, kind: Kind? = nil, savedAt: Date = Date(),
         legacyIDs: Set<String> = []) {
        id = FavoriteIdentity.key(for: item)
        sourceID = item.id
        name = item.name
        subtitle = item.subtitle
        tags = item.tags
        coordinate = item.coordinate
        self.kind = kind ?? (item.isStation ? .station :
            item.tags["railway"] != nil || item.tags["route"] != nil ? .line : .place)
        self.savedAt = savedAt
        self.legacyIDs = legacyIDs.union([item.id])
    }

    /// Restores every stored RailwaySelection field, including the original ID.
    /// Navigation must use the coordinate or an exact, currently loaded match,
    /// never assume that this old fragment ID still exists at another zoom.
    var selection: RailwaySelection {
        RailwaySelection(id: sourceID, name: name, subtitle: subtitle,
                         tags: tags, coordinate: coordinate)
    }

    func refreshed(with item: RailwaySelection, kind: Kind, active: Bool,
                   legacyIDs: Set<String>) -> Self {
        var value = self
        value.id = FavoriteIdentity.key(for: item)
        value.legacyIDs.formUnion(legacyIDs)
        // A bundled package only fills missing snapshots. Neither it nor a new
        // fragment may replace the saved position/date with another location.
        if active && sourceID == item.id {
            value.name = item.name
            value.subtitle = item.subtitle
            value.tags = item.tags
            value.kind = kind
        }
        return value
    }
}

/// User-owned filing, kept apart from OSM tags and available before a snapshot.
struct FavoriteAnnotation: Codable, Equatable {
    var city: String
    var labels: [String]

    init(city: String = "", labels: [String] = []) {
        self.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        self.labels = Self.normalizedLabels(labels)
    }

    private enum CodingKeys: String, CodingKey { case city, labels }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(city: try values.decodeIfPresent(String.self, forKey: .city) ?? "",
                  labels: try values.decodeIfPresent([String].self, forKey: .labels) ?? [])
    }

    static func labels(from text: String) -> [String] {
        normalizedLabels(text.components(separatedBy: CharacterSet(charactersIn: ",，\n\r")))
    }

    private static func normalizedLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// If legacy IDs converge, keep the canonical city (including a deliberate
    /// empty value) and union labels. Only exact source identities may converge.
    func merging(_ legacy: Self) -> Self {
        Self(city: city, labels: labels + legacy.labels)
    }
}

struct FavoriteCitySuggestion: Equatable {
    let city: String
    let source: String

    static func from(tags: [String: String]) -> Self? {
        var keys = ["addr:city:zh", "addr:city", "is_in:city"]
        if tags["place"] == "city" { keys += ["name:zh", "name"] }
        for key in keys {
            guard let city = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !city.isEmpty, !city.contains(";"), !city.contains("；") else { continue }
            return Self(city: city, source: key)
        }
        return nil
    }
}

struct FavoriteEntry: Identifiable, Equatable {
    let id: String
    let snapshot: FavoriteSnapshot?
    let isLoaded: Bool
    var annotation = FavoriteAnnotation()
    var citySuggestion: FavoriteCitySuggestion?
}

struct FavoriteCityGroup: Identifiable, Equatable {
    let city: String
    let entries: [FavoriteEntry]
    var id: String { city }
    var title: String { city.isEmpty ? "未设置城市" : city }
}

@MainActor
final class FavoriteStore: ObservableObject {
    static let shared = FavoriteStore()

    @Published private(set) var entries: [FavoriteEntry] = []
    @Published private(set) var cityGroups: [FavoriteCityGroup] = []
    @Published private(set) var persistenceMessage: String?

    private struct Archive: Codable {
        var version = 1
        let snapshots: [FavoriteSnapshot]
        let annotations: [String: FavoriteAnnotation]

        init(snapshots: [FavoriteSnapshot], annotations: [String: FavoriteAnnotation]) {
            self.snapshots = snapshots
            self.annotations = annotations
        }

        private enum CodingKeys: String, CodingKey { case version, snapshots, annotations }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            snapshots = try values.decode([FavoriteSnapshot].self, forKey: .snapshots)
            // Additive v1 field: existing build-4/5 archives remain readable.
            annotations = try values.decodeIfPresent([String: FavoriteAnnotation].self, forKey: .annotations) ?? [:]
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "railway.favoriteSnapshots.v1"
    private let writesEnabled: Bool
    private var snapshots: [String: FavoriteSnapshot] = [:]
    private var annotations: [String: FavoriteAnnotation] = [:]
    private var aliases: [String: String] = [:]
    private var loaded: [String: RailwaySelection] = [:]
    private var entriesByCity: [String: [FavoriteEntry]] = [:]
    private var unreadableArchive: Data?

    init(defaults: UserDefaults = .standard,
         writesEnabled: Bool = !CommandLine.arguments.contains("--ui-smoke")) {
        self.defaults = defaults
        self.writesEnabled = writesEnabled
        if let data = defaults.data(forKey: storageKey) {
            do {
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                for snapshot in archive.snapshots where !snapshot.id.isEmpty && snapshot.coordinate.isValid {
                    snapshots[snapshot.id] = snapshot
                }
                annotations = archive.annotations
            } catch {
                // Preserve unreadable bytes before any later successful write.
                unreadableArchive = data
                persistenceMessage = "收藏快照待恢复"
            }
        }
        rebuildAliases()
        normalizeAnnotations()
        publish(ids: Set(defaults.stringArray(forKey: "railway.favorites") ?? []))
    }

    func contains(_ item: RailwaySelection, ids: Set<String>) -> Bool {
        ids.contains(item.id) || ids.contains(FavoriteIdentity.key(for: item))
            || ids.contains(aliases[item.id] ?? item.id)
    }

    /// Cached grouping; callers need not scan all favorites on every map redraw.
    func entries(inCity city: String?) -> [FavoriteEntry] {
        guard let city else { return entries }
        return entriesByCity[city] ?? []
    }

    /// Also supports unresolved old IDs. Saving a draft never re-adds a favorite
    /// removed in another view while the editor was open.
    @discardableResult
    func updateAnnotation(_ id: String, city: String, labels: [String],
                          in map: RailwayMapStore) -> Bool {
        let key = aliases[id] ?? id
        let ids = Set(map.favoriteIDs.map { aliases[$0] ?? $0 })
        guard ids.contains(key) else { return false }
        let value = FavoriteAnnotation(city: city, labels: labels)
        guard (annotations[key] ?? FavoriteAnnotation()) != value else { return true }
        annotations[key] = value
        commit(ids: ids, to: map, archiveChanged: true)
        return true
    }

    /// Call once at the END of RailwayMapStore.rebuildIndex(), never from
    /// rebuildVisible(), renderRevision observers, or a View.body.
    /// One pass over the new data; only favorited features become selections.
    func reconcile(with map: RailwayMapStore) {
        let previous = snapshots
        let previousAnnotations = annotations
        normalizeAnnotations()
        var ids = Set(map.favoriteIDs.map { aliases[$0] ?? $0 })
        var nextLoaded: [String: RailwaySelection] = [:]

        func visit(id: String, tags: [String: String], kind: FavoriteSnapshot.Kind,
                   active: Bool, selection: () -> RailwaySelection) {
            let key = FavoriteIdentity.key(id: id, tags: tags)
            guard ids.contains(id) || ids.contains(key) else { return }
            let item = selection()
            guard item.coordinate.isValid else { return }
            let wasLegacy = id != key && ids.remove(id) != nil
            ids.insert(key)
            migrateAnnotation(from: id, to: key)
            let old = snapshots[key] ?? snapshots[id]
            var legacy = old?.legacyIDs ?? []
            if wasLegacy { legacy.insert(id) }

            if let old {
                snapshots[key] = old.refreshed(with: item, kind: kind, active: active, legacyIDs: legacy)
            } else {
                snapshots[key] = FavoriteSnapshot(item, kind: kind,
                    legacyIDs: legacy)
            }
            if id != key { snapshots.removeValue(forKey: id) }
            if active {
                if nextLoaded[key] == nil || item.id == snapshots[key]?.sourceID {
                    nextLoaded[key] = item
                }
            }
        }

        // The local package is also usable migration evidence at startup, even
        // while the online map is active. It is not marked as currently loaded.
        if map.mapMode != .offline, let dataset = map.dataset {
            for station in dataset.stations {
                visit(id: station.id, tags: station.tags, kind: .station, active: false) {
                    RailwayMapStore.item(station)
                }
            }
            for line in dataset.lines where !line.coordinates.isEmpty {
                visit(id: line.id, tags: line.tags, kind: .line, active: false) {
                    RailwayMapStore.item(line)
                }
            }
        }
        for line in map.activeLines where !line.coordinates.isEmpty {
            visit(id: line.id, tags: line.tags, kind: .line, active: true) {
                RailwayMapStore.item(line)
            }
        }
        for station in map.activeStations {
            visit(id: station.id, tags: station.tags, kind: .station, active: true) {
                RailwayMapStore.item(station)
            }
        }
        snapshots = snapshots.filter { ids.contains($0.key) }
        annotations = annotations.filter { ids.contains($0.key) }
        loaded = nextLoaded
        rebuildAliases()
        commit(ids: ids, to: map, archiveChanged: previous != snapshots || previousAnnotations != annotations)
    }

    /// Replaces toggleFavorite's old ID-only implementation. Selection is the
    /// normal O(1) path; the fallback lookup runs only on an explicit user action.
    func toggle(_ id: String, in map: RailwayMapStore) {
        let item = resolve(id, in: map)
        let key = item.map(FavoriteIdentity.key(for:)) ?? aliases[id] ?? id
        var ids = Set(map.favoriteIDs.map { aliases[$0] ?? $0 })
        if ids.contains(id) || ids.contains(key) {
            aliases[id] = key
            remove(key, in: map)
            return
        }
        ids.insert(key)
        if let item, item.coordinate.isValid {
            snapshots[key] = FavoriteSnapshot(item)
            loaded[key] = item
        }
        rebuildAliases()
        commit(ids: ids, to: map, archiveChanged: item != nil)
    }

    func remove(_ id: String, in map: RailwayMapStore) {
        let key = aliases[id] ?? id
        let ids = Set(map.favoriteIDs.compactMap { value -> String? in
            let canonical = aliases[value] ?? value
            return canonical == key ? nil : canonical
        })
        let removed = snapshots.removeValue(forKey: key) != nil
        let previousAnnotations = annotations
        annotations = annotations.filter { (aliases[$0.key] ?? $0.key) != key }
        loaded.removeValue(forKey: key)
        rebuildAliases()
        commit(ids: ids, to: map, archiveChanged: removed || previousAnnotations != annotations)
    }

    func locate(_ entry: FavoriteEntry, on map: RailwayMapStore) {
        if let item = loaded[entry.id] {
            map.searchText = ""
            map.select(item)
            return
        }
        guard let snapshot = entry.snapshot else { return }
        map.selection = nil
        map.searchText = ""
        map.showsStations = true
        map.region = MKCoordinateRegion(center: snapshot.coordinate.location,
                                        latitudinalMeters: 6_000, longitudinalMeters: 6_000)
        map.cameraRevision += 1
        if map.mapMode == .offline {
            map.changeMode(.apple)
        } else {
            map.rebuildVisible()
            map.refreshViewport()
        }
        map.showMessage("已定位收藏，点选地图查看当前详情。")
    }

    private func resolve(_ id: String, in map: RailwayMapStore) -> RailwaySelection? {
        let key = aliases[id] ?? id
        if let item = map.selection,
           item.id == id || FavoriteIdentity.key(for: item) == key { return item }
        if let item = loaded[key] { return item }
        if let station = map.activeStations.first(where: {
            $0.id == id || FavoriteIdentity.key(id: $0.id, tags: $0.tags) == key
        }) { return RailwayMapStore.item(station) }
        if let line = map.activeLines.first(where: {
            !$0.coordinates.isEmpty && ($0.id == id || FavoriteIdentity.key(id: $0.id, tags: $0.tags) == key)
        }) { return RailwayMapStore.item(line) }
        return nil
    }

    private func rebuildAliases() {
        aliases = [:]
        for snapshot in snapshots.values {
            aliases[snapshot.sourceID] = snapshot.id
            for id in snapshot.legacyIDs { aliases[id] = snapshot.id }
        }
    }

    private func migrateAnnotation(from id: String, to key: String) {
        guard id != key, let legacy = annotations.removeValue(forKey: id) else { return }
        annotations[key] = annotations[key].map { $0.merging(legacy) } ?? legacy
    }

    private func normalizeAnnotations() {
        for id in annotations.keys.sorted() {
            if let key = aliases[id] { migrateAnnotation(from: id, to: key) }
        }
    }

    private func commit(ids: Set<String>, to map: RailwayMapStore, archiveChanged: Bool) {
        if archiveChanged { persistSnapshots() }
        if map.favoriteIDs != ids {
            map.favoriteIDs = ids
            if writesEnabled { defaults.set(ids.sorted(), forKey: "railway.favorites") }
        }
        publish(ids: ids)
    }

    private func persistSnapshots() {
        guard writesEnabled else { return }
        do {
            let archive = Archive(snapshots: snapshots.values.sorted { $0.id < $1.id }, annotations: annotations)
            let data = try JSONEncoder().encode(archive)
            if let unreadableArchive {
                // A recovery copy is intentionally outside the normal read path.
                defaults.set(unreadableArchive, forKey: storageKey + ".recovery")
                self.unreadableArchive = nil
            }
            defaults.set(data, forKey: storageKey)
            persistenceMessage = nil
        } catch {
            persistenceMessage = "收藏快照保存失败"
        }
    }

    private func publish(ids: Set<String>) {
        let next = Set(ids.map { aliases[$0] ?? $0 }).map { id in
            FavoriteEntry(id: id, snapshot: snapshots[id], isLoaded: loaded[id] != nil,
                          annotation: annotations[id] ?? FavoriteAnnotation(),
                          citySuggestion: FavoriteCitySuggestion.from(tags: loaded[id]?.tags ?? snapshots[id]?.tags ?? [:]))
        }.sorted { left, right in
            let lhs = left.snapshot?.savedAt ?? .distantPast
            let rhs = right.snapshot?.savedAt ?? .distantPast
            return lhs == rhs ? left.id < right.id : lhs > rhs
        }
        if entries != next {
            entriesByCity = Dictionary(grouping: next, by: { $0.annotation.city })
            cityGroups = entriesByCity.map { FavoriteCityGroup(city: $0.key, entries: $0.value) }.sorted {
                if $0.city.isEmpty != $1.city.isEmpty { return !$0.city.isEmpty }
                return $0.city.localizedStandardCompare($1.city) == .orderedAscending
            }
            entries = next
        }
    }
}
