import Foundation
import RailwayCore
import SwiftUI

enum PassportLocalFiles {
    static func prepare(_ directory: URL) throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
}

/// Each entry has its own file so selecting a station never rewrites the whole history.
@MainActor
final class PassportActivityStore: ObservableObject {
    @Published private(set) var entries: [PassportActivity] = []
    @Published private(set) var pinned: Set<String> = []
    @Published private(set) var message: String?
    private(set) var readOnly = false
    private var idsByKey: [String: UUID] = [:]
    let directory: URL
    private var starsFile: URL { directory.appendingPathComponent("stamps.json") }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    init(directory: URL) {
        self.directory = directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try PassportLocalFiles.prepare(directory)
            let decoder = JSONDecoder()
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                let entry = try decoder.decode(PassportActivity.self, from: Data(contentsOf: url))
                guard entry.id == id, idsByKey[entry.key] == nil else { throw DataError.invalid("经历记录的标识重复或不符") }
                entries.append(entry)
                idsByKey[entry.key] = id
            }
            entries.sort { $0.opened > $1.opened }
            if FileManager.default.fileExists(atPath: starsFile.path) {
                pinned = try decoder.decode(Set<String>.self, from: Data(contentsOf: starsFile))
            }
        } catch {
            readOnly = true
            message = "经历暂时只读，原文件已保留。\(error.localizedDescription)"
        }
    }

    func browse(_ selection: RailwaySelection) {
        guard selection.isStation || selection.tags["railway"] != nil || selection.tags["route"] != nil else { return }
        record(.init(kind: .browsed, subject: .feature(key: FavoriteIdentity.key(for: selection),
                                                       name: selection.name, station: selection.isStation)))
    }

    func browseLine(_ key: String, name: String) {
        record(.init(kind: .browsed, subject: .feature(key: key, name: name, station: false)))
    }

    func record(_ journey: RailJourney, as kind: PassportActivityKind) {
        guard journey.validationMessage == nil else { return }
        let segment = PassportActivity.pending(journey, source: "\(kind.title)区间")
        record(.init(kind: kind, subject: .segment(segment)))
    }

    func simulationStarted(_ timetable: RailTimetable) {
        // A running player has already validated the track against this timetable.
        let segment = timetable.draftJourney
        record(segment, as: .simulated)
    }

    private func record(_ input: PassportActivity) {
        guard !readOnly else { return }
        var entry = input
        if let existing = idsByKey[entry.key] { entry.id = existing }
        do {
            try PassportLocalFiles.prepare(directory)
            try JSONEncoder().encode(entry).write(to: file(entry.id), options: .atomic)
            idsByKey[entry.key] = entry.id
            entries.removeAll { $0.id == entry.id }
            entries.insert(entry, at: 0)
            message = nil
        } catch { message = "经历未保存。\(error.localizedDescription)" }
    }

    func remove(_ entry: PassportActivity) {
        guard !readOnly, idsByKey[entry.key] == entry.id else { return }
        do {
            try FileManager.default.removeItem(at: file(entry.id))
            entries.removeAll { $0.id == entry.id }
            idsByKey[entry.key] = nil
            message = nil
        } catch { message = "经历未移除。\(error.localizedDescription)" }
    }

    func toggleStamp(_ id: String) {
        guard !readOnly else { return }
        var next = pinned
        if !next.insert(id).inserted { next.remove(id) }
        do {
            try PassportLocalFiles.prepare(directory)
            try JSONEncoder().encode(next.sorted()).write(to: starsFile, options: .atomic)
            pinned = next
            message = nil
        } catch { message = "收藏章未保存。\(error.localizedDescription)" }
    }
}
