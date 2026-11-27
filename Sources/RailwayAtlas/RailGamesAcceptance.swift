import Foundation
import RailwayCore
import WebKit
#if os(macOS)
import AppKit
private typealias GamePlatformView = NSView
#else
import UIKit
private typealias GamePlatformView = UIView
#endif

/// Installed-app check. Uses the real menu/controls, the bundled WK page and the main map's player.
@MainActor
enum RailGamesAcceptance {
    static let requested = CommandLine.arguments.contains("--rail-games-check")
    private static var started = false

    struct Ride: Codable {
        let game, train, date: String
        let stations: [String]
        let legs: Int
        let playerRunning, markerOnMap, mainMapVisible: Bool
    }
    struct Receipt: Encodable {
        var status = "FAIL"
        let bundle = Bundle.main.bundleURL.path
        var resources = [String]()
        var rides = [Ride]()
        var error: String?
    }
    private struct Fixture {
        let game: ExperienceTab, train: String, date: String, stops: [String]
    }
    private static let fixtures = [
        Fixture(game: .blind, train: "Z230", date: "2026-11-25", stops: ["海石湾", "乐都", "平安驿"]),
        Fixture(game: .detective, train: "G879", date: "2026-11-24", stops: []),
        Fixture(game: .puzzle, train: "C101", date: "2026-11-28", stops: ["哈尔滨", "高楞", "依兰", "佳木斯", "鹤立", "鹤岗"]),
        Fixture(game: .daily, train: "G1609", date: "2026-11-28", stops: ["普宁", "陆丰"])
    ]

    static func run(store: RailwayMapStore, showDiscovery: () -> Void) async {
        guard requested, !started else { return }
        started = true
        let args = CommandLine.arguments
        let directory: URL
        if let i = args.firstIndex(of: "--ui-smoke"), args.indices.contains(i + 1) {
            directory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RailGamesCheck", isDirectory: true)
        }
        var receipt = Receipt(), stage = "包内资源"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let assets = try RailGameAssets.bundled.get()
            guard let root = Bundle.main.resourceURL?.resolvingSymlinksInPath(),
                  assets.webRoot.resolvingSymlinksInPath() == root else { throw failure("玩法从安装包以外载入") }
            let files = [assets.page] + ["rail-games.js", "games/outlines.json", "station-directory/national.js",
                                         "station-directory/paths/index.json"].map { root.appendingPathComponent($0) }
            for file in files {
                guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                      FileManager.default.isReadableFile(atPath: file.path) else { throw failure("缺少 \(file.path)") }
                receipt.resources.append(file.path)
            }
            for f in fixtures {
                stage = f.game.title + "入口"
                #if os(macOS)
                try await openMenu(f.game)
                #else
                showDiscovery()
                try await openShortcut(f.game)
                #endif
                let web: WKWebView = try await wait(stage) {
                    for root in roots {
                        for view in descendants(root).compactMap({ $0 as? WKWebView }) where view.url?.standardizedFileURL == assets.page {
                            let showing = try? await view.callAsyncJavaScript(
                                "const p = document.querySelector('[data-experience-page=\"'+id+'\"]'); return !!(p && !p.hidden && p.querySelector('button'));",
                                arguments: ["id": f.game.rawValue], in: nil, contentWorld: .page)
                            if showing as? Bool == true { return view }
                        }
                    }
                    return nil
                }
                stage = f.game.title + "作答"
                _ = try await web.callAsyncJavaScript(play, arguments: ["id": f.game.rawValue, "order": f.stops], in: nil, contentWorld: .page)
                stage = f.game.title + "主地图"
                let expectedStops: [String]
                if f.game == .detective, let table = try await NationalJourneyPaths.shared.timetable(train: f.train, date: f.date) {
                    expectedStops = table.stops.map(\.station)
                } else { expectedStops = f.stops }
                var observed = ""
                let ride: Ride
                do { ride = try await wait(stage) {
                    let player = store.journeyPlayer
                    observed = "\(player.timetable?.train ?? "—") \(player.timetable?.stops.map(\.station).joined(separator: " → ") ?? "") / \(store.experienceLines.count) 段 / 播放 \(player.playing) / 主地图 \(mainMapVisible)"
                    let feedback = try? await web.callAsyncJavaScript(
                        "return document.querySelector('[data-experience-page=\"'+id+'\"] [role=status]:last-child')?.textContent || [...document.querySelectorAll('[role=status]')].find(x=>x.textContent.includes('暂时无法回放'))?.textContent || '';",
                        arguments: ["id": f.game.rawValue], in: nil, contentWorld: .page)
                    if let message = feedback as? String, message.contains("暂时无法回放") { throw failure(message) }
                    guard let table = player.timetable, table.train == f.train, table.serviceDate == f.date,
                          table.stops.map(\.station) == expectedStops, store.experienceLines.count == expectedStops.count - 1,
                          store.experienceLines.allSatisfy({ $0.coordinates.count >= 2 }),
                          player.playing, store.experienceMarker != nil, mainMapVisible else { return nil }
                    return Ride(game: f.game.rawValue, train: table.train, date: table.serviceDate,
                                stations: expectedStops, legs: store.experienceLines.count, playerRunning: player.playing,
                                markerOnMap: store.experienceMarker != nil, mainMapVisible: mainMapVisible)
                } } catch {
                    #if os(macOS)
                    observed += " / " + NSApp.orderedWindows.filter(\.isVisible).map {
                        "\($0.identifier?.rawValue ?? "?")=\($0.title) key=\($0.isKeyWindow)"
                    }.joined(separator: ", ")
                    #endif
                    throw failure("\(error.localizedDescription)（\(observed)）")
                }
                receipt.rides.append(ride)
                store.journeyPlayer.stop()
            }
            receipt.status = "PASS"
        } catch { receipt.error = "\(stage) · \(error.localizedDescription)" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try encoder.encode(receipt).write(to: directory.appendingPathComponent("rail-games.json"), options: .atomic) }
        catch { print("Rail games receipt: \(error.localizedDescription)") }
        #if os(macOS)
        NSApp.terminate(nil)
        #endif
    }

    private static func failure(_ text: String) -> DataError { .invalid(text) }
    private static func wait<T>(_ label: String, poll: () async throws -> T?) async throws -> T {
        let until = ProcessInfo.processInfo.systemUptime + 14
        repeat {
            if let result = try await poll() { return result }
            try await Task.sleep(for: .milliseconds(120))
        } while ProcessInfo.processInfo.systemUptime < until
        throw failure("等待\(label)超时")
    }
    private static func descendants(_ view: GamePlatformView) -> [GamePlatformView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    #if os(macOS)
    private static var roots: [NSView] { NSApp.windows.filter(\.isVisible).compactMap(\.contentView) }
    private static var mainMapVisible: Bool {
        // A background QA process can have no key window. Inspect its own front document window.
        let front = NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
        return front?.identifier?.rawValue == "main-map" && front?.isVisible == true
    }
    private static func openMenu(_ game: ExperienceTab) async throws {
        let _: Bool = try await wait("漫游菜单") {
            guard let menu = NSApp.mainMenu?.item(withTitle: "漫游")?.submenu else { return nil }
            menu.update()
            let index = menu.indexOfItem(withTitle: game.title)
            guard index >= 0, menu.item(at: index)?.isEnabled == true else { return nil }
            menu.performActionForItem(at: index)
            return true
        }
    }
    #else
    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).filter(\.isKeyWindow)
    }
    private static var roots: [UIView] { windows.map { $0 as UIView } }
    private static var mainMapVisible: Bool {
        windows.contains { $0.rootViewController != nil && $0.rootViewController?.presentedViewController == nil }
    }
    private static func openShortcut(_ game: ExperienceTab) async throws {
        let _: Bool = try await wait(game.title) {
            for root in roots {
                if let button = descendants(root).compactMap({ $0 as? UIButton }).first(where: {
                    $0.accessibilityIdentifier == "rail-game-entry-" + game.rawValue && $0.window != nil && !$0.isHidden && $0.isEnabled
                }) {
                    button.sendActions(for: .touchUpInside)
                    return true
                }
            }
            return nil
        }
    }
    #endif

    // Exercise the visible controls. The only fixed inputs are the QA clock, draw and expected public records.
    private static let play = """
    const p = document.querySelector('[data-experience-page="'+id+'"]');
    const btn = name => [...p.querySelectorAll('button')].find(b => b.textContent===name && !b.disabled && !b.closest('[hidden]'));
    const click = name => { const b=btn(name); if (!b) throw Error('找不到按钮 '+name); b.click(); };
    const expect = text => { if (!p.innerText.includes(text)) throw Error('页面未显示 '+text+' / '+p.innerText); };
    if (id==='rail-blind') {
      const [station, date, limit] = p.querySelectorAll('input');
      station.value='海石湾'; date.value='2026-11-25'; limit.value='52'; click('抽一段行程');
      if (p.querySelectorAll('li').length!==1 || p.innerText.includes('平安驿')) throw Error('盲盒提前揭晓');
      click('揭晓下一站'); expect('乐都'); click('揭晓下一站'); expect('Z230');
    } else if (id==='rail-detective') {
      if (!p.querySelector('canvas') || p.querySelectorAll('li').length) throw Error('路形或线索初态有误');
      click('给我一条线索'); click('给我一条线索'); click('给我一条线索');
      const wrong=[...p.querySelectorAll('.quiz-choice')].find(b => b.textContent!=='北京南 → 青岛');
      wrong.click(); expect('对不上'); click('北京南 → 青岛'); expect('G879');
    } else if (id==='rail-puzzle') {
      for (const b of p.querySelectorAll('.quiz-choice')) b.click();
      click('核对站序'); expect('站序没对上');
      for (const s of order) click('撤回一站');
      for (const s of order) click(s);
      click('核对站序'); expect('铁路拼图完成卡'); expect(order.join(' → '));
    } else if (id==='rail-daily') {
      expect('2026-11-28'); expect('G1609'); expect('普宁');
      const answer=p.querySelector('input'); answer.value='3'; click('提交答案'); expect('再核对');
      answer.value='2'; click('提交答案'); expect('答对了');
    }
    click('在主地图沿线旅行');
    return true;
    """
}
