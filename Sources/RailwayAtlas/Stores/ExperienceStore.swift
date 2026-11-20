import Foundation
import RailwayCore
import SwiftUI

@MainActor
final class JourneyStore: ObservableObject {
    @Published private(set) var journeys: [RailJourney] = []
    @Published var error: String?
    @Published private(set) var readOnly = false
    @Published private(set) var deleted: RailJourney?
    let directory: URL
    var file: URL { directory.appendingPathComponent("journeys-v1.json") }

    init(directory: URL? = nil) {
        let args = CommandLine.arguments
        if let directory { self.directory = directory }
        else if let i = args.firstIndex(of: "--ui-smoke"), args.count > i + 1 {
            self.directory = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("passport")
        } else {
            self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RailwayAtlas/Passport", isDirectory: true)
        }
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 10_000_000 else { throw DataError.invalid("护照文件过大") }
                journeys = try RailJourneyArchive.decode(Data(contentsOf: file)).journeys
            } catch {
                readOnly = true
                self.error = "护照暂时只读，原文件已保留：\(error.localizedDescription)"
            }
        }
    }

    var travelled: [RailJourney] { journeys.filter { $0.status == .travelled } }
    var visitedStations: Int { Set(travelled.flatMap { [$0.from, $0.to] }).count }
    var pendingCount: Int { journeys.filter { $0.status == .needsReview }.count }

    @discardableResult
    func save(_ journey: RailJourney) -> Bool {
        if let message = journey.validationMessage { error = message; return false }
        var next = journeys
        if let index = next.firstIndex(where: { $0.id == journey.id }) { next[index] = journey }
        else { next.append(journey) }
        return commit(next)
    }

    @discardableResult
    func importReviewed(_ input: [RailJourney]) -> Bool {
        var ids = Set(journeys.map(\.id))
        let new = input.map { item -> RailJourney in
            var item = item
            if ids.contains(item.id) { item.id = UUID() }
            ids.insert(item.id)
            return item
        }
        return commit(journeys + new)
    }

    func remove(_ item: RailJourney) {
        if commit(journeys.filter { $0.id != item.id }) { deleted = item }
    }
    func undoRemoval() {
        guard let deleted, !journeys.contains(where: { $0.id == deleted.id }) else { return }
        if commit(journeys + [deleted]) { self.deleted = nil }
    }

    private func commit(_ input: [RailJourney]) -> Bool {
        guard !readOnly else { return false }
        do {
            let sorted = input.sorted { ($0.date, $0.departure, $0.train) > ($1.date, $1.departure, $1.train) }
            let data = try RailJourneyArchive(journeys: sorted).encode()
            _ = try RailJourneyArchive.decode(data)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let existing = try Data(contentsOf: file)
                _ = try RailJourneyArchive.decode(existing)
                try existing.write(to: directory.appendingPathComponent("journeys-previous.json"), options: .atomic)
            }
            try data.write(to: file, options: .atomic)
            journeys = sorted; error = nil
            return true
        } catch { self.error = "未保存：\(error.localizedDescription)"; return false }
    }
}

enum ExperienceTab: String, CaseIterable, Identifiable {
    case guess, passport, postcard, history, simulation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .guess: "路网猜城市"
        case .passport: "铁路护照"
        case .postcard: "地图明信片"
        case .history: "铁路时光机"
        case .simulation: "沿线旅行"
        }
    }
    var icon: String {
        switch self {
        case .guess: "point.3.connected.trianglepath.dotted"
        case .passport: "book.closed"
        case .postcard: "ticket"
        case .history: "clock.arrow.circlepath"
        case .simulation: "tram.fill"
        }
    }
    var subtitle: String {
        switch self {
        case .guess: "只凭线形，认出一座城市"
        case .passport: "把散落的车票收成一段旅程"
        case .postcard: "让每次出发，都有一张纪念"
        case .history: "在地图上，看线路随时间逐段生长"
        case .simulation: "按真实时刻表，慢慢走过一程"
        }
    }
}

@MainActor
final class ExperienceStore: ObservableObject {
    struct CityShape: Identifiable {
        var id: String { city }
        let city: String
        let coordinates: [[Coordinate]]
        let sourceDate: String
        var cached = false
        var silhouette: RailSilhouette { RailSilhouette(coordinates: coordinates) }
    }
    struct Round {
        let id = UUID()
        let answer: String
        let choices: [String]
        let silhouette: RailSilhouette
        let sourceDate: String
    }
    @Published var tab: ExperienceTab = .guess
    @Published private(set) var cities: [CityShape] = []
    @Published var round: Round?
    @Published var guessed: String?
    @Published var roundsAnswered = 0
    @Published var correctAnswers = 0
    @Published var rotatesGuess = false
    @Published var error: String?
    @Published var timetables: [RailTimetable] = []
    @Published var history: [RailHistoryEvent] = []
    @Published var postcardDraft = RailJourney()
    @Published var postcardStyle: PostcardStyle = .red
    @Published var postcardCity = "上海"
    @Published var postcardCaption = "山川迢迢，来日方长。"
    @Published var pastedJourneyText = ""
    @Published var includesWorldCache = false { didSet { nextRound() } }
    @Published var quizLoading = false
    @Published var historyRegions: [RailHistoryRegion] = []
    @Published var trackJourneys: [RailTrackJourney] = []
    @Published var selectedTrainID = ""
    let library: TimetableLibraryStore
    lazy var routeRepository = RailJourneyRouteRepository(directory: directory.appendingPathComponent("JourneyRoutes"),
        mapCache: mapCacheDirectory.appendingPathComponent("railways.railcache"))
    weak var map: RailwayMapStore?
    private var loaded = false
    let directory: URL
    private var customTrains: [RailTimetable] = []
    private var customHistory: [RailHistoryEvent] = []
    private var archivesReadOnly = false

    init(directory: URL? = nil) {
        let args = CommandLine.arguments
        if let directory { self.directory = directory }
        else if let i = args.firstIndex(of: "--ui-smoke"), args.count > i + 1 {
            self.directory = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("experiences")
        } else {
            self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RailwayAtlas/Experiences", isDirectory: true)
        }
        library = TimetableLibraryStore(directory: self.directory.appendingPathComponent("TimetableLibrary"))
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            timetables = try RailExperienceCatalog.timetables()
            history = try RailExperienceCatalog.history()
            historyRegions = try RailHistoricalGeometry.bundled()
            trackJourneys = try RailTrackJourney.bundled()
            do {
                if let data = try readArchive("timetables.json", limit: 5_000_000) {
                    let trains = try RailTimetableArchive.decode(data).timetables
                    let bundled = Set(timetables.map(\.id))
                    guard !trains.contains(where: { bundled.contains($0.id) }) else {
                        throw DataError.invalid("保存的车次标识与随附时刻重复")
                    }
                    customTrains = trains; timetables += trains
                }
                if let data = try readArchive("history.json", limit: 2_000_000) {
                    let events = try RailHistoryArchive.decode(data).events
                    let bundled = Set(history.map(\.id))
                    guard !events.contains(where: { bundled.contains($0.id) }) else {
                        throw DataError.invalid("保存的历史节点标识重复")
                    }
                    customHistory = events; history += events
                    history.sort { $0.date < $1.date }
                }
            } catch {
                archivesReadOnly = true
                self.error = "自定义资料暂时只读，原文件已保留：\(error.localizedDescription)"
            }
            let snapshot = try await NationalMetroRepository(directory: mapCacheDirectory.appendingPathComponent("MetroOverview")).load()
            let groups = Dictionary(grouping: snapshot.lines, by: { $0.tags["atlas:overviewCity"] ?? "" })
            cities = groups.keys.filter { !["", "未归档", "氢淞号"].contains($0) }.sorted().compactMap { city in
                let lines = groups[city] ?? []
                let coordinates = lines.filter {
                    !["construction", "proposed", "abandoned", "disused"].contains($0.tags["railway"] ?? "")
                }
                    .map(\.coordinates)
                guard !coordinates.isEmpty else { return nil }
                return CityShape(city: city, coordinates: coordinates, sourceDate: snapshot.sourceDate ?? "日期未注明")
            }
            await refreshCachedCities()
            nextRound()
        } catch { self.error = error.localizedDescription }
    }

    func nextRound() {
        let pool = cities.filter { includesWorldCache || !$0.cached }
        guard pool.count >= 4, let city = pool.filter({ $0.city != round?.answer }).randomElement() else { return }
        let choices = ([city.city] + pool.filter { $0.city != city.city }.shuffled().prefix(3).map(\.city)).shuffled()
        round = Round(answer: city.city, choices: choices,
                      silhouette: RailSilhouette(coordinates: city.coordinates,
                                                rotation: rotatesGuess ? Double.random(in: 0..<2 * .pi) : 0),
                      sourceDate: city.sourceDate)
        guessed = nil
    }
    func answer(_ city: String) {
        guard guessed == nil, let round else { return }
        guessed = city; roundsAnswered += 1
        if city == round.answer { correctAnswers += 1 }
    }
    func makePostcard(_ journey: RailJourney) {
        postcardDraft = journey; tab = .postcard
    }

    var mapCacheDirectory: URL {
        if CommandLine.arguments.contains("--ui-smoke"), let i = CommandLine.arguments.firstIndex(of: "--route-cache-directory"),
           CommandLine.arguments.count > i + 1 { return URL(fileURLWithPath: CommandLine.arguments[i + 1]) }
        if CommandLine.arguments.contains("--ui-smoke") { return directory.appendingPathComponent("empty-map-cache") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RailwayAtlas/Online")
    }
    func refreshCachedCities() async {
        guard !quizLoading else { return }
        quizLoading = true
        defer { quizLoading = false }
        let url = mapCacheDirectory.appendingPathComponent("railways.railcache")
        do {
            let features = try await Task.detached { try RailExperienceCache.read(url) }.value
            var new: [CityShape] = []
            let national = Set(cities.filter { !$0.cached }.map(\.city))
            for city in DiscoveryCatalog.cities where !national.contains(city.name) {
                // Bounded regional slices are explicitly described as cached
                // fragments; no reverse-geocoding or network call during quiz.
                let lines = features.lines.filter { line in
                    line.isUrbanTransit && line.coordinates.allSatisfy {
                        RailTrackJourney.metres($0, city.coordinate) < 45_000
                    }
                }
                guard Set(lines.flatMap { ($0.routes ?? []).map(\.visibilityKey) }).count >= 2,
                      lines.reduce(0, { $0 + $1.coordinates.count }) >= 30 else { continue }
                new.append(CityShape(city: city.name, coordinates: lines.map(\.coordinates),
                                     sourceDate: "缓存片段 · " + (lines.compactMap { $0.tags["atlas:cacheDate"] }.max() ?? "日期未知"),
                                     cached: true))
            }
            cities = cities.filter { !$0.cached } + new
        } catch { self.error = "缓存题库未更新，已保留全国题库：\(error.localizedDescription)" }
    }
    func historyForCurrentMap() async -> RailHistoryRegion? {
        guard let map else { return nil }
        let bounds = map.viewportBounds, url = mapCacheDirectory.appendingPathComponent("railways.railcache")
        do {
            let cached = try await Task.detached { try RailExperienceCache.read(url, bounds: bounds) }.value
            let lines = (cached.lines + map.activeLines).filter {
                $0.tags["atlas:nationalOverview"] != "yes"
                    && $0.coordinates.contains(where: bounds.contains)
            }
            var seen = Set<String>()
            let segments = lines.compactMap { line -> RailDatedSegment? in
                let id = line.tags["atlas:osm"] ?? line.id
                guard id.hasPrefix("way/"), seen.insert(id).inserted else { return nil }
                return RailDatedSegment.from(line)
            }
            guard segments.contains(where: { $0.opened != nil }) else {
                error = "当前范围暂无带区段开通日期的缓存。可先选择已提供日期的地区。"
                return nil
            }
            let region = RailHistoryRegion(id: "current-viewport", title: "当前地图区域", segments: segments)
            historyRegions.removeAll { $0.id == region.id }; historyRegions.append(region)
            return region
        } catch { self.error = error.localizedDescription; return nil }
    }

    func addTimetables(_ items: [RailTimetable]) throws {
        guard !archivesReadOnly else { throw DataError.invalid("资料文件只读，请先检查原文件") }
        let existing = Set(timetables.map(\.id))
        guard items.allSatisfy({ !existing.contains($0.id) }) else { throw DataError.invalid("车次快照标识重复；请使用新的标识") }
        let all = customTrains + items
        let data = try JSONEncoder().encode(RailTimetableArchive(timetables: all))
        _ = try RailTimetableArchive.decode(data)
        try saveArchive(data, name: "timetables.json")
        customTrains = all; timetables += items
    }

    func addHistory(_ items: [RailHistoryEvent]) throws {
        guard !archivesReadOnly else { throw DataError.invalid("资料文件只读，请先检查原文件") }
        let existing = Set(history.map(\.id))
        guard items.allSatisfy({ !existing.contains($0.id) }) else { throw DataError.invalid("历史节点标识重复；请使用新的标识") }
        let all = customHistory + items
        let data = try JSONEncoder().encode(RailHistoryArchive(events: all))
        _ = try RailHistoryArchive.decode(data)
        try saveArchive(data, name: "history.json")
        customHistory = all; history += items
        history.sort { $0.date < $1.date }
    }
    private func readArchive(_ name: String, limit: Int) throws -> Data? {
        let file = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else {
            throw DataError.invalid("自定义资料文件过大")
        }
        return try Data(contentsOf: file)
    }
    private func saveArchive(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            try Data(contentsOf: file).write(to: directory.appendingPathComponent(name + ".previous"), options: .atomic)
        }
        try data.write(to: file, options: .atomic)
    }
}
