#if os(macOS)
import AppKit
import CoreText
import RailwayCore
import SwiftUI

@MainActor
enum ExperienceValidation {
    static let flag = "--experiences-check"
    static func run(directory: URL) async throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw DataError.invalid("Experience UI: \(message)") }
        }
        let modelDirectory = directory.appendingPathComponent("catalog-ui")
        if let flag = CommandLine.arguments.firstIndex(of: "--llt-fixture"), CommandLine.arguments.count > flag + 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            let snapshot = try LuluTimetableSnapshot.read(data)
            let expected = try RailExperienceCatalog.timetables()[0]
            let actual = try snapshot.services.first { $0.train == "G6580" }!
                .timetable(on: expected.serviceDate, edition: snapshot.edition)
            try require(actual.stops.map(\.station) == expected.stops.map(\.station), "LLT station IDs mismatch")
            for i in expected.stops.indices {
                try require(actual.stops[i].arrival == expected.stops[i].arrival, "LLT arrival mismatch")
                if i < expected.stops.count - 1 {
                    try require(actual.stops[i].departure == expected.stops[i].departure, "LLT dwell mismatch")
                }
            }
            let libraryDirectory = modelDirectory.appendingPathComponent("TimetableLibrary")
            try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            try data.write(to: libraryDirectory.appendingPathComponent("lulutong.json"), options: .atomic)
        }
        let model = ExperienceStore(directory: modelDirectory)
        await model.load()
        if CommandLine.arguments.contains("--journey-routing-check") {
            try await JourneyRoutingValidation.run(model: model, directory: directory)
            return
        }
        try require(model.error == nil && model.cities.count >= 70 && model.historyRegions.count >= 4, "expanded catalog loading")
        try require(model.round?.choices.count == 4, "quiz choices")
        let firstID = model.round!.id
        model.answer(model.round!.answer)
        model.answer(model.round!.answer)
        try require(model.correctAnswers == 1 && model.roundsAnswered == 1, "double-counted quiz answer")
        model.nextRound()
        try require(model.round?.id != firstID && model.guessed == nil, "quiz did not reset")
        let passportDirectory = directory.appendingPathComponent("passport-test")
        let passport = JourneyStore(directory: passportDirectory)
        try require(passport.journeys.isEmpty, "new passport invented personal history")
        let record = RailJourney(date: "2026-11-08", train: "G6580", from: "香港西九龙", to: "肇庆东",
                                 departure: "16:04", source: "QA 合成记录")
        try require(passport.save(record), "passport save")
        try require(passport.travelled.isEmpty && passport.pendingCount == 1, "unreviewed ticket counted as travel")
        var confirmed = record; confirmed.status = .travelled
        try require(passport.save(confirmed), "passport review")
        let loaded = JourneyStore(directory: passportDirectory)
        try require(loaded.journeys == [confirmed] && loaded.visitedStations == 2, "passport reload")
        loaded.remove(confirmed)
        try require(loaded.journeys.isEmpty, "passport delete")
        loaded.undoRemoval()
        try require(loaded.journeys == [confirmed], "passport undo")
        try require(FileManager.default.fileExists(atPath: passportDirectory.appendingPathComponent("journeys-previous.json").path),
                    "previous archive missing")
        let brokenDirectory = directory.appendingPathComponent("corrupt-passport-test")
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        let brokenFile = brokenDirectory.appendingPathComponent("journeys-v1.json")
        let broken = Data("not a passport".utf8)
        try broken.write(to: brokenFile)
        let locked = JourneyStore(directory: brokenDirectory)
        try require(locked.readOnly && !locked.save(record), "corrupt archive overwritten")
        let after = try Data(contentsOf: brokenFile)
        try require(after == broken, "corrupt file bytes changed")
        var custom = model.timetables[0]
        custom.id = "qa-imported-timetable"
        let catalogTest = ExperienceStore(directory: directory.appendingPathComponent("catalog-test"))
        await catalogTest.load()
        try catalogTest.addTimetables([custom])
        var history = model.history[0]; history.id = "qa-imported-history"
        try catalogTest.addHistory([history])
        let reloaded = ExperienceStore(directory: directory.appendingPathComponent("catalog-test"))
        await reloaded.load()
        try require(reloaded.timetables.contains { $0.id == custom.id }
                    && reloaded.history.contains { $0.id == history.id }, "custom catalog did not persist")
        var report = [
            "PASS bundled catalog, \(model.cities.count)-city sanitized drawing boundary, answer locking and next-round state.",
            "PASS isolated passport starts empty; tentative entries excluded from travel stats; review, atomic persistence, reload, delete/undo and previous-file backup.",
            "PASS corrupt passport remains read-only and byte-identical.",
            "PASS imported dated timetables and historical event packs survive restart in isolated storage."
        ]
        let map = RailwayMapStore()
        map.mapMode = .offline
        map.statusVisible = false
        let configuration = ConfigurationStore(
            url: directory.appendingPathComponent("experience-config.json")
        )

        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1080, height: 830),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "铁道漫游 · 界面验证"
        let host = NSHostingView(rootView: ExperienceRootView(model: model, passport: passport, map: map))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for tab in ExperienceTab.allCases {
            model.tab = tab
            if tab == .postcard { model.makePostcard(confirmed) }
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            _ = try await OnlineUIValidation.capture("experience-\(tab.rawValue)", directory: directory, window: window)
        }
        model.tab = .guess
        model.answer(model.round!.answer)
        try await Task.sleep(for: .milliseconds(200))
        _ = try await OnlineUIValidation.capture("experience-guess-reveal", directory: directory, window: window)
        window.appearance = NSAppearance(named: .darkAqua)
        model.tab = .passport
        try await Task.sleep(for: .milliseconds(200))
        _ = try await OnlineUIValidation.capture("experience-passport-dark", directory: directory, window: window)
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 940, height: 680))
        model.tab = .postcard
        try require(model.postcardDraft == confirmed, "switching tabs discarded the postcard draft")
        try await Task.sleep(for: .milliseconds(200))
        _ = try await OnlineUIValidation.capture("experience-postcard-narrow", directory: directory, window: window)
        report.append("CAPTURED five native pages, revealed answer, dark passport and minimum window size; inspect PNGs before acceptance.")
        let review = JourneyImportBatch(journeys: [confirmed, confirmed, RailJourney(from: "北京南", to: "天津")],
                                        notes: ["QA：重复文件及缺失日期的候选记录"])
        window.setContentSize(NSSize(width: 660, height: 660))
        window.contentView = NSHostingView(rootView: JourneyImportReviewView(batch: review).environmentObject(passport))
        try await Task.sleep(for: .milliseconds(200))
        _ = try await OnlineUIValidation.capture("experience-import-review", directory: directory, window: window)

        let legs = try model.trackJourneys[0].slice(from: confirmed.from, to: confirmed.to).legs
        for style in PostcardStyle.allCases {
            let renderer = ImageRenderer(content: TicketPostcardArt(style: style, journey: confirmed,
                caption: "山川迢迢，来日方长。", legs: legs)
                .environment(\.colorScheme, .light))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw DataError.invalid("Ticket image export failed")
            }
            try require(image.width == 1520 && image.height == 880, "wrong postcard output dimensions")
            try png.write(to: directory.appendingPathComponent("postcard-\(style.rawValue).png"))
        }
        for name in ["STSongti-SC-Bold", "STHeitiSC-Medium", "Menlo-Regular"] {
            let actual = CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 24, nil)) as String
            try require(actual == name, "ticket font missing: \(name)")
        }
        report.append("PASS red/blue/map PNG rendering at 1520x880 and actual Songti, Heiti, Menlo font resolution.")

        let ocr = ImageRenderer(content: VStack(alignment: .leading, spacing: 20) {
            Text("2026年11月8日 16:04").font(.system(size: 32))
            Text("G6580次 香港西九龙→肇庆东").font(.system(size: 32))
        }.padding(40).foregroundStyle(.black).background(.white))
        ocr.scale = 2
        guard let image = ocr.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw DataError.invalid("OCR fixture render failed")
        }
        let ocrURL = directory.appendingPathComponent("ocr-fixture.png")
        try png.write(to: ocrURL)
        let imported = await JourneyDocumentImport.read([ocrURL])
        try require(imported.notes.isEmpty && imported.journeys.count == 1
                    && imported.journeys[0].date == "2026-11-08" && imported.journeys[0].train == "G6580",
                    "local OCR failed to extract rendered test date/train")
        try require(imported.journeys[0].status == .needsReview, "OCR falsely confirmed travel")
        report.append("PASS on-device Vision OCR of a synthetic ticket-like image yields tentative date and train; real ticket layouts still require review.")

        // Exercise the same main-map control and both production renderers.
        window.setContentSize(NSSize(width: 1120, height: 820))
        let route = model.trackJourneys[0], timetable = model.timetables[0]
        try map.journeyPlayer.start(timetable, route: route)
        map.journeyPlayer.pause()
        map.journeyPlayer.seek(970 * 60)
        let movingPoint = map.experienceMarker
        map.journeyPlayer.seek(975 * 60)
        try require(map.experienceMarker != movingPoint, "train did not follow track")
        map.journeyPlayer.seek(978 * 60)
        let stopPoint = map.experienceMarker
        map.journeyPlayer.seek(979 * 60)
        try require(map.experienceMarker == stopPoint, "map train moved during dwell")
        try require(map.journeyPlayer.runDetails.contains("模拟 0 km/h") &&
                    map.journeyPlayer.runDetails.contains("本站还停"), "dwell speed or departure countdown")
        map.journeyPlayer.seek(Double(timetable.end * 60))
        try require(map.journeyPlayer.trainStatus.contains("已抵达") &&
                    map.journeyPlayer.runDetails.contains(String(format: "已行 %.1f km", route.distance / 1000)),
                    "terminal distance must equal the track geometry")
        map.journeyPlayer.seek(979 * 60)
        let futian = Coordinate(22.54157405277572, 114.05130386352539)
        try require(stopPoint.map { RailTrackJourney.metres($0, futian) < 80 } ?? false,
                    "Futian dwell marker is not at the station")
        window.contentView = NSHostingView(rootView: MapScreen()
            .environmentObject(map).environmentObject(AssistantStore())
            .environmentObject(Connectivity()).environmentObject(configuration))
        try await Task.sleep(for: .milliseconds(300))
        try require(map.experienceMarker == stopPoint && map.journeyPlayer.seconds == 979 * 60,
                    "paused train changed after rendering")
        _ = try await OnlineUIValidation.capture("main-map-train-dwell", directory: directory, window: window)
        window.contentView = NSHostingView(rootView: ZStack(alignment: .bottom) {
            AppleRailwayMap(store: map)
            MapExperienceControls(player: map.journeyPlayer).frame(width: 620).padding(40)
        }.environmentObject(configuration))
        try await Task.sleep(for: .milliseconds(700))
        try require(map.experienceMarker == stopPoint, "Apple renderer changed the marker")
        report.append("POSITION Futian WGS84: \(map.experienceMarker!); displayed: \(map.alignment.display(map.experienceMarker!)); camera: \(map.region.center).")
        _ = try await OnlineUIValidation.capture("apple-map-train", directory: directory, window: window)
        let region = model.historyRegions.first { $0.id == "hongkong" }!
        map.journeyPlayer.start(region)
        try require(map.historyMapActive && map.experienceLines.isEmpty, "initial history frame leaked current tracks")
        window.contentView = NSHostingView(rootView: MapScreen()
            .environmentObject(map).environmentObject(AssistantStore())
            .environmentObject(Connectivity()).environmentObject(configuration))
        map.journeyPlayer.seek(Double(map.journeyPlayer.historyDates.firstIndex { $0 >= "1980-01-01" } ?? 1))
        let earlyCount = map.experienceLines.count
        try await Task.sleep(for: .milliseconds(300))
        _ = try await OnlineUIValidation.capture("main-map-history-early", directory: directory, window: window)
        map.journeyPlayer.seek(Double(map.journeyPlayer.historyDates.count - 1))
        try require(map.experienceLines.count > earlyCount, "history did not grow by segment")
        try await Task.sleep(for: .milliseconds(300))
        _ = try await OnlineUIValidation.capture("main-map-history-recent", directory: directory, window: window)
        map.journeyPlayer.stop()
        try require(!map.historyMapActive && map.experienceLines.isEmpty && map.experienceMarker == nil, "map playback cleanup")
        report.append("PASS main-map track movement, stationary dwell, Apple/offline renderers, initially empty history, cumulative dated geometry and exit cleanup.")

        let library = TimetableLibraryStore(directory: directory.appendingPathComponent("library-test"))
        let validLibrary = TimetableLibraryArchive(version: 1, provider: "QA", edition: "2026-11-08", timetables: [timetable])
        let file = directory.appendingPathComponent("library-test-import.json")
        try JSONEncoder().encode(validLibrary).write(to: file)
        await library.importFile(file)
        try require(library.archive?.timetables.count == 1, "full library import")
        try Data("corrupt".utf8).write(to: file)
        await library.importFile(file)
        try require(library.archive?.timetables.count == 1, "bad import replaced library")
        library.updateURL = "not a URL"
        await library.synchronize()
        try require(library.archive?.timetables.count == 1, "bad update replaced library")
        report.append("PASS shared library import and preservation across malformed imports and invalid update addresses.")
        if CommandLine.arguments.contains("--llt-sync-check") {
            let libraryDirectory = modelDirectory.appendingPathComponent("TimetableLibrary")
            let file = libraryDirectory.appendingPathComponent("lulutong.json")
            let previous = try Data(contentsOf: file)
            let liveLibrary = TimetableLibraryStore(directory: libraryDirectory)
            await liveLibrary.synchronizeLulu()
            try require(liveLibrary.lulu != nil && liveLibrary.message?.contains("已保存到本机") == true,
                        "installed-app LLT synchronization failed: \(liveLibrary.message ?? "no result")")
            let backup = try Data(contentsOf: libraryDirectory.appendingPathComponent("lulutong.previous.json"))
            try require(backup == previous, "LLT update did not preserve the previous complete file")
            let saved = try LuluTimetableSnapshot.read(Data(contentsOf: file))
            try require(saved.services.count == liveLibrary.lulu?.services.count && saved.services.count > 10_000,
                        "LLT synchronized file does not match the complete in-memory library")
            report.append("PASS actual installed-app LLT synchronization through the update-button store: \(saved.services.count) services, \(saved.stationCount) station names, \(saved.stopCount) stops; previous library backed up byte-identically.")
        }
        try Data(report.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("experience-qa.txt"), options: .atomic)
        print(report.joined(separator: "\n"))
    }
}
#endif
