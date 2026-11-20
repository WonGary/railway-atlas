import Foundation
import RailwayCore

enum NationalMetroDisplayChecks {
    static func run() throws {
        let source = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"osm_id":1,"city":"测试城市","network":"测试网络",
           "line_name":"线路甲","route_type":"subway","ref":"A","colour":"#00AA11"},
           "geometry":{"type":"LineString","coordinates":[[120,31],[120.06,31]]}}
        ]}
        """
        let snapshot = try NationalMetroSnapshot.decodeGeoJSON(Data(source.utf8))
        let serviceSource = source.replacingOccurrences(of: "\"ref\":\"A\"",
            with: "\"ref\":\"A\",\"service\":\"metro\",\"usage\":\"branch\"")
        let serviceLine = try NationalMetroSnapshot.decodeGeoJSON(Data(serviceSource.utf8)).lines[0]
        guard serviceLine.appearance(showMetroColors: true).colors.first?.hex == "#00AA11",
              serviceLine.routes?.first?.tags["service"] == "metro", serviceLine.tags["usage"] == nil else {
            throw DataError.invalid("A metro route's service/branch metadata must not darken or hide its overview")
        }
        var route = snapshot.lines[0].routes![0]
        route.tags = ["route": "subway", "atlas:routeMaster": "", "atlas:paletteIdentity": " "]
        guard route.visibilityKey == route.id else {
            throw DataError.invalid("Empty master/palette fields must not merge unrelated national routes")
        }
        let alternateRoles = """
        {"elements":[{"type":"relation","id":1,"tags":{"type":"route","route":"subway"},"members":[
          {"type":"way","ref":1,"role":"route","geometry":[{"lat":31,"lon":120},{"lat":31,"lon":120.01}]},
          {"type":"way","ref":2,"role":"inactive","geometry":[{"lat":31,"lon":120.01},{"lat":31,"lon":120.02}]},
          {"type":"way","ref":3,"role":"platform","geometry":[{"lat":31,"lon":120.02},{"lat":31,"lon":120.03}]}
        ]}]}
        """
        let decoded = try MetroRouteDecoder.decode(Data(alternateRoles.utf8))
        guard Set(decoded.lines.compactMap { $0.tags["atlas:osm"] }) == ["way/1", "way/2"] else {
            throw DataError.invalid("Detail handoff must retain OSM route/inactive track roles and exclude platform geometry")
        }
        let middle = MapBounds(south: 30.99, west: 120.02, north: 31.01, east: 120.04)
        var liveLine = snapshot.lines[0]
        liveLine.id = "detail/1"
        liveLine.tags.removeValue(forKey: "atlas:nationalOverview")
        liveLine.coordinates = [Coordinate(31, 120.02), Coordinate(31, 120.04)]
        var live = RailTileFeatures()
        live.lines = [liveLine]
        func overviewParts(_ features: RailTileFeatures, country: Bool) -> [RailLine] {
            features.lines.filter { $0.tags["atlas:nationalOverview"] == "yes"
                && $0.tags["atlas:overviewLOD"] != (country ? "detail" : "country") }
        }
        let national = overviewParts(NationalMetroDisplay.merging(snapshot, into: live,
            detailCoverage: [middle], zoom: 4), country: true)
        guard national.count == 1, national[0].coordinates.count == 2 else {
            throw DataError.invalid("National overview should remain complete at country zoom")
        }
        let detail = overviewParts(NationalMetroDisplay.merging(snapshot, into: live,
            detailCoverage: [middle], zoom: 10), country: false)
        guard detail.count == 2,
              abs(detail[0].coordinates.last!.longitude - 120.02) < 1e-9,
              abs(detail[1].coordinates.first!.longitude - 120.04) < 1e-9,
              detail.allSatisfy({ $0.routes?.first?.color?.hex == "#00AA11" }) else {
            throw DataError.invalid("Complete detail must replace only its rectangle, without bridging the removed gap")
        }
        let missingRoute = overviewParts(NationalMetroDisplay.merging(snapshot, into: RailTileFeatures(),
            detailCoverage: [middle], zoom: 10), country: false)
        guard missingRoute.count == 1, missingRoute[0].coordinates == snapshot.lines[0].coordinates else {
            throw DataError.invalid("An old complete tile without this route must not erase a new overview line")
        }
        live.lines[0].coordinates = [Coordinate(31, 120.025), Coordinate(31, 120.03)]
        let oldExtension = overviewParts(NationalMetroDisplay.merging(snapshot, into: live,
            detailCoverage: [middle], zoom: 10), country: false)
        guard oldExtension.count == 1, oldExtension[0].coordinates == snapshot.lines[0].coordinates else {
            throw DataError.invalid("Old route geometry must not erase a new extension inside the same cell")
        }
        let partial = NationalMetroDisplay.merging(snapshot, into: RailTileFeatures(),
            detailCoverage: [], zoom: 12)
        guard partial.lines.count == 1, partial.lines[0].coordinates == snapshot.lines[0].coordinates else {
            throw DataError.invalid("Partial/failed detail must retain the entire overview geometry")
        }
        let whole = MapBounds(south: 30.9, west: 119.9, north: 31.1, east: 120.1)
        live.lines[0].coordinates = snapshot.lines[0].coordinates
        let covered = NationalMetroDisplay.merging(snapshot, into: live, detailCoverage: [whole], zoom: 10)
        guard overviewParts(covered, country: false).isEmpty,
              overviewParts(covered, country: true).count == 1 else {
            throw DataError.invalid("Keep country geometry ready while complete detail suppresses duplicate overview")
        }
        print("PASS national detail handoff: preserve nationwide routes, clip complete rectangles, retain failed/partial coverage, no gap bridges.")
    }
}
