import Foundation
import JavaScriptCore
import CryptoKit
import RailwayCore

// Both clients read Web/data/metro. A relation identifies one direction.
struct MetroDirection: Decodable, Identifiable, Sendable {
    struct Stop: Decodable, Sendable {
        let id, name, role: String
        let coordinate: [Double]
        var location: Coordinate? { MetroDirection.point(coordinate) }
    }
    let id, name, ref, color, type, from, to, network: String
    let stopCoverage, stopNote, stopSource: String?
    let parts: [[[Double]]]
    let stops: [Stop]
    var paths: [[Coordinate]] { parts.map { $0.compactMap(Self.point) }.filter { $0.count >= 2 } }
    static func point(_ pair: [Double]) -> Coordinate? {
        guard pair.count == 2 else { return nil }
        let value = Coordinate(pair[1], pair[0])
        return value.isValid ? value : nil
    }
    var route: RailRoute {
        RailRoute(id: id, name: name, tags: ["route":type, "colour":color, "ref":ref, "network":network,
                                           "from":from, "to":to], colourSourceID: id)
    }
}

struct MetroCitySpec: Decodable, Identifiable, Sendable {
    let id, name: String
    let bounds: [Double]
    let data, country: String?
    var area: MapBounds { MapBounds(south: bounds[0], west: bounds[1], north: bounds[2], east: bounds[3]) }
    static let directory: [Self] = {
        struct Index: Decodable { let cities: [MetroCitySpec] }
        guard let url = Bundle.main.url(forResource: "metro-index", withExtension: "json"),
              let data = try? Data(contentsOf:url), let items = try? JSONDecoder().decode(Index.self, from:data) else { return [] }
        return items.cities.filter { $0.bounds.count == 4 && $0.area.isValid }
    }()
    static func at(_ point: Coordinate) -> Self {
        let matches = directory.filter { $0.area.contains(point) }
        if let city = matches.min(by:{ MapAlignment.distance($0.area.center,point) < MapAlignment.distance($1.area.center,point) }) { return city }
        let y=Int(floor(point.latitude*4)), x=Int(floor(point.longitude*4))
        return Self(id:"area-\(y)_\(x)",name:String(format:"地图区域 %.2f°, %.2f°", (Double(y)+0.5)/4, (Double(x)+0.5)/4),
                    bounds:[Double(y)/4,Double(x)/4,Double(y+1)/4,Double(x+1)/4],data:nil,country:nil)
    }
}

struct MetroDirectionCatalog {
    struct City: Decodable, Sendable {
        let id, name, sourceDate: String
        let routes: [MetroDirection]
    }
    struct Entry {
        let city, date: String
        let direction: MetroDirection
    }
    private(set) var entries = [String:Entry]()
    private(set) var byStop = [String:[MetroDirection]]()
    private var recent = [City]()
    mutating func accept(_ new: City) {
        recent.removeAll { $0.id == new.id }
        recent.append(new)
        if recent.count > 5 { recent.removeFirst() }
        entries.removeAll(keepingCapacity:true)
        byStop.removeAll(keepingCapacity:true)
        for city in recent {
            for route in city.routes {
                if let known = entries[route.id], known.direction.stops.count > route.stops.count { continue }
                entries[route.id] = Entry(city: city.name, date: city.sourceDate, direction: route)
            }
        }
        for entry in entries.values.sorted(by: { $0.direction.id < $1.direction.id }) {
            for id in Set(entry.direction.stops.map(\.id)) { byStop[id, default: []].append(entry.direction) }
        }
    }
    func reverse(of entry: Entry) -> MetroDirection? {
        let route = entry.direction
        guard !route.from.isEmpty, !route.to.isEmpty, route.from != route.to else { return nil }
        let matches = entries.values.filter {
            let other = $0.direction
            return $0.city == entry.city && other.network == route.network && other.type == route.type
                && other.ref == route.ref && other.from == route.to && other.to == route.from
        }
        return matches.count == 1 ? matches[0].direction : nil
    }
}

actor MetroCityReader {
    private let cache: URL
    private struct Feed: Decodable, Sendable {
        struct Entry: Decodable, Sendable { let hash, sourceDate: String; let bytes: Int }
        let version: Int
        let cities: [String:Entry]
    }
    private let feedURL = URL(string:"https://wongary.github.io/railway-atlas/data/city-packs/")!
    private var feed: Feed?
    private var checkAfter = Date.distantPast
    private var checking: Task<Feed?, Never>?
    private var updating = Set<String>()

    private func feedEntry(_ id: String) async -> Feed.Entry? {
        if checkAfter > Date() { return feed?.cities[id] }
        if let checking { return await checking.value?.cities[id] }
        let url=feedURL.appendingPathComponent("manifest.json")
        let task=Task<Feed?, Never> {
            do {
                var request=URLRequest(url:url,cachePolicy:.reloadRevalidatingCacheData,timeoutInterval:3.5)
                request.httpShouldHandleCookies=false
                let (data,response)=try await URLSession.shared.data(for:request)
                guard (response as? HTTPURLResponse)?.statusCode==200, data.count<=1_000_000 else {return nil}
                let value=try JSONDecoder().decode(Feed.self,from:data)
                return value.version==1 ? value : nil
            } catch { return nil }
        }
        checking=task
        let value=await task.value
        checking=nil
        if let value { feed=value }
        checkAfter=Date().addingTimeInterval(value == nil ? 60 : 21600)
        return feed?.cities[id]
    }

    private func published(_ spec: MetroCitySpec, disk: URL, current: Data?,
                           stored: MetroDirectionCatalog.City?) async -> MetroDirectionCatalog.City? {
        guard let entry=await feedEntry(spec.id),
              entry.hash.count==64, entry.hash.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
              (1...32_000_000).contains(entry.bytes) else {return nil}
        func hash(_ data: Data) -> String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
        if let stored, stored.sourceDate>entry.sourceDate || (current?.count == entry.bytes && current.map(hash) == entry.hash) {return stored}
        do {
            var request=URLRequest(url:feedURL.appendingPathComponent(entry.hash+".json"),timeoutInterval:10)
            request.httpShouldHandleCookies=false
            let (bytes,response)=try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode==200, bytes.count==entry.bytes, hash(bytes)==entry.hash else {return nil}
            let city=try JSONDecoder().decode(MetroDirectionCatalog.City.self,from:bytes)
            guard city.id==spec.id, city.sourceDate==entry.sourceDate else {return nil}
            try Task.checkCancellation()
            try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            try? bytes.write(to:disk,options:.atomic)
            return city
        } catch {return nil}
    }
    init() {
        if let i=CommandLine.arguments.firstIndex(of:"--ui-smoke"), CommandLine.arguments.indices.contains(i+1) {
            cache=URL(fileURLWithPath:CommandLine.arguments[i+1]).appendingPathComponent("city-cache")
        } else {
            cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("RailwayAtlas/CityDirections-v1")
        }
    }
    func load(_ spec: MetroCitySpec, online: Bool, refresh: Bool) async throws -> MetroDirectionCatalog.City {
        let decoder=JSONDecoder()
        func decode(_ bytes: Data) throws -> MetroDirectionCatalog.City {
            let city=try decoder.decode(MetroDirectionCatalog.City.self,from:bytes)
            guard city.id==spec.id else { throw DataError.invalid("城市编号不符") }
            return city
        }
        let disk=cache.appendingPathComponent(spec.id+".json")
        let packaged = spec.data == nil ? nil : Bundle.main.url(forResource:spec.id,withExtension:"json",subdirectory:"metro")
        if let packaged { return try decode(Data(contentsOf:packaged)) }
        let current=try? Data(contentsOf:disk)
        let stored=current.flatMap { try? decode($0) }
        if let stored, !online {return stored}
        if let stored, !refresh && ((try? disk.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)?.timeIntervalSinceNow ?? -.infinity) > (stored.routes.isEmpty ? -86400 : -604800) {
            if updating.insert(spec.id).inserted {
                Task {
                    _ = await published(spec,disk:disk,current:current,stored:stored)
                    updating.remove(spec.id)
                }
            }
            return stored
        }
        guard online else { throw DataError.invalid("本设备还没有这个城市的离线资料") }
        if let shared=await published(spec,disk:disk,current:current,stored:stored) {return shared}
        guard let script=Bundle.main.url(forResource:"metro-source",withExtension:"js"),
              let ctx=JSContext() else { throw DataError.invalid("缺少城轨查询组件") }
        ctx.evaluateScript(try String(contentsOf:script,encoding:.utf8))
        let parser=ctx.objectForKeyedSubscript("MetroSource")
        guard let query=parser?.invokeMethod("query",withArguments:[spec.bounds])?.toString(),
              let sources=parser?.invokeMethod("endpoints",withArguments:[spec.bounds])?.toArray() as? [String] else { throw DataError.invalid("查询范围无效") }
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for source in sources {
            try Task.checkCancellation()
            do {
                var url=URLComponents(string:source)!
                url.queryItems=[URLQueryItem(name:"data",value:query)]
                var request=URLRequest(url:url.url!);request.timeoutInterval=45
                let (data,response)=try await URLSession.shared.data(for:request)
                guard let http=response as? HTTPURLResponse, http.statusCode==200, data.count<48_000_000 else {throw URLError(.badServerResponse)}
                let raw=try JSONSerialization.jsonObject(with:data)
                let meta: [String:Any]=["id":spec.id,"name":spec.name,"bounds":spec.bounds]
                ctx.exception=nil
                guard let obj=parser?.invokeMethod("convert",withArguments:[meta,raw])?.toDictionary(),ctx.exception==nil else {throw URLError(.cannotParseResponse)}
                let bytes=try JSONSerialization.data(withJSONObject:obj)
                let city=try decode(bytes)
                try Task.checkCancellation()
                try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
                try? bytes.write(to:disk,options:.atomic)
                return city
            } catch {lastError=error}
        }
        if let stored {return stored}
        throw lastError
    }
}
