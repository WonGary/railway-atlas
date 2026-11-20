import Foundation
import RailwayCore
import SwiftUI

struct TimetableLibraryArchive: Codable, Sendable {
    var version: Int
    var provider: String
    var edition: String
    var timetables: [RailTimetable]
    static let limit = 80_000_000
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= limit else { throw DataError.invalid("离线库超过 80 MB") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, !result.provider.isEmpty, result.provider.count <= 200,
              !result.edition.isEmpty, result.edition.count <= 100,
              (1...100_000).contains(result.timetables.count),
              Set(result.timetables.map(\.id)).count == result.timetables.count else {
            throw DataError.invalid("离线库的版本、来源或车次标识无效")
        }
        try result.timetables.forEach { try $0.validate() }
        return result
    }
}

@MainActor
final class TimetableLibraryStore: ObservableObject {
    @Published private(set) var archive: TimetableLibraryArchive?
    @Published private(set) var lulu: LuluTimetableSnapshot?
    @Published var updateURL = ""
    @Published var message: String?
    @Published private(set) var busy = false
    private let directory: URL
    private var readOnly = false
    init(directory: URL) {
        self.directory = directory
        let file = directory.appendingPathComponent("library.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) { archive = try Self.read(file) }
            let luluFile = directory.appendingPathComponent("lulutong.json")
            if FileManager.default.fileExists(atPath: luluFile.path) {
                guard (try luluFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 80_000_000 else {
                    throw DataError.invalid("路路通缓存超限")
                }
                lulu = try LuluTimetableSnapshot.read(Data(contentsOf: luluFile))
            }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("source.json")),
               let value = try? JSONDecoder().decode(String.self, from: data) { updateURL = value }
        } catch { readOnly = true; message = "离线库损坏，已保留原文件：\(error.localizedDescription)" }
    }
    func synchronizeLulu() async {
        guard !busy else { return }
        busy = true; message = "正在读取路路通官网公开包并校验全库…"
        defer { busy = false }
        do {
            guard !readOnly else { throw DataError.invalid("原库只读，请先检查损坏文件") }
            let next = try await LuluTimetableClient.download()
            try saveLulu(next)
        } catch { message = "路路通同步失败，原库保留：\(error.localizedDescription)" }
    }
    private func saveLulu(_ next: LuluTimetableSnapshot) throws {
        guard !readOnly else { throw DataError.invalid("原库只读，请先检查损坏文件") }
        let data = try JSONEncoder().encode(next)
        _ = try LuluTimetableSnapshot.read(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("lulutong.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try Data(contentsOf: file).write(to: directory.appendingPathComponent("lulutong.previous.json"), options: .atomic)
        }
        try data.write(to: file, options: .atomic); lulu = next
        message = "路路通 \(next.edition)：\(next.services.count) 条车次，\(next.routing?.routes.count ?? 0) 条径路，已保存到本机。"
    }
    nonisolated private static func read(_ file: URL) throws -> TimetableLibraryArchive {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= TimetableLibraryArchive.limit else {
            throw DataError.invalid("离线库超过 80 MB")
        }
        return try TimetableLibraryArchive.decode(Data(contentsOf: file))
    }
    func importFile(_ url: URL) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= TimetableLibraryArchive.limit else {
                    throw DataError.invalid("离线库超过 80 MB")
                }
                return try Data(contentsOf: url)
            }.value
            if let next = try? LuluTimetableSnapshot.read(data) { try saveLulu(next) }
            else { try save(TimetableLibraryArchive.decode(data)) }
        } catch { message = "未导入，原库保留：\(error.localizedDescription)" }
    }
    func synchronize() async {
        guard !busy else { return }
        guard let url = URL(string: updateURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            message = "此入口需要 HTTPS JSON 离线库地址；路路通请使用上方的专用同步按钮。"
            return
        }
        busy = true; defer { busy = false }
        do {
            let next = try await Task.detached {
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 120
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                let (bytes, response) = try await session.bytes(from: url)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https", response.expectedContentLength <= TimetableLibraryArchive.limit else {
                    throw DataError.invalid("下载响应无效")
                }
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    guard data.count <= TimetableLibraryArchive.limit else { throw DataError.invalid("下载超限") }
                }
                return try TimetableLibraryArchive.decode(data)
            }.value
            try save(next)
            try JSONEncoder().encode(updateURL).write(to: directory.appendingPathComponent("source.json"), options: .atomic)
        } catch { message = "同步失败，原库保留：\(error.localizedDescription)" }
    }
    private func save(_ next: TimetableLibraryArchive) throws {
        guard !readOnly else { throw DataError.invalid("原库只读，请先检查损坏文件") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try Data(contentsOf: file).write(to: directory.appendingPathComponent("library.previous.json"), options: .atomic)
        }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        archive = next
        message = "已载入 \(next.timetables.count) 个日期车次 · \(next.provider) · \(next.edition)"
    }
}
