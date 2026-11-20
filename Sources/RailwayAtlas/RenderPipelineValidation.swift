#if os(macOS)
import Foundation
import RailwayCore

@MainActor
enum RenderPipelineValidation {
    static func run(store: RailwayMapStore, directory: URL) async throws {
        guard let key = store.tileFeatures.keys.first(where: { !(store.tileFeatures[$0]?.lines.isEmpty ?? true) }),
              var changed = store.tileFeatures[key], var line = changed.lines.first else {
            throw DataError.invalid("Streaming test requires the Tokyo fixture")
        }
        let before = store.assemblyPasses
        store.publishTiles()
        try await wait { store.assemblyPasses > before }
        // The first Tokyo worker is in flight. A newer viewport and several
        // arrivals must produce one follow-up pass using the latest contents.
        store.viewportGeneration = UUID()
        line.id = "qa/latest-arrival"
        changed.lines.append(line)
        store.tileFeatures[key] = changed
        for _ in 0..<20 { store.publishTiles() }
        try await wait { store.assemblyTask == nil }
        guard store.assemblyPasses - before == 2,
              store.onlineLines.contains(where: { $0.id == line.id || $0.id.hasPrefix(line.id + "/display/") }) else {
            throw DataError.invalid("Streaming updates did not coalesce or lost the newest viewport")
        }
        let beforeCancel = store.assemblyPasses
        store.publishTiles()
        try await wait { store.assemblyPasses > beforeCancel }
        store.changeMode(.offline)
        let revision = store.renderRevision
        try await Task.sleep(for: .seconds(2))
        guard store.assemblyTask == nil, store.renderRevision == revision, store.mapMode == .offline else {
            throw DataError.invalid("Cancelled online assembly changed the offline map")
        }
        let report = """
        PASS: 20 notifications during an in-flight Tokyo assembly coalesce to one follow-up pass.
        PASS: a newer viewport's last arrival is present; the stale worker cannot overwrite it.
        PASS: switching to the local map cancels assembly and cannot publish late online geometry.
        """
        try Data(report.utf8).write(to: directory.appendingPathComponent("render-pipeline.txt"))
    }

    private static func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !ready() {
            guard Date() < deadline else { throw DataError.invalid("Streaming test timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
