#if os(macOS)
import Darwin
import Foundation
import MapKit
import RailwayCore

/// Explicit, synchronous QA: call before store.start() to avoid starting map
/// downloads. All favorite writes go to a disposable UserDefaults suite.
@MainActor
enum DiscoveryValidation {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--v020-discovery-check") else { return }
        do {
            print(try run())
            exit(EXIT_SUCCESS)
        } catch {
            print("FAIL discovery: \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
    }

    static func run() throws -> String {
        let suiteName = "app.railwayatlas.discovery-validation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw DataError.invalid("Cannot create isolated discovery defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let standardIDs = UserDefaults.standard.stringArray(forKey: "railway.favorites")
        let standardSnapshots = UserDefaults.standard.data(forKey: "railway.favoriteSnapshots.v1")

        // Do not call start, rebuildIndex, toggleFavorite or the shared store:
        // those are application hooks. Exercise their injected implementation
        // directly, with real RailStation/RailLine/RailwaySelection values.
        let map = RailwayMapStore()
        map.mapMode = .apple
        map.dataset = nil
        let a = try station("fixture/z10/a", osm: "node/910001", longitude: 139.0)
        let b = try station("fixture/z10/b", osm: "node/910002", longitude: 139.00001)
        let lowLine = try line("fixture/z8/track", longitude: 139.0)
        let missing = "fixture/unloaded/legacy"
        map.onlineStations = [a, b]
        map.onlineLines = [lowLine]
        map.favoriteIDs = [a.id, b.id, lowLine.id, missing]
        defaults.set(map.favoriteIDs.sorted(), forKey: "railway.favorites")
        let favorites = FavoriteStore(defaults: defaults, writesEnabled: true)
        favorites.reconcile(with: map)
        let expectedIDs: Set<String> = ["node/910001", "node/910002", "way/920001", missing]
        try require(map.favoriteIDs == expectedIDs, "Visible legacy fragment IDs were not migrated")
        try require(favorites.entries.count == 4, "Same-name adjacent stations merged or unknown ID vanished")
        try require(favorites.entries.filter { $0.snapshot?.kind == .station }.count == 2,
                    "Same-name adjacent stations must remain independent")
        try require(favorites.entries.first { $0.id == missing }?.snapshot == nil,
                    "An unavailable legacy ID acquired fabricated metadata")
        try require(favorites.contains(RailwayMapStore.item(a), ids: map.favoriteIDs),
                    "Favorite membership does not recognize a source identity")
        let original = try snapshot("way/920001", in: favorites)
        try require(original.kind == .line && original.sourceID == lowLine.id
                    && original.tags == lowLine.tags, "Line type or original fields were lost")
        var report = ["PASS legacy IDs migrate by exact OSM identity; same-name stations one metre apart stay separate; unavailable IDs remain pending."]

        let reloaded = FavoriteStore(defaults: defaults, writesEnabled: true)
        let restored = try snapshot("way/920001", in: reloaded)
        let restoredSelection = restored.selection
        let expectedSelection = RailwayMapStore.item(lowLine)
        try require(restored == original
                    && restoredSelection.id == expectedSelection.id
                    && restoredSelection.name == expectedSelection.name
                    && restoredSelection.subtitle == expectedSelection.subtitle
                    && restoredSelection.coordinate == expectedSelection.coordinate
                    && restoredSelection.tags == expectedSelection.tags,
                    "Reload failed to preserve all RailwaySelection fields")
        try require(reloaded.entries.count == 4, "Reload lost a pending legacy ID")

        map.onlineLines = []
        map.onlineStations = []
        reloaded.reconcile(with: map)
        try require(map.favoriteIDs == expectedIDs && reloaded.entries.count == 4
                    && reloaded.entries.allSatisfy { !$0.isLoaded },
                    "Leaving the viewport removed favorites or retained stale loaded state")
        try require(try snapshot("way/920001", in: reloaded) == original,
                    "Unloading changed the saved navigation position")
        report.append("PASS isolated persistence reload restores type, original ID, name, subtitle, coordinate and raw tags; unloading preserves snapshots and pending IDs.")

        let highLine = try line("fixture/z15/different-fragment", longitude: 139.02)
        map.onlineLines = [highLine]
        map.onlineStations = [a, b]
        reloaded.reconcile(with: map)
        try require(reloaded.contains(RailwayMapStore.item(highLine), ids: map.favoriteIDs),
                    "Changed tile ID lost favorite membership")
        try require(try snapshot("way/920001", in: reloaded).coordinate == original.coordinate,
                    "Another tile fragment moved the saved bookmark")
        reloaded.toggle(highLine.id, in: map)
        reloaded.reconcile(with: map)
        let afterRemoval = FavoriteStore(defaults: defaults, writesEnabled: true)
        afterRemoval.reconcile(with: map)
        try require(!map.favoriteIDs.contains("way/920001")
                    && !afterRemoval.entries.contains { $0.id == "way/920001" },
                    "Cancelled favorite resurrected after reload/reindex")
        afterRemoval.remove(missing, in: map)
        afterRemoval.reconcile(with: map)
        try require(!map.favoriteIDs.contains(missing)
                    && !FavoriteStore(defaults: defaults, writesEnabled: true).entries.contains { $0.id == missing },
                    "Removing an unresolved legacy ID was not persisted")

        // Explicit re-add saves the new selection; simple viewport refreshes do
        // not. This also covers the normal toggle path through map.selection.
        map.selection = RailwayMapStore.item(highLine)
        afterRemoval.toggle(highLine.id, in: map)
        try require(try snapshot("way/920001", in: afterRemoval).sourceID == highLine.id,
                    "Explicit re-add did not capture the current selection")
        afterRemoval.toggle(highLine.id, in: map)
        afterRemoval.reconcile(with: map)
        try require(map.favoriteIDs == ["node/910001", "node/910002"],
                    "Toggle disturbed independent favorites")
        report.append("PASS changed zoom IDs retain membership and the saved center; cancel/reload/reindex cannot resurrect removed favorites; explicit re-add captures the new selection.")

        // Catch cancellation before a legacy record has had its first reindex.
        map.favoriteIDs = [highLine.id]
        defaults.set([highLine.id], forKey: "railway.favorites")
        let unmigrated = FavoriteStore(defaults: defaults, writesEnabled: true)
        unmigrated.toggle(highLine.id, in: map)
        unmigrated.reconcile(with: map)
        try require(map.favoriteIDs.isEmpty && unmigrated.entries.isEmpty,
                    "A legacy fragment could not be cancelled before migration")
        try require(FavoriteIdentity.key(for: RailwaySelection(
            id: "node/930001", name: "fixture", subtitle: "", tags: [:],
            coordinate: Coordinate(35, 139))) == "node/930001",
                    "osmReference fallback failed")
        try require(FavoriteIdentity.osmID("node/not-a-number") == nil,
                    "Malformed source reference accepted")

        try require(Set(DiscoveryCatalog.cities.map(\.id)).count == DiscoveryCatalog.cities.count,
                    "Duplicate city catalog identities")
        try require(Set(DiscoveryCatalog.stations.map(\.id)).count == DiscoveryCatalog.stations.count,
                    "Duplicate station catalog identities")
        try require(DiscoveryCatalog.cities.allSatisfy { $0.coordinate.isValid },
                    "Invalid city coordinates")
        try require(DiscoveryCatalog.stations.allSatisfy {
            $0.coordinate.isValid && !$0.country.isEmpty && !$0.referenceArticle.isEmpty
                && $0.referenceURL.host == "en.wikipedia.org" && !$0.referenceURL.absoluteString.contains("%25")
        }, "Invalid station navigation centers or reference URLs")
        for city in DiscoveryCatalog.cities {
            let region = city.region
            let center = region.center
            let north = CLLocation(latitude: center.latitude + region.span.latitudeDelta / 2, longitude: center.longitude)
            let south = CLLocation(latitude: center.latitude - region.span.latitudeDelta / 2, longitude: center.longitude)
            let east = CLLocation(latitude: center.latitude, longitude: center.longitude + region.span.longitudeDelta / 2)
            let west = CLLocation(latitude: center.latitude, longitude: center.longitude - region.span.longitudeDelta / 2)
            try require(abs(north.distance(from: south) - 50_000) < 2_000
                        && abs(east.distance(from: west) - 50_000) < 2_000,
                        "City region is not approximately 50 × 50 km: \(city.name)")
        }
        var rng = SeededGenerator()
        var previousCities = Set<String>()
        var previousStations = Set<String>()
        for _ in 0..<64 {
            let cities = DiscoveryCatalog.randomCities(excluding: previousCities, using: &rng)
            let stations = DiscoveryCatalog.randomStations(excluding: previousStations, using: &rng)
            let cityIDs = Set(cities.map(\.id)), stationIDs = Set(stations.map(\.id))
            try require(cities.count == 10 && cityIDs.count == 10 && cityIDs.isDisjoint(with: previousCities),
                        "City refresh has the wrong size, duplicates or previous entries")
            try require(stations.count == 20 && stationIDs.count == 20 && stationIDs.isDisjoint(with: previousStations),
                        "Station refresh has the wrong size, duplicates or previous entries")
            for kind in DiscoveryStationKind.allCases {
                try require(stations.filter { $0.kind == kind }.count == 5,
                            "Station refresh did not retain five entries per category")
            }
            previousCities = cityIDs
            previousStations = stationIDs
        }
        report.append("PASS 64 seeded refreshes: ten distinct cities, twenty distinct landmarks, five per category, no immediate repeats; all catalog coordinates and 50 × 50 km city regions valid.")
        report.append(try filingChecks())
        try require(UserDefaults.standard.stringArray(forKey: "railway.favorites") == standardIDs
                    && UserDefaults.standard.data(forKey: "railway.favoriteSnapshots.v1") == standardSnapshots,
                    "Discovery checks changed real favorite preferences")
        report.append("PASS real favorite preferences unchanged; disposable defaults suite removed on return. No network requests or app map hooks.")
        return report.joined(separator: "\n")
    }

    private static func filingChecks() throws -> String {
        let suiteName = "app.railwayatlas.favorite-filing-validation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw DataError.invalid("Cannot create isolated filing defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archiveKey = "railway.favoriteSnapshots.v1"
        let map = RailwayMapStore()
        map.mapMode = .apple
        map.dataset = nil
        var original = try station("fixture/filing/old", osm: "node/940001", longitude: 139)
        original.tags["addr:city"] = "来源东京"
        let pendingID = "fixture/filing/pending"
        let originalDate = Date(timeIntervalSince1970: 1_600_000_000)
        let originalSnapshot = FavoriteSnapshot(RailwayMapStore.item(original), kind: .station, savedAt: originalDate)

        // Exact old schema: there is no annotations field in this archive.
        struct LegacyArchive: Encodable {
            let version = 1
            let snapshots: [FavoriteSnapshot]
        }
        defaults.set(try JSONEncoder().encode(LegacyArchive(snapshots: [originalSnapshot])), forKey: archiveKey)
        defaults.set([original.id, pendingID], forKey: "railway.favorites")
        map.favoriteIDs = [original.id, pendingID]
        map.onlineStations = [original]
        let initial = FavoriteStore(defaults: defaults, writesEnabled: true)
        initial.reconcile(with: map)
        try require(try snapshot(originalSnapshot.id, in: initial) == originalSnapshot,
                    "Old-schema decoding or migration changed saved fields")
        try require(initial.entries.allSatisfy { $0.annotation == FavoriteAnnotation() },
                    "Old schema should default to empty user filing")
        try require(initial.entries.first { $0.id == originalSnapshot.id }?.citySuggestion?.city == "来源东京",
                    "Explicit city source was not offered as a suggestion")
        let parsed = FavoriteAnnotation.labels(from: " 想去,夜景，想去,, \n 换乘 ")
        try require(parsed == ["想去", "夜景", "换乘"], "Comma parsing, trimming or deduplication failed")
        try require(initial.updateAnnotation(original.id, city: " 手工东京 ", labels: parsed, in: map),
                    "Could not edit a migrated legacy ID")
        try require(initial.updateAnnotation(pendingID, city: "旧城", labels: ["待补资料"], in: map),
                    "Pending favorites cannot be filed before map metadata arrives")
        try require(initial.entries(inCity: "旧城").first?.snapshot == nil
                    && initial.entries(inCity: "旧城").count == 1,
                    "Filing fabricated a pending favorite's location or broke filtering")
        let filed = FavoriteAnnotation(city: "手工东京", labels: parsed)

        let restored = FavoriteStore(defaults: defaults, writesEnabled: true)
        try require(restored.entries.first { $0.id == originalSnapshot.id }?.annotation == filed
                    && restored.entries.first { $0.id == pendingID }?.annotation.city == "旧城",
                    "Reload dropped city/custom labels or pending filing")
        try require(try snapshot(originalSnapshot.id, in: restored).savedAt == originalDate,
                    "Filing reset the saved date")
        let unchanged = defaults.data(forKey: archiveKey)
        restored.reconcile(with: map)
        restored.reconcile(with: map)
        try require(restored.updateAnnotation(originalSnapshot.id, city: filed.city, labels: filed.labels, in: map),
                    "Unchanged filing was not accepted")
        try require(defaults.data(forKey: archiveKey) == unchanged,
                    "Identical reconciliation or filing changed the archive")

        var updated = original
        updated.name = "更新后的站名"
        updated.coordinate = Coordinate(35.02, 139.02)
        updated.tags["addr:city"] = "来源横滨"
        updated.tags["operator"] = "Updated source operator"
        map.onlineStations = [updated]
        restored.reconcile(with: map)
        let refreshed = try snapshot(originalSnapshot.id, in: restored)
        try require(refreshed.name == updated.name && refreshed.tags == updated.tags
                    && refreshed.coordinate == originalSnapshot.coordinate && refreshed.savedAt == originalDate,
                    "Metadata refresh lost the bookmark coordinate/date or did not update source fields")
        try require(restored.entries.first { $0.id == originalSnapshot.id }?.annotation == filed,
                    "Source metadata overwrote custom labels/city")
        // The old local package must not downgrade a newer snapshot on unload.
        map.dataset = try JSONDecoder().decode(RailwayDataset.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "name": "Old fixture package",
            "downloadedAt": originalDate.timeIntervalSinceReferenceDate,
            "sourceURL": "https://example.invalid/fixture",
            "bounds": ["south": 34.0, "west": 138.0, "north": 36.0, "east": 140.0],
            "lines": [], "stations": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))]
        ]))
        map.onlineStations = []
        restored.reconcile(with: map)
        try require(try snapshot(originalSnapshot.id, in: restored) == refreshed,
                    "Inactive package overwrote newer snapshot metadata")
        try require(restored.entries.first { $0.id == originalSnapshot.id }?.annotation == filed,
                    "Unloading discarded custom filing")

        let arrived = try station(pendingID, osm: "node/940002", longitude: 139.00001)
        map.onlineStations = [updated, arrived]
        restored.reconcile(with: map)
        try require(!map.favoriteIDs.contains(pendingID) && map.favoriteIDs.contains("node/940002"),
                    "Pending ID did not migrate when exact source identity arrived")
        try require(restored.entries.first { $0.id == "node/940002" }?.annotation
                    == FavoriteAnnotation(city: "旧城", labels: ["待补资料"]),
                    "Pending-to-source migration discarded custom filing")
        try require(restored.updateAnnotation(pendingID, city: "恢复后手工城", labels: ["待补资料", "已确认"], in: map),
                    "Editor opened before migration cannot save through the old ID")
        try require(FavoriteCitySuggestion.from(tags: ["name": "东京站", "operator": "东京地铁"]) == nil,
                    "City was guessed from station name/operator")
        try require(FavoriteCitySuggestion.from(tags: ["place": "city", "name": "明确城市"])?.city == "明确城市",
                    "Explicit city feature name was not recognized")
        try require(restored.updateAnnotation(originalSnapshot.id, city: "", labels: parsed, in: map),
                    "Could not clear a manual city")
        restored.reconcile(with: map)
        try require(restored.entries(inCity: "").contains { $0.id == originalSnapshot.id },
                    "Explicitly cleared city was auto-filled during reconciliation")
        let clearedReload = FavoriteStore(defaults: defaults, writesEnabled: true)
        try require(clearedReload.entries.first { $0.id == originalSnapshot.id }?.annotation
                    == FavoriteAnnotation(city: "", labels: parsed),
                    "Reload lost labels or restored an explicitly cleared city")
        try require(restored.cityGroups.flatMap(\.entries).count == restored.entries.count,
                    "City grouping lost or duplicated favorites")

        map.selection = RailwayMapStore.item(updated)
        restored.toggle(updated.id, in: map)
        try require(!restored.updateAnnotation(updated.id, city: "过期编辑", labels: ["不应恢复"], in: map),
                    "A stale editor resurrected a removed favorite")
        let afterRemoval = FavoriteStore(defaults: defaults, writesEnabled: true)
        afterRemoval.toggle(updated.id, in: map)
        try require(afterRemoval.entries.first { $0.id == originalSnapshot.id }?.annotation == FavoriteAnnotation(),
                    "Re-adding a removed favorite resurrected its labels/city")
        let removedPending = "fixture/filing/remove-pending"
        afterRemoval.toggle(removedPending, in: map)
        try require(afterRemoval.updateAnnotation(removedPending, city: "待定", labels: ["待定标签"], in: map),
                    "Could not file an unresolved ID")
        afterRemoval.remove(removedPending, in: map)
        let afterPendingRemoval = FavoriteStore(defaults: defaults, writesEnabled: true)
        afterPendingRemoval.toggle(removedPending, in: map)
        try require(afterPendingRemoval.entries.first { $0.id == removedPending }?.annotation == FavoriteAnnotation(),
                    "Removing a pending favorite left its custom filing behind")

        // Multiple old fragments of the SAME explicit OSM identity retain all
        // labels when converging. Names/proximity are not used for this merge.
        let legacyA = "fixture/filing/alias-a", legacyB = "fixture/filing/alias-b"
        afterPendingRemoval.toggle(legacyA, in: map)
        afterPendingRemoval.toggle(legacyB, in: map)
        afterPendingRemoval.updateAnnotation(legacyA, city: "归档城", labels: ["甲"], in: map)
        afterPendingRemoval.updateAnnotation(legacyB, city: "归档城", labels: ["乙"], in: map)
        map.onlineStations += [
            try station(legacyA, osm: "node/940003", longitude: 139.1),
            try station(legacyB, osm: "node/940003", longitude: 139.1)
        ]
        afterPendingRemoval.reconcile(with: map)
        let final = FavoriteStore(defaults: defaults, writesEnabled: true)
        try require(final.entries.first { $0.id == "node/940003" }?.annotation.city == "归档城"
                    && Set(final.entries.first { $0.id == "node/940003" }?.annotation.labels ?? []) == ["甲", "乙"],
                    "Exact-identity alias migration or reload lost custom labels")
        try require(final.updateAnnotation("node/940003", city: "", labels: ["甲", "乙"], in: map),
                    "Could not clear the canonical city's filing")
        let lateAlias = "fixture/filing/late-alias"
        final.toggle(lateAlias, in: map)
        final.updateAnnotation(lateAlias, city: "旧归档城", labels: ["丙"], in: map)
        map.onlineStations.append(try station(lateAlias, osm: "node/940003", longitude: 139.1))
        final.reconcile(with: map)
        let afterLateMigration = FavoriteStore(defaults: defaults, writesEnabled: true)
        try require(afterLateMigration.entries.first { $0.id == "node/940003" }?.annotation
                    == FavoriteAnnotation(city: "", labels: ["甲", "乙", "丙"]),
                    "Late alias migration overwrote the canonical city or lost custom labels")

        // Cancellation may precede rebuildIndex: no alias exists yet, but both
        // the old raw membership and its filing must be removed in that case.
        let unindexedID = "fixture/filing/cancel-before-migration"
        final.toggle(unindexedID, in: map)
        try require(final.updateAnnotation(unindexedID, city: "待迁移城", labels: ["待迁移标签"], in: map),
                    "Could not file an unmigrated ID")
        let unindexed = try station(unindexedID, osm: "node/940004", longitude: 139.2)
        map.onlineStations.append(unindexed)
        map.selection = RailwayMapStore.item(unindexed)
        final.toggle(unindexedID, in: map)
        final.reconcile(with: map)
        let afterUnindexedRemoval = FavoriteStore(defaults: defaults, writesEnabled: true)
        try require(!map.favoriteIDs.contains(unindexedID) && !map.favoriteIDs.contains("node/940004")
                    && !afterUnindexedRemoval.entries.contains { $0.id == unindexedID || $0.id == "node/940004" },
                    "Cancellation before migration retained membership or resurrected a favorite")
        afterUnindexedRemoval.toggle(unindexedID, in: map)
        afterUnindexedRemoval.reconcile(with: map)
        try require(afterUnindexedRemoval.entries.first { $0.id == "node/940004" }?.annotation == FavoriteAnnotation(),
                    "Cancellation before migration left custom filing behind")
        try require(try JSONDecoder().decode(FavoriteAnnotation.self, from: Data("{}".utf8)) == FavoriteAnnotation(),
                    "Missing annotation fields do not decode compatibly")
        return "PASS custom filing: old archives decode; city/labels survive reload, exact-ID migration and metadata refresh; source suggestions never guess or auto-fill; pending IDs are editable; removal clears filing; saved date/coordinate and newer metadata survive; city filters/groups retain every favorite."
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw DataError.invalid(message) }
    }

    private static func snapshot(_ id: String, in store: FavoriteStore) throws -> FavoriteSnapshot {
        guard let value = store.entries.first(where: { $0.id == id })?.snapshot else {
            throw DataError.invalid("Missing snapshot: \(id)")
        }
        return value
    }

    private static func station(_ id: String, osm: String, longitude: Double) throws -> RailStation {
        try JSONDecoder().decode(RailStation.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "name": "同名站",
            "coordinate": ["latitude": 35.0, "longitude": longitude],
            "tags": ["railway": "station", "atlas:osm": osm, "operator": "fixture", "country": "JP"]
        ]))
    }

    private static func line(_ id: String, longitude: Double) throws -> RailLine {
        try JSONDecoder().decode(RailLine.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "name": "回归线路",
            "coordinates": [
                ["latitude": 35.0, "longitude": longitude],
                ["latitude": 35.01, "longitude": longitude + 0.01]
            ],
            "tags": ["railway": "rail", "atlas:osm": "way/920001", "operator": "fixture", "ref": "Q"]
        ]))
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64 = 0xA71A5
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }
}
#endif
