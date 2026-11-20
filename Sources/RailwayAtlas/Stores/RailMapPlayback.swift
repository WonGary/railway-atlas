import Foundation
import MapKit
import RailwayCore
import SwiftUI

struct ExperienceMapLine: Identifiable {
    let id: String
    let coordinates: [Coordinate]
    let colour: String
    var uncertain = false
}

@MainActor
final class RailMapPlayback: ObservableObject {
    enum Mode { case train, history }
    @Published private(set) var mode: Mode?
    @Published var seconds = 0.0
    @Published var speed = 60.0
    @Published var follow = true
    @Published private(set) var playing = false
    @Published private(set) var timetable: RailTimetable?
    @Published private(set) var region: RailHistoryRegion?
    @Published var historyIndex = 0
    @Published var showUnknown = false { didSet { if mode == .history { drawHistory() } } }
    private weak var map: RailwayMapStore?
    private var route: RailTrackJourney?
    private var work: Task<Void, Never>?
    private var previousRegion: MKCoordinateRegion?
    private var cameraTime = 0.0
    init(map: RailwayMapStore) { self.map = map }
    var historyDates: [String] {
        guard let region, let first = region.dates.first else { return [] }
        // An empty initial frame makes the first construction step visible.
        return [String((Int(first.prefix(4)) ?? 1900) - 1) + "-12-31"] + region.dates
    }
    var date: String { historyDates.indices.contains(historyIndex) ? historyDates[historyIndex] : "" }
    var visibleSegmentCount: Int { region?.segments.filter { $0.visible(on: date) }.count ?? 0 }
    var trainStatus: String {
        guard let timetable else { return "" }
        let p = timetable.position(at: seconds), a = timetable.stops[p.from].station
        switch p.phase {
        case .running: return "\(a) → \(timetable.stops[p.to].station)"
        case .dwelling: return "停靠 · \(a)"
        case .arrived: return "已抵达 · \(a)"
        case .waiting: return "候车 · \(a)"
        case .unknown: return "时刻不完整 · 位置未知"
        }
    }
    func start(_ timetable: RailTimetable, route: RailTrackJourney) throws {
        try route.validate(for: timetable)
        pause()
        rememberCamera()
        self.timetable = timetable; self.route = route; region = nil; mode = .train
        seconds = Double(timetable.start * 60); cameraTime = 0
        map?.historyMapActive = false
        map?.experienceLines = route.legs.enumerated().map {
            ExperienceMapLine(id: "\(route.id)/\($0.offset)", coordinates: $0.element, colour: "#DC653D")
        }
        map?.experienceGeometryRevision += 1
        if let point = route.legs.first?.first { focus(point, span: 0.12) }
        updateTrain()
        play()
    }
    func start(_ region: RailHistoryRegion) {
        pause()
        rememberCamera()
        self.region = region; timetable = nil; route = nil; mode = .history
        historyIndex = 0
        map?.historyMapActive = true
        map?.experienceMarker = nil
        if let map {
            let b = region.bounds
            map.region = MKCoordinateRegion(center: b.center.location,
                span: MKCoordinateSpan(latitudeDelta: max(0.05, (b.north - b.south) * 1.2),
                                       longitudeDelta: max(0.05, (b.east - b.west) * 1.2)))
            map.cameraRevision += 1
        }
        drawHistory()
    }
    func seek(_ value: Double) {
        if let timetable, mode == .train {
            seconds = max(Double(timetable.start * 60), min(Double(timetable.end * 60), value))
            updateTrain(forceCamera: true)
        } else if mode == .history {
            historyIndex = max(0, min(historyDates.count - 1, Int(value)))
            drawHistory()
        }
    }
    func toggle() { if playing { pause() } else { play() } }
    func pause() { playing = false; work?.cancel(); work = nil }
    func play() {
        guard mode != nil else { return }
        pause()
        if mode == .train, let timetable, seconds >= Double(timetable.end * 60) { seek(Double(timetable.start * 60)) }
        if mode == .history, historyIndex >= historyDates.count - 1 { seek(0) }
        playing = true
        work = Task { [weak self] in
            var last = ProcessInfo.processInfo.systemUptime, elapsed = 0.0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.playing else { return }
                let now = ProcessInfo.processInfo.systemUptime, delta = now - last
                last = now
                if self.mode == .train, let timetable = self.timetable {
                    self.seconds = min(Double(timetable.end * 60), self.seconds + delta * self.speed)
                    self.updateTrain()
                    if self.seconds >= Double(timetable.end * 60) { self.pause() }
                } else if self.mode == .history {
                    elapsed += delta
                    if elapsed >= 1.5 {
                        elapsed = 0
                        self.seek(Double(self.historyIndex + 1))
                        if self.historyIndex >= self.historyDates.count - 1 { self.pause() }
                    }
                }
            }
        }
    }
    func stop() {
        pause(); mode = nil
        map?.experienceLines = []; map?.experienceMarker = nil
        map?.historyMapActive = false; map?.experienceGeometryRevision += 1
        if let previousRegion { map?.region = previousRegion; map?.cameraRevision += 1 }
        previousRegion = nil
    }
    private func rememberCamera() { if previousRegion == nil { previousRegion = map?.region } }
    private func focus(_ point: Coordinate, span: Double? = nil) {
        guard let map else { return }
        map.region = MKCoordinateRegion(center: point.location,
            span: span.map { MKCoordinateSpan(latitudeDelta: $0, longitudeDelta: $0 * 1.4) } ?? map.region.span)
        map.cameraRevision += 1
    }
    private func updateTrain(forceCamera: Bool = false) {
        guard let timetable, let route else { return }
        let point = route.coordinate(at: timetable.position(at: seconds))
        map?.experienceMarker = point
        let now = ProcessInfo.processInfo.systemUptime
        if follow, let point, forceCamera || now - cameraTime >= 1 {
            cameraTime = now; focus(point)
        }
    }
    private func drawHistory() {
        guard let region, let map else { return }
        map.experienceLines = region.segments.compactMap { segment in
            if segment.visible(on: date) {
                return ExperienceMapLine(id: segment.id, coordinates: segment.coordinates,
                                         colour: segment.colour ?? "#2DAD87")
            }
            if let construction = segment.construction, RailDatedSegment.upperBound(construction) <= date,
               let opened = segment.opened, RailDatedSegment.upperBound(opened) > date {
                return ExperienceMapLine(id: segment.id, coordinates: segment.coordinates, colour: "#DE9946", uncertain: true)
            }
            if showUnknown, segment.opened == nil {
                return ExperienceMapLine(id: segment.id, coordinates: segment.coordinates, colour: "#819096", uncertain: true)
            }
            return nil
        }
        map.experienceGeometryRevision += 1
    }
}
