import Foundation

/// Confidence in a station-complex association. OSM/entity membership alone
/// proves no pedestrian passage; an official record may attest a specific one.
public enum StationInterchangeConfidence: String, Sendable {
    case documented
    case possible
}

/// Reviewed local supplements, independent of OSM tags and relation IDs.
/// Records match exact station IDs only; names, routes and distances never
/// activate them. Passage wording must stay within the cited sources' claims.
public struct StationInterchangeOfficialRecord: Hashable, Sendable {
    public let stationIDs: [String]
    public let officialURL: URL
    public let supportingURLs: [URL]
    public let summary: String
    public let passageNotice: String

    public init(stationIDs: [String], officialURL: URL, supportingURLs: [URL] = [],
                summary: String, passageNotice: String) {
        self.stationIDs = stationIDs
        self.officialURL = officialURL
        self.supportingURLs = supportingURLs
        self.summary = summary
        self.passageNotice = passageNotice
    }

    public static let bundled: [StationInterchangeOfficialRecord] = [
        StationInterchangeOfficialRecord(
            stationIDs: ["node/6617852357", "node/12435251104"],
            officialURL: URL(string: "https://www.bjsubway.com/station/siteinfo.html?loc=150998319")!,
            supportingURLs: [URL(string: "https://news.qq.com/rain/a/20250211A07WHU00")!],
            summary: "北京地铁官网列出12／13号线及换乘通道设施；北京交通广播2025-02-11援引建管公司确认付费区内换乘。",
            passageNotice: "12号线与13号线可在付费区内换乘。")
    ]
}

public struct StationInterchangeEvidence: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case stopArea, stopAreaGroup, wikidata, wikipedia, official, nameContextNearby
    }
    public let kind: Kind
    /// Relation ID, station entity/article, official summary, or name/context.
    public let value: String
    /// Actual witnesses; an association may use a chain of documented links.
    public let stationIDs: [String]
    public let distanceMeters: Double?
    public let officialRecord: StationInterchangeOfficialRecord?
    public var sourceURL: URL? { officialRecord?.officialURL }
    public var supportingURLs: [URL] { officialRecord?.supportingURLs ?? [] }
    public var confidence: StationInterchangeConfidence {
        kind == .nameContextNearby ? .possible : .documented
    }

    init(kind: Kind, value: String, stationIDs: [String], distanceMeters: Double?,
         officialRecord: StationInterchangeOfficialRecord? = nil) {
        self.kind = kind
        self.value = value
        self.stationIDs = stationIDs
        self.distanceMeters = distanceMeters
        self.officialRecord = officialRecord
    }
}

public struct StationInterchangePeer: Identifiable, Sendable {
    /// An unchanged station value, with its own ID, position and routes.
    public let station: RailStation
    public let confidence: StationInterchangeConfidence
    public let evidence: [StationInterchangeEvidence]
    public var id: String { station.id }
}

/// Inspector-only projection. Never use these routes to recolour physical
/// markers, replace a station's routes, or determine favourite/selection IDs.
public struct StationInterchangeGroup: Sendable {
    public let stationID: String
    public let peers: [StationInterchangePeer]
    /// Union for discovery, including possible peers. Render their uncertainty.
    public let routes: [RailRoute]
    public let documentedRoutes: [RailRoute]
    /// Routes contributed only by possible peers, excluding documented routes.
    public let possibleRoutes: [RailRoute]
    public let evidence: [StationInterchangeEvidence]
    public let confidence: StationInterchangeConfidence
    /// Official passage claims apply only to their exact witnesses. They must
    /// not leak into an unrelated candidate's notice via a neighbouring complex.
    public var passageNotice: String {
        let records = evidence.filter { $0.kind == .official && $0.stationIDs.contains(stationID) }
            .compactMap(\.officialRecord)
        guard !records.isEmpty else { return "换乘通道、站内可达性及开放状态未核实" }
        let covered = Set(records.flatMap(\.stationIDs))
        let notices = Set(records.map(\.passageNotice)).sorted().joined(separator: "\n")
        let otherPeers = peers.contains { $0.confidence == .possible || !covered.contains($0.id) }
        return notices + (otherPeers ? "\n其他关联站点的换乘通道、站内可达性及开放状态未核实" : "")
    }
}

/// Build once from prepared stations, before filtering individual line switches.
/// Lookup is O(1); constructing the index never mutates or merges its input.
/// Possible links are direct neighbours of a documented complex, not transitive.
public struct StationInterchangeIndex: Sendable {
    /// Decoder-generated, semicolon-separated OSM relation IDs.
    public static let stopAreaTag = "atlas:stopAreaIDs"
    public static let stopAreaGroupTag = "atlas:stopAreaGroupIDs"
    /// Set to "no" when an authoritative source explicitly rules out transfer.
    /// Preserve that source separately; this index never invents this marker.
    public static let interchangeProhibitedTag = "atlas:interchange"
    public static let maximumCandidateDistanceMeters = 350.0

    private let groups: [String: StationInterchangeGroup]

    public subscript(stationID: String) -> StationInterchangeGroup? { groups[stationID] }
    public func group(for stationID: String) -> StationInterchangeGroup? { groups[stationID] }

    /// For exact-ID tile assembly only. Returns metadata without modifying
    /// either station, its coordinates or routes. Conflicting entity IDs stay
    /// with the existing object; absent fields may be supplied by a later tile.
    public static func mergedEvidenceTags(existing: RailStation, incoming: RailStation) -> [String: String] {
        var tags = existing.tags
        guard existing.id == incoming.id else { return tags }
        for key in [stopAreaTag, stopAreaGroupTag] {
            let ids = relationIDs(existing.tags[key]).union(relationIDs(incoming.tags[key]))
            if !ids.isEmpty { tags[key] = ids.sorted().joined(separator: ";") }
        }
        for key in ["wikidata", "wikipedia"] where normal(tags[key] ?? "").isEmpty {
            if let value = incoming.tags[key], !normal(value).isEmpty { tags[key] = value }
        }
        // A prohibition found in a later tile must not disappear at assembly.
        for key in exclusionKeys where isNo(incoming.tags[key]) { tags[key] = incoming.tags[key] }
        return tags
    }

    public init(stations input: [RailStation],
                officialRecords: [StationInterchangeOfficialRecord] = StationInterchangeOfficialRecord.bundled) {
        let stations = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            .values.sorted { $0.id < $1.id }
        let positions = Dictionary(uniqueKeysWithValues: stations.enumerated().map { ($0.element.id, $0.offset) })
        var parent = Array(stations.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var sources: [Source: [Int]] = [:]
        for (index, station) in stations.enumerated() {
            for source in Self.documentedSources(station) { sources[source, default: []].append(index) }
        }
        var documented: [StationInterchangeEvidence] = []
        for (source, members) in sources where members.count > 1 {
            for member in members.dropFirst() {
                let a = root(members[0]), b = root(member)
                parent[max(a, b)] = min(a, b)
            }
            documented.append(StationInterchangeEvidence(kind: source.kind, value: source.value,
                stationIDs: members.map { stations[$0].id }, distanceMeters: nil))
        }
        for record in officialRecords {
            let members = Set(record.stationIDs).sorted().compactMap { positions[$0] }
                .filter { !Self.excludesInterchange(stations[$0]) }
            guard members.count > 1 else { continue } // Never fabricate an absent peer.
            for member in members.dropFirst() {
                let a = root(members[0]), b = root(member)
                parent[max(a, b)] = min(a, b)
            }
            documented.append(StationInterchangeEvidence(kind: .official, value: record.summary,
                stationIDs: members.map { stations[$0].id }, distanceMeters: nil, officialRecord: record))
        }
        let roots = stations.indices.map { root($0) }
        let components = Dictionary(grouping: stations.indices, by: { roots[$0] })
        var componentEvidence: [Int: [StationInterchangeEvidence]] = [:]
        for evidence in documented {
            if let id = evidence.stationIDs.first, let index = positions[id] {
                componentEvidence[roots[index], default: []].append(evidence)
            }
        }
        let contexts = stations.map(Self.context)
        var byName: [String: [Int]] = [:]
        for (index, station) in stations.enumerated() {
            for name in Self.names(station) { byName[name, default: []].append(index) }
        }
        var examined = Set<Pair>()
        var candidates: [Int: [Int: [StationInterchangeEvidence]]] = [:]
        for (name, members) in byName.sorted(by: { $0.key < $1.key }) where members.count > 1 {
            for (offset, a) in members.enumerated() {
                for b in members.dropFirst(offset + 1) {
                    guard roots[a] != roots[b], examined.insert(Pair(a: a, b: b)).inserted,
                          let common = Self.commonContext(contexts[a], contexts[b]),
                          !contexts[a].routes.subtracting(contexts[b].routes).isEmpty,
                          !contexts[b].routes.subtracting(contexts[a].routes).isEmpty,
                          stations[a].coordinate.isValid, stations[b].coordinate.isValid else { continue }
                    let distance = MapAlignment.distance(stations[a].coordinate, stations[b].coordinate)
                    guard distance <= Self.maximumCandidateDistanceMeters else { continue }
                    let evidence = StationInterchangeEvidence(kind: .nameContextNearby,
                        value: "\(name) · \(common)", stationIDs: [stations[a].id, stations[b].id],
                        distanceMeters: distance)
                    candidates[roots[a], default: [:]][roots[b], default: []].append(evidence)
                    candidates[roots[b], default: [:]][roots[a], default: []].append(evidence)
                }
            }
        }
        var result: [String: StationInterchangeGroup] = [:]
        for (component, members) in components {
            let neighbours = candidates[component] ?? [:]
            guard members.count > 1 || !neighbours.isEmpty else { continue }
            let ownEvidence = Self.ordered(componentEvidence[component] ?? [])
            let ownRoutes = Self.routes(members.map { stations[$0] })
            let ownKeys = Set(ownRoutes.map(\.visibilityKey))
            var possible: [StationInterchangePeer] = []
            for (neighbour, evidence) in neighbours.sorted(by: { $0.key < $1.key }) {
                let proof = Self.ordered(ownEvidence + evidence + (componentEvidence[neighbour] ?? []))
                for index in components[neighbour] ?? [] {
                    possible.append(StationInterchangePeer(station: stations[index], confidence: .possible, evidence: proof))
                }
            }
            let possibleRoutes = Self.routes(possible.map(\.station)).filter { !ownKeys.contains($0.visibilityKey) }
            let routes = (ownRoutes + possibleRoutes).sorted { $0.visibilityKey < $1.visibilityKey }
            let evidence = Self.ordered(ownEvidence + possible.flatMap(\.evidence))
            for index in members {
                let peers = members.filter { $0 != index }.map {
                    StationInterchangePeer(station: stations[$0], confidence: .documented, evidence: ownEvidence)
                } + possible
                result[stations[index].id] = StationInterchangeGroup(stationID: stations[index].id,
                    peers: peers.sorted { $0.id < $1.id }, routes: routes, documentedRoutes: ownRoutes,
                    possibleRoutes: possibleRoutes, evidence: evidence,
                    confidence: possible.isEmpty ? .documented : .possible)
            }
        }
        groups = result
    }

    private struct Source: Hashable {
        let kind: StationInterchangeEvidence.Kind
        let value: String
    }
    private struct Pair: Hashable { let a: Int; let b: Int }
    private struct Context {
        let cities: Set<String>
        let namedCities: Set<String>
        let networks: Set<String>
        let routes: Set<String>
    }

    private static func documentedSources(_ station: RailStation) -> Set<Source> {
        guard !excludesInterchange(station) else { return [] }
        var result = Set<Source>()
        for (tag, kind) in [(stopAreaTag, StationInterchangeEvidence.Kind.stopArea), (stopAreaGroupTag, .stopAreaGroup)] {
            for id in relationIDs(station.tags[tag]) { result.insert(Source(kind: kind, value: id)) }
        }
        // Only the station's own identifiers, never route/network/operator IDs.
        if let id = station.tags["wikidata"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           id.range(of: #"^Q[1-9][0-9]*$"#, options: .regularExpression) != nil {
            result.insert(Source(kind: .wikidata, value: id))
        }
        if let article = station.tags["wikipedia"], let key = wikipedia(article) {
            result.insert(Source(kind: .wikipedia, value: key))
        }
        return result
    }

    private static func relationIDs(_ value: String?) -> Set<String> {
        Set((value ?? "").split(separator: ";").compactMap {
            let id = String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            return id.range(of: #"^relation/[1-9][0-9]*$"#, options: .regularExpression) == nil ? nil : id
        })
    }

    private static func wikipedia(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty,
              parts[0].range(of: #"^[a-zA-Z][a-zA-Z-]{1,15}$"#, options: .regularExpression) != nil else { return nil }
        // Language and title both matter; unrelated translations are not guessed.
        let title = String(parts[1]).replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return title.isEmpty ? nil : parts[0].lowercased() + ":" + title
    }

    private static func context(_ station: RailStation) -> Context {
        let fields = [station.tags] + (station.routes ?? []).map(\.tags)
        var cities = Set<String>(), namedCities = Set<String>(), networks = Set<String>()
        for tags in fields {
            if let city = tags["atlas:paletteCity"], !normal(city).isEmpty { cities.insert(normal(city)) }
            if let identity = tags["atlas:paletteIdentity"] {
                let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 3, parts[0] == "metro", !parts[1].isEmpty, !parts[2].isEmpty {
                    cities.insert(normal(String(parts[1])))
                }
            }
            for (key, value) in tags where key == "network" || key.hasPrefix("network:") {
                let value = normal(value)
                if !value.isEmpty { networks.insert("\(key == "network:wikidata" || key == "network:wikipedia" ? key : "network")=\(value)") }
            }
        }
        for key in ["addr:city", "is_in:city"] {
            if let city = station.tags[key], !normal(city).isEmpty { namedCities.insert(normal(city)) }
        }
        return Context(cities: cities, namedCities: namedCities, networks: networks,
                       routes: Set((station.routes ?? []).map(\.visibilityKey)))
    }

    private static func commonContext(_ a: Context, _ b: Context) -> String? {
        // An explicit city disagreement vetoes a shared network/operator name.
        if !a.cities.isEmpty, !b.cities.isEmpty, a.cities.isDisjoint(with: b.cities) { return nil }
        if !a.namedCities.isEmpty, !b.namedCities.isEmpty, a.namedCities.isDisjoint(with: b.namedCities) { return nil }
        if let city = a.cities.intersection(b.cities).sorted().first { return "city=\(city)" }
        if let city = a.namedCities.intersection(b.namedCities).sorted().first { return "city=\(city)" }
        return a.networks.intersection(b.networks).sorted().first
    }

    private static func names(_ station: RailStation) -> Set<String> {
        guard !excludesInterchange(station) else { return [] }
        let values = [station.name] + station.tags.filter { $0.key == "name" || $0.key.hasPrefix("name:") }.map(\.value)
        let unknowns: Set<String> = ["", "未命名车站", "未命名", "unnamed", "unknown", "station"]
        return Set(values.map(normal)).subtracting(unknowns)
    }

    private static let exclusionKeys = [
        "interchange", "transfer", "public_transport:interchange", "railway:interchange", interchangeProhibitedTag
    ]
    private static func isNo(_ value: String?) -> Bool {
        ["no", "false", "0"].contains(normal(value ?? ""))
    }
    private static func excludesInterchange(_ station: RailStation) -> Bool {
        exclusionKeys.contains { isNo(station.tags[$0]) }
    }

    private static func normal(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .precomposedStringWithCanonicalMapping
    }

    private static func routes(_ stations: [RailStation]) -> [RailRoute] {
        var result: [String: RailRoute] = [:]
        for route in stations.flatMap({ $0.routes ?? [] }).sorted(by: { $0.id < $1.id }) {
            if result[route.visibilityKey] == nil
                || (result[route.visibilityKey]?.color == nil && route.color != nil) {
                result[route.visibilityKey] = route
            }
        }
        return result.values.sorted { $0.visibilityKey < $1.visibilityKey }
    }

    private static func ordered(_ evidence: [StationInterchangeEvidence]) -> [StationInterchangeEvidence] {
        Array(Set(evidence)).sorted {
            let a = "\($0.kind.rawValue)|\($0.value)|\($0.stationIDs.joined(separator: ";"))"
            let b = "\($1.kind.rawValue)|\($1.value)|\($1.stationIDs.joined(separator: ";"))"
            return a < b
        }
    }
}
