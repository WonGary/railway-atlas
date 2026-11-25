#if os(macOS)
import AppKit
import RailwayCore
import SwiftUI

@MainActor
enum JourneyRoutingValidation {
    static func run(model: ExperienceStore, directory: URL) async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw DataError.invalid("Journey UI: " + message) }
        }
        guard let library = model.library.lulu, library.routing != nil,
              let service = library.services.first(where: { $0.train == "G6580" }) else {
            throw DataError.invalid("Pass a verified --llt-fixture with routing")
        }
        let timetable = try library.timetable(service, on: "2026-11-09")
        let route = try await model.prepareRoute(timetable, allowNetwork: false)
        try route.validate(for: timetable)
        var journey = timetable.draftJourney
        journey.from = "深圳北"; journey.to = "佛山西"; journey.updateBoardingTime()
        try require(journey.departure == "16:31", "boarding time remains origin departure")
        let passenger = try await model.passengerRoute(journey, allowNetwork: false)
        try require(passenger.legs == Array(route.legs[2..<6]), "passport did not crop the selected train")
        try require(passenger.stations.first == journey.from && passenger.stations.last == journey.to, "wrong ticket endpoints")
        let passport = JourneyStore(directory: directory.appendingPathComponent("route-passport"))
        try require(passport.save(journey), "save selected service provenance")
        let reloaded = JourneyStore(directory: passport.directory)
        try require(reloaded.journeys.first?.timetable == timetable, "route snapshot lost after passport reload")

        let importDirectory = directory.appendingPathComponent("route-library-import")
        let store = TimetableLibraryStore(directory: importDirectory)
        let file = directory.appendingPathComponent("route-library.json")
        var legacy = library; legacy.routing = nil
        let previous = try JSONEncoder().encode(legacy)
        try previous.write(to: file); await store.importFile(file)
        try require(store.lulu?.routing == nil && store.lulu?.services.count == library.services.count, "legacy library import")
        try JSONEncoder().encode(library).write(to: file); await store.importFile(file)
        try require(store.lulu?.routing?.routes.count == library.routing?.routes.count, "routing library import")
        let backup = try Data(contentsOf: importDirectory.appendingPathComponent("lulutong.previous.json"))
        let backedUp = try LuluTimetableSnapshot.read(backup)
        try require(backedUp.routing == nil, "previous library was not retained")
        try Data("broken".utf8).write(to: file); await store.importFile(file)
        try require(store.lulu?.routing?.routes.count == library.routing?.routes.count, "bad import replaced route library")

        let map = RailwayMapStore(); map.mapMode = .offline; map.statusVisible = false
        model.map = map; model.timetables.append(timetable); model.selectedTrainID = timetable.id
        try map.journeyPlayer.start(timetable, route: route); map.journeyPlayer.pause()
        map.journeyPlayer.seek(988 * 60); let stopped = map.experienceMarker
        map.journeyPlayer.seek(990 * 60)
        try require(map.experienceMarker == stopped, "imported train moved during station dwell")
        map.journeyPlayer.seek(994 * 60); let moving = map.experienceMarker
        map.journeyPlayer.seek(996 * 60)
        try require(map.experienceMarker != moving, "imported train did not move on main-map track")
        map.journeyPlayer.pause()

        let window = NSWindow(contentRect: CGRect(x: 120, y: 100, width: 1060, height: 830),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "乘车径路 · 验证"
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ExperienceRootView(model: model, passport: passport, map: map))
        window.makeKeyAndOrderFront(nil)
        model.tab = .simulation
        try await Task.sleep(for: .seconds(2))
        _ = try await OnlineUIValidation.capture("imported-train-simulation", directory: directory, window: window)
        model.makePostcard(journey)
        try await Task.sleep(for: .seconds(2))
        _ = try await OnlineUIValidation.capture("passenger-postcard-preview", directory: directory, window: window)
        window.setContentSize(NSSize(width: 940, height: 680))
        try await Task.sleep(for: .milliseconds(300))
        _ = try await OnlineUIValidation.capture("passenger-postcard-narrow", directory: directory, window: window)
        window.contentView = NSHostingView(rootView: PassengerRouteView(journey: journey).environmentObject(model))
        window.setContentSize(NSSize(width: 660, height: 600))
        try await Task.sleep(for: .seconds(1))
        _ = try await OnlineUIValidation.capture("passport-passenger-route", directory: directory, window: window)
        for style in PostcardStyle.allCases {
            let renderer = ImageRenderer(content: TicketPostcardArt(style: style, journey: journey,
                caption: "只画这一程。", legs: passenger.legs)
                .environment(\.colorScheme, .light))
            renderer.scale = 2
            guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw DataError.invalid("route postcard render failed")
            }
            try require(image.width == 1520 && image.height == 880, "route postcard size")
            try png.write(to: directory.appendingPathComponent("passenger-\(style.rawValue).png"))
        }
        map.journeyPlayer.stop()
        let report = """
        PASS real LLT G6580 on 2026-11-09: dynamically matched \(route.legs.count) continuous map legs, \(Int(route.distance)) m.
        PASS Shenzhen North to Foshan West: exact legs 2..<6, \(passenger.stations.count) stops, \(Int(passenger.distance)) m; origin/terminus outside passenger segment excluded.
        PASS boarding-time autofill, selected timetable/route persistence and passport reload.
        PASS legacy/full LLT JSON import, backup and preservation after invalid import.
        PASS imported train movement and stationary dwell through the main-map player.
        CAPTURED simulation, passport segment, postcard preview/minimum width and red/blue/map exports at 1520x880.
        """
        try Data(report.utf8).write(to: directory.appendingPathComponent("journey-route-qa.txt"), options: .atomic)
        print(report)
    }
}
#endif
