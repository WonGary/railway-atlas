import Foundation
import RailwayCore
#if os(macOS)
import AppKit
import SwiftUI
#endif

@MainActor
enum PassportFootprintValidation {
    static let flag = "--passport-footprints-check"
    private struct Receipt: Encodable {
        var status = "FAIL"
        let bundle = Bundle.main.bundleURL.path
        var stages: [String] = []
        var origin = "", boarding = "", section = ""
        var metres = 0.0
        var error: String?
    }

    static func run(directory: URL) async {
        var report = Receipt()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await exercise(directory, report: &report)
            report.status = "PASS"
        } catch { report.error = error.localizedDescription }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("passport-footprints.json"), options: .atomic)
        } catch { print("护照验收报告写入失败 \(error.localizedDescription)") }
    }

    private static func require(_ pass: Bool, _ message: String) throws {
        if !pass { throw DataError.invalid(message) }
    }

    private static func exercise(_ directory: URL, report: inout Receipt) async throws {
        let map = RailwayMapStore()
        map.mapMode = .offline
        let historyDir = directory.appendingPathComponent("test-activity")
        map.passportActivity = PassportActivityStore(directory: historyDir)
        let activity = map.passportActivity
        let model = map.journeyWorkspace
        let passport = JourneyStore(directory: directory.appendingPathComponent("test-rides"))
        let resource = Bundle.main.resourceURL?.appendingPathComponent("station-directory/paths/index.json")
        try require(resource.map { FileManager.default.isReadableFile(atPath: $0.path) } == true, "安装包缺少全国径路索引")
        try require(passport.journeys.isEmpty && activity.entries.isEmpty, "请使用新的空测试目录")
        guard let train = try await NationalJourneyPaths.shared.timetable(train: "Z230", date: "2026-11-25",
                from: "海石湾", to: "平安驿", boarding: true),
              let path = try await NationalJourneyPaths.shared.journey(train, from: "海石湾", to: "平安驿") else {
            throw DataError.invalid("随附快照缺少 Z230 验收区间")
        }
        let table = try train.passengerSection(from: "海石湾", to: "平安驿")
        try require(path.legs.count == 2 && table.serviceDate == "2026-11-25" && train.serviceDate < table.serviceDate,
                    "跨夜上车日期或站序不符")
        report.origin = train.serviceDate; report.boarding = table.serviceDate
        let browse = try PassportActivity.segment(train, from: "海石湾", to: "平安驿")
        activity.record(browse, as: .browsed)
        activity.record(browse, as: .browsed)
        let station = RailwaySelection(id: "national:海石湾", name: "海石湾", subtitle: "车站",
            tags: ["railway":"station"], coordinate: path.legs[0][0])
        map.selection = station
        map.selection = station
        try map.journeyPlayer.start(table, route: path)
        map.journeyPlayer.pause(); map.journeyPlayer.seek(Double(table.end * 60)); map.journeyPlayer.stop()
        try map.journeyPlayer.start(table, route: path)
        map.journeyPlayer.stop()
        try require(activity.entries.filter { $0.kind == .browsed }.count == 2 &&
                    activity.entries.filter { $0.kind == .simulated }.count == 1 && passport.journeys.isEmpty,
                    "地图浏览、重复播放或结束播放改变了分类或乘车记录")
        guard let simulation = activity.entries.first(where: { $0.kind == .simulated })?.candidate,
              let request = PassportSectionRequest(simulation) else { throw DataError.invalid("模拟经历不能选择区间") }
        let stopNames = request.limits.map { request.table.stops[$0].station }
        try require(stopNames == ["海石湾", "乐都", "平安驿"], "区间选择超出了模拟路段")
        var narrow = try PassportActivity.segment(request.table, from: "乐都", to: "平安驿")
        narrow.source = request.source
        report.section = "\(narrow.from) → \(narrow.to)"
        try require((try? PassportActivity.segment(table, from: "平安驿", to: "乐都")) == nil &&
                    narrow.date == table.serviceDate && RailCivilDate.minute(narrow.departure) == table.stops[1].departure,
                    "区间顺序、上车日或发车时刻错误")
        report.stages.append("shelves-and-overnight")

        var bait = narrow; bait.status = .travelled; bait.note = "验收私密备注"
        let batch = JourneyImportBatch.section(bait)
        let candidate = batch.journeys[0]
        try require(candidate.status == .needsReview && candidate.note.isEmpty && candidate.id != narrow.id,
                    "从区间复制的候选包含原记录的确认状态、备注或标识")
        let choice = JourneyImportBatch.selection(batch.journeys, existing: passport.journeys)
        try require(choice.selected == [candidate.id] && choice.duplicates.isEmpty, "新候选默认选择错误")
        #if os(macOS)
        try await pressImport(batch, passport: passport)
        #else
        try require(passport.importReviewed(batch.journeys.filter { choice.selected.contains($0.id) }), "核对页保存失败")
        #endif
        let second = JourneyImportBatch.section(narrow)
        let duplicates = JourneyImportBatch.selection(second.journeys, existing: passport.journeys)
        try require(duplicates.selected.isEmpty && duplicates.duplicates == [second.journeys[0].id] &&
                    passport.pendingCount == 1 && passport.travelled.isEmpty && activity.entries.count == 3,
                    "再次导入未跳过相同区间，或导入改写了原经历")
        let pending = try await PassportFootprint.load(passport.journeys) { _ in throw DataError.invalid("待核对记录触发了径路查询") }
        try require(pending.confirmed.isEmpty && pending.stamps.isEmpty && pending.sections.isEmpty, "待核对产生足迹或章")
        report.stages.append("review-and-dedup")

        var confirmed = candidate
        confirmed.status = .travelled
        try require(passport.save(confirmed), "核对后的实乘记录保存失败")
        let unavailable = RailJourney(date: "2000-01-01", train: "QA9999", from: "测试甲", to: "测试乙", status: .travelled)
        var cancelled = unavailable; cancelled.id = UUID(); cancelled.status = .cancelled
        try require(passport.save(unavailable) && passport.save(cancelled), "混合状态写入失败")
        func load(_ records: [RailJourney], reuse: PassportFootprint? = nil) async throws -> PassportFootprint {
            try await PassportFootprint.load(records, reusing: reuse) { try await model.passengerRoute($0, allowNetwork: false) }
        }
        let measured = try await load(passport.journeys)
        let expected = RailTrackJourney.length(path.legs[1])
        try require(measured.sections.count == 1 && measured.missing.map(\.id) == [unavailable.id] &&
                    abs(measured.metres - expected) < 0.01 && measured.metres < path.distance,
                    "缺失径路、未乘坐或上车前的轨道进入了累计里程")
        try require(measured.sections[0].legs.count == 1 &&
                    measured.sections[0].legs[0].first == path.legs[1].first &&
                    measured.sections[0].legs[0].last == path.legs[1].last &&
                    !measured.stations.contains("海石湾"), "足迹地图绘出了所选区间以外的轨道或到访站")
        report.metres = measured.metres
        struct SavedTrack: Encodable { var timetable: RailTimetable; var journey: RailTrackJourney }
        var localTrain = table; localTrain.id = "qa-local-full"; localTrain.train = "QA90"
        var localTrack = path; localTrack.train = localTrain.train
        let archive = model.directory.appendingPathComponent("JourneyRoutes")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let cacheKey = localTrain.id.utf8.map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(SavedTrack(timetable: localTrain, journey: localTrack))
            .write(to: archive.appendingPathComponent("route-\(cacheKey).json"), options: .atomic)
        let localSection = try PassportActivity.segment(localTrain, from: "乐都", to: "平安驿")
        let fromCache = try await model.passengerRoute(localSection, allowNetwork: false)
        try require(fromCache.legs == [path.legs[1]], "离线缓存只有全程径路时未按实际上下车站截取")
        report.stages.append("geometry-mileage-and-gaps")

        let id = "station/乐都"
        try require(measured.stamps.contains { $0.id == id } && !measured.stamps.contains { $0.id == "km/100" },
                    "车站章或里程章解锁条件错误")
        activity.toggleStamp(id)
        let reopened = PassportActivityStore(directory: historyDir)
        try require(reopened.entries.count == 3 && reopened.pinned == [id] &&
                    JourneyStore(directory: passport.directory).journeys == passport.journeys,
                    "重开后丢失经历、收藏或旧格式护照")
        for folder in [historyDir, passport.directory] {
            try require(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                        "个人目录未排除系统云备份")
        }
        activity.toggleStamp(id)
        try require(PassportActivityStore(directory: historyDir).pinned.isEmpty, "取消收藏后仍在本机收藏夹")
        report.stages.append("local-persistence-and-stamps")

        var expanded = try PassportActivity.segment(train, from: "海石湾", to: "平安驿")
        expanded.id = confirmed.id; expanded.status = .travelled
        try require(passport.save(expanded), "编辑上车站失败")
        let edited = try await load(passport.journeys, reuse: measured)
        try require(abs(edited.metres - path.distance) < 0.01 && edited.sections.first?.legs.count == 2, "修改区间后仍显示旧足迹")
        guard let other = try await NationalJourneyPaths.shared.timetable(train: "G879", date: "2026-11-24") else {
            throw DataError.invalid("随附快照缺少 G879")
        }
        var distinct = other.draftJourney; distinct.status = .travelled
        try require(passport.save(distinct), "第二个区间未保存")
        let multiple = try await load(passport.journeys, reuse: edited)
        try require(multiple.sections.count == 2 && multiple.metres > path.distance + 100_000 &&
                    multiple.stamps.contains { $0.id == "km/100" }, "多区间累计或百公里章错误")
        #if os(macOS)
        try await capturePassport(model, passport, directory: directory)
        #endif
        passport.remove(distinct)
        passport.remove(expanded)
        let removed = try await load(passport.journeys, reuse: multiple)
        try require(removed.sections.isEmpty && removed.metres == 0 && !removed.stamps.contains { $0.id == id },
                    "移除实乘后仍计里程或保留失去依据的章")
        passport.undoRemoval()
        let undone = try await load(passport.journeys, reuse: removed)
        try require(abs(undone.metres - path.distance) < 0.01, "撤销后没有恢复实际区间")
        let savedSimulation = activity.entries.first { $0.kind == .simulated }!
        activity.remove(savedSimulation)
        try require(PassportActivityStore(directory: historyDir).entries.count == 2 && passport.travelled.count == 2,
                    "删除模拟经历影响其他类别")
        report.stages.append("edit-delete-undo")
    }

    #if os(macOS)
    private static func pressImport(_ batch: JourneyImportBatch, passport: JourneyStore) async throws {
        let host = NSHostingView(rootView: JourneyImportReviewView(batch: batch).environmentObject(passport))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 650, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func attribute(_ key: String, _ node: NSObject) -> Any? {
            node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
        }
        var labels = Set<String>()
        for attempt in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            var nodes: [NSObject] = [window, host], seen = Set<ObjectIdentifier>()
            while let node = nodes.popLast() {
                guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
                let id = attribute("accessibilityIdentifier", node) as? String
                let title = attribute("accessibilityLabel", node) as? String ?? (node as? NSButton)?.title
                if let title, !title.isEmpty { labels.insert(title) }
                if id == "passport-import-selected" || title == "导入所选" {
                    if let button = node as? NSButton, button.isEnabled { button.performClick(nil); break }
                    if let control = node as? NSAccessibilityProtocol, control.accessibilityPerformPress() { break }
                }
                if let view = node as? NSView { nodes += view.subviews }
                nodes += attribute("accessibilityChildren", node) as? [NSObject] ?? []
            }
            if attempt == 10, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
            }
            if passport.pendingCount == 1 { return }
        }
        throw DataError.invalid("核对页的导入按钮没有写入候选。页面可见控件 \(labels.sorted().joined(separator: "、"))；\(passport.error ?? "")")
    }

    private static func capturePassport(_ model: ExperienceStore, _ passport: JourneyStore, directory: URL) async throws {
        let host = NSHostingView(rootView: ScrollView { RailwayPassportView().padding(18) }.background(.background)
            .environmentObject(model).environmentObject(passport))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 830, height: 940),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw DataError.invalid("足迹截图失败") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw DataError.invalid("足迹截图编码失败") }
        try png.write(to: directory.appendingPathComponent("passport-footprints.png"), options: .atomic)
    }
    #endif
}
