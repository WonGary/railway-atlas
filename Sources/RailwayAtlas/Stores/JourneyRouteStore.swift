import Foundation
import RailwayCore

extension ExperienceStore {
    func prepareRoute(_ input: RailTimetable, allowNetwork: Bool = true, retryMissing: Bool = false) async throws -> RailTrackJourney {
        let online = allowNetwork && map?.mapMode != .offline
        try Task.checkCancellation()
        // Existing full-geometry snapshots remain usable without a download.
        if input.routing == nil, input.routingIssue == nil, let known = trackJourneys.first(where: {
            $0.train == input.train && $0.serviceDate == input.serviceDate && $0.stations == input.stops.map(\.station)
        }) { try known.validate(for: input); return known }
        do {
            if let result = try await NationalJourneyPaths.shared.journey(input) { return result }
        } catch {
            try Task.checkCancellation()
            if let saved = await routeRepository.savedRoute(input) { return saved }
            if !retryMissing { throw error }
        }
        let timetable = try await routedTimetable(input, allowNetwork: online && retryMissing)
        if !retryMissing {
            if let saved = await routeRepository.savedRoute(timetable) { return saved }
            throw DataError.invalid("这份时刻表还没有连续轨迹。可用「重新匹配」从地图补查。")
        }
        let result = try await routeRepository.route(timetable, allowNetwork: online)
        try Task.checkCancellation()
        return result
    }

    private func routedTimetable(_ input: RailTimetable, allowNetwork: Bool) async throws -> RailTimetable {
        var timetable = input
        if timetable.routing == nil {
            if library.lulu?.routing == nil, library.lulu != nil, allowNetwork { await library.synchronizeLulu() }
            if let lulu = library.lulu, let service = lulu.services.first(where: {
                $0.train == input.train && $0.validFrom <= input.serviceDate && input.serviceDate <= $0.validThrough
                    && $0.stops == input.stops
            }) { timetable = try lulu.timetable(service, on: input.serviceDate) }
        }
        try Task.checkCancellation()
        return timetable
    }

    func timetable(for journey: RailJourney) throws -> RailTimetable {
        guard journey.validationMessage == nil, !journey.train.isEmpty else {
            throw DataError.invalid(journey.validationMessage ?? "请填写车次，才能确定乘车径路")
        }
        func matches(_ train: RailTimetable) -> Bool {
            guard !LuluRouteDatabase.trainNames(train.train).isDisjoint(with: LuluRouteDatabase.trainNames(journey.train)),
                  let a = train.stops.firstIndex(where: { $0.station == journey.from }),
                  let b = train.stops.lastIndex(where: { $0.station == journey.to }), a < b,
                  let departure = train.stops[a].departure,
                  RailCivilDate.addingDays(departure / 1440, to: train.serviceDate) == journey.date else { return false }
            return journey.departure.isEmpty || RailCivilDate.minute(journey.departure) == departure % 1440
        }
        if let saved = journey.timetable, matches(saved) { try saved.validate(); return saved }
        let saved = timetables.filter(matches)
        if saved.count == 1 { return saved[0] }
        guard let lulu = library.lulu else { throw DataError.invalid("请先同步路路通离线库，或选择已有的日期车次") }
        let names = LuluRouteDatabase.trainNames(journey.train)
        var results: [RailTimetable] = []
        for service in lulu.services where !LuluRouteDatabase.trainNames(service.train).isDisjoint(with: names) {
            guard let index = service.stops.firstIndex(where: { $0.station == journey.from }),
                  let departure = service.stops[index].departure,
                  let origin = RailCivilDate.addingDays(-(departure / 1440), to: journey.date),
                  service.validFrom <= origin, origin <= service.validThrough else { continue }
            let candidate = try service.timetable(on: origin, edition: lulu.edition, retrievedOn: lulu.retrievedOn)
            if matches(candidate) { results.append(try lulu.timetable(service, on: origin)) }
        }
        guard results.count == 1 else {
            throw DataError.invalid(results.isEmpty ? "该日期车次没有依次经过所填起终点，请核对日期、站名和发车时间"
                                   : "该车次有多个时刻版本，请从离线库明确选择后再绘制")
        }
        return results[0]
    }

    func passengerRoute(_ journey: RailJourney, allowNetwork: Bool = true, retryMissing: Bool = false) async throws -> RailTrackJourney {
        let online = allowNetwork && map?.mapMode != .offline
        let train: RailTimetable
        do { train = try timetable(for: journey) }
        catch {
            guard let found = try await NationalJourneyPaths.shared.timetable(train:journey.train,date:journey.date,
                from:journey.from,to:journey.to,boarding:true,departure:journey.departure) else { throw error }
            train = found
        }
        if train.routing == nil, train.routingIssue == nil, let known = trackJourneys.first(where: {
            $0.train == train.train && $0.serviceDate == train.serviceDate && $0.stations == train.stops.map(\.station)
        }) { try known.validate(for: train); return try known.slice(from: journey.from, to: journey.to) }
        do {
            if let result = try await NationalJourneyPaths.shared.journey(train,from:journey.from,to:journey.to) { return result }
        } catch {
            try Task.checkCancellation()
            if let section = try? train.passengerSection(from:journey.from,to:journey.to),
               let saved = await routeRepository.savedRoute(section) { return saved }
            if !retryMissing { throw error }
        }
        let routed = try await routedTimetable(train, allowNetwork: online && retryMissing)
        let section = try routed.passengerSection(from: journey.from, to: journey.to)
        if !retryMissing {
            if let saved = await routeRepository.savedRoute(section) { return saved }
            throw DataError.invalid("该乘车区间还没有连续轨迹。可用「重新匹配乘车路线」补查。")
        }
        return try await routeRepository.route(section, allowNetwork: online)
    }
}
