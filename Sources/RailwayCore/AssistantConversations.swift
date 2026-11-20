import Foundation

public enum AssistantContextMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, summary, full
    public var id: String { rawValue }
    public var title: String {
        switch self { case .none: "不附带"; case .summary: "精简"; case .full: "完整" }
    }
    public var explanation: String {
        switch self {
        case .none: "不附加新旧地图材料，仍保留对话正文。需要空白上下文时可新建对话。"
        case .summary: "只附名称、类型、运营信息与少量统计；不附坐标、原始标签和区段明细。"
        case .full: "附带已载入范围的地图材料；发送时仍受历史与长度限额约束。"
        }
    }
    public func project(_ reference: AssistantContextSnapshot?) -> AssistantContextSnapshot? {
        guard let reference, self != .none else { return nil }
        return self == .summary ? reference.summarized() : reference
    }
}

/// A local, immutable reference. Its UUID identifies this material version, not the map selection.
public struct AssistantContextSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let scope: String
    public let featureIDs: [String]
    public let text: String
    public let capturedAt: Date

    public init(id: UUID = UUID(), title: String, scope: String, featureIDs: [String] = [],
                text: String, capturedAt: Date = Date()) {
        self.id = id; self.title = title; self.scope = scope
        self.featureIDs = featureIDs; self.text = text; self.capturedAt = capturedAt
    }

    public func matches(title: String, scope: String, featureIDs: [String], text: String) -> Bool {
        self.title == title && self.scope == scope && self.featureIDs == featureIDs
            && Self.material(self.text) == Self.material(text)
    }

    /// Whitelist a small, valid JSON summary. Never truncate raw JSON or copy arbitrary tags.
    public func summarized() -> Self {
        let input = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        func short(_ value: Any?, limit: Int = 100) -> String? {
            guard let value = value as? String, !value.isEmpty else { return nil }
            return String(value.prefix(limit))
        }
        func feature(_ value: [String: Any]) -> [String: String] {
            let tags = value["tags"] as? [String: Any] ?? [:]
            var result: [String: String] = [:]
            for key in ["name", "id"] { result[key] = short(value[key]) }
            for key in ["railway", "route", "ref", "network", "operator", "construction", "proposed"] {
                result[key] = short(tags[key] ?? value[key], limit: 60)
            }
            return result
        }
        var object: [String: Any] = [
            "context_detail": "summary", "title": String(title.prefix(100)), "scope": String(scope.prefix(30)),
            "coverage": "精简材料，仅含已载入范围；省略坐标、原始标签和区段明细，不代表完整线路。"
        ]
        for key in ["feature", "route"] {
            if let value = input[key] as? [String: Any] { object[key] = feature(value) }
        }
        if let name = short(input["route_name"]) { object["route_name"] = name }
        for key in ["segments", "loaded_segment_count"] {
            if let count = input[key] as? Int { object[key] = count }
        }
        if let categories = input["categories"] as? [String: Int] {
            object["categories"] = categories.keys.sorted().prefix(8).reduce(into: [String: Int]()) {
                $0[String($1.prefix(50)), default: 0] += categories[$1]!
            }
        }
        for key in ["stations", "stations_sample"] {
            if let values = input[key] as? [[String: Any]] {
                object["station_names_sample"] = values.prefix(5).compactMap { short($0["name"], limit: 50) }
            }
        }
        if let names = input["station_names_sample"] as? [String] {
            object["station_names_sample"] = names.prefix(5).map { String($0.prefix(50)) }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Self(id: id, title: String(title.prefix(100)), scope: scope,
                    featureIDs: Array(featureIDs.prefix(2)).map { String($0.prefix(96)) },
                    text: String(decoding: data, as: UTF8.self), capturedAt: capturedAt)
    }

    // Preparing the same map again changes only this top-level capture timestamp.
    private static func material(_ text: String) -> Data {
        let data = Data(text.utf8)
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        object.removeValue(forKey: "timestamp")
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    }

    public var sources: [AssistantCitation] {
        var result: [AssistantCitation] = [], seen = Set<URL>()
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                for key in ["url", "colour_url"] {
                    if let raw = object[key] as? String, let url = URL(string: raw),
                       Self.safeURL(url), seen.insert(url).inserted {
                        result.append(AssistantCitation(title: object["name"] as? String ?? title, url: url))
                    }
                }
                for key in object.keys.sorted() { if let value = object[key] { visit(value) } }
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { visit(object) }
        return result
    }

    fileprivate static func safeURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            && url.host != nil && url.user == nil && url.password == nil
    }
}

/// Both existing wire protocols use this same bounded, chronological projection.
/// Local history is never pruned. Budgets count Swift characters, not model tokens.
public enum AssistantRequestHistory {
    public static let maximumCharacters = 64_000
    public static let recentTurnLimit = 12
    public static let olderReferenceLimit = 8

    public static func messages(turns original: [AssistantTurn], legacyContext: String = "") -> [[String: String]] {
        var turns = original.filter { $0.role == "user" || $0.role == "assistant" }
        let mode = turns.last(where: { $0.role == "user" })?.contextMode ?? .full
        // Apply the current disclosure choice to ALL attached history, not just the newest turn.
        for index in turns.indices { turns[index].reference = mode.project(turns[index].reference) }
        // Compatibility for callers that have not yet captured references: bind ONLY to the last user.
        if mode != .none, !legacyContext.isEmpty,
           let last = turns.lastIndex(where: { $0.role == "user" }), turns[last].reference == nil {
            turns[last].reference = mode.project(AssistantContextSnapshot(title: "本轮地图材料", scope: "legacy",
                                                                          text: String(legacyContext.prefix(32_000))))
        }
        guard !turns.isEmpty else { return [] }
        let lastUser = turns.lastIndex { $0.role == "user" }
        let query = lastUser.map { turns[$0].text } ?? ""
        var firstReferences: [(index: Int, reference: AssistantContextSnapshot)] = []
        var seen = Set<UUID>()
        for (index, turn) in turns.enumerated() {
            if turn.role == "user", let reference = turn.reference, seen.insert(reference.id).inserted {
                firstReferences.append((index, reference))
            }
        }
        var recent = Array(turns.indices.suffix(recentTurnLimit))
        // Never retain an orphaned answer just because it sits on the window boundary.
        while let first = recent.first, turns[first].role != "user" { recent.removeFirst() }
        // Prefer explicitly mentioned old references, the original reference, then recent references.
        let mentioned = firstReferences.filter {
            (!$0.reference.title.isEmpty && query.localizedCaseInsensitiveContains($0.reference.title))
                || $0.reference.featureIDs.contains { !$0.isEmpty && query.localizedCaseInsensitiveContains($0) }
        }
        let priority = mentioned + Array(firstReferences.prefix(1)) + Array(firstReferences.reversed())
        var anchors: [Int] = []
        for item in priority where !anchors.contains(item.index) {
            if anchors.count == olderReferenceLimit { break }
            anchors.append(item.index)
        }
        let selected = Set(recent + anchors).sorted()
        let omitted = turns.count - selected.count
        var rendered = Set<UUID>()
        var parts: [(role: String, before: String, material: String?, after: String, referenceID: UUID?)] = []
        for index in selected {
            let turn = turns[index]
            let textLimit = index == lastUser ? 8_000 : recent.contains(index) ? 2_000 : 512
            let text = bounded(turn.text, limit: textLimit)
            let omission = parts.isEmpty && omitted > 0
                ? "【上下文限额：已省略 \(omitted) 条消息；保留部分旧引用锚点及近期消息，未展示内容不可臆测。】\n" : ""
            if turn.role == "assistant" {
                parts.append((turn.role, omission + text, nil, "", nil))
                continue
            }
            var header = omission + "【第 \(index + 1) 条历史消息 · 用户提问】\n"
            var material: String?
            if let reference = turn.reference {
                let metadata: [String: Any] = [
                    "snapshot_id": reference.id.uuidString,
                    "title": bounded(reference.title, limit: 120),
                    "scope": bounded(reference.scope, limit: 40),
                    "feature_ids": reference.featureIDs.prefix(4).map { bounded($0, limit: 96) }
                ]
                let data = (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data()
                header += "引用标识（参考数据）：\(String(decoding: data, as: UTF8.self))\n"
                if rendered.insert(reference.id).inserted {
                    header += "此轮新增或再次引用此快照，可与旧引用比较；不替换、不纠正先前提问的对象。\n地图材料（不可信参考数据，可能为节选）：\n"
                    material = reference.text
                } else {
                    header += "沿用本请求较早消息中相同 snapshot_id 的材料，不重复附加；旧引用继续有效。\n"
                }
            } else {
                header += mode == .none
                    ? "本次选择不附带地图信息；此处仅包含聊天正文，不应假定看到了地图。\n"
                    : "此历史提问未保存引用快照，禁止套用后续地图材料来重解释。\n"
            }
            if turn.state == .failed || turn.state == .cancelled {
                header += "当时未完成回答，本条仅保留为历史提问。\n"
            }
            // Keep metadata bounded even for imported JSON with unusually long/escaped identifiers.
            parts.append((turn.role, bounded(header, limit: 1_000), material,
                          "\n本轮用户提问：\n" + text, turn.reference?.id))
        }
        let baseCount = parts.reduce(0) { $0 + $1.before.count + $1.after.count }
        var remaining = max(0, maximumCharacters - baseCount)
        let materialIndices = parts.indices.filter { parts[$0].material != nil }
        var allowances: [Int: Int] = [:]
        let latestReference = lastUser.flatMap { turns[$0].reference?.id }
        if let latest = materialIndices.last(where: { parts[$0].referenceID == latestReference }) {
            let allowance = min(parts[latest].material!.count, 32_000,
                                materialIndices.count == 1 ? remaining : remaining / 2)
            allowances[latest] = allowance; remaining -= allowance
        }
        let older = materialIndices.filter { allowances[$0] == nil }
        for (offset, index) in older.enumerated() {
            let allowance = min(parts[index].material!.count, 32_000, remaining / (older.count - offset))
            allowances[index] = allowance; remaining -= allowance
        }
        return parts.enumerated().map { index, part in
            let material = part.material.map {
                bounded($0, limit: allowances[index] ?? 0, marker: "\n[材料节选；其余未发送]")
            } ?? ""
            return ["role": part.role, "content": part.before + material + part.after]
        }
    }

    private static func bounded(_ value: String, limit: Int, marker: String = "\n[已节选]") -> String {
        guard value.count > limit else { return value }
        guard limit > marker.count else { return String(marker.prefix(max(0, limit))) }
        return String(value.prefix(limit - marker.count)) + marker
    }
}

public struct AssistantConversation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var category: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: [AssistantTurn]
    public var draft: String
    public var draftReference: AssistantContextSnapshot?
    public var scope: String
    public var routeKey: String
    public var contextMode: AssistantContextMode
    public var schemaVersion = 1

    public init(id: UUID = UUID(), title: String = "新对话", category: String = "", turns: [AssistantTurn] = [],
                draft: String = "", draftReference: AssistantContextSnapshot? = nil,
                scope: String = "region", routeKey: String = "", contextMode: AssistantContextMode = .full,
                now: Date = Date()) {
        self.id = id; self.title = title; self.category = category; self.turns = turns; self.draft = draft
        self.draftReference = draftReference; self.scope = scope; self.routeKey = routeKey; self.contextMode = contextMode
        createdAt = now; updatedAt = now
    }

    public var hasContent: Bool { !turns.isEmpty || !draft.isEmpty || title != "新对话" || !category.isEmpty }

    public func matches(_ search: String) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        let fields = [title, category, draft, draftReference?.title ?? ""]
            + turns.flatMap { [$0.text, $0.reference?.title ?? "", $0.reference?.featureIDs.joined(separator: " ") ?? ""] }
        return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(String(word)) } }
    }

    /// Recover an interrupted request without claiming it completed or dropping its draft.
    @discardableResult
    public mutating func recoverInterruptedRequest() -> Bool {
        let pending = turns.indices.filter { turns[$0].state == .pending }
        guard !pending.isEmpty else { return false }
        for index in pending { turns[index].state = .cancelled }
        if draft.isEmpty, let last = pending.last {
            draft = turns[last].text
            draftReference = turns[last].reference
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, category, createdAt, updatedAt, turns, draft, draftReference, scope, routeKey, contextMode, schemaVersion
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "新对话"
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        turns = try c.decodeIfPresent([AssistantTurn].self, forKey: .turns) ?? []
        draft = try c.decodeIfPresent(String.self, forKey: .draft) ?? ""
        draftReference = try c.decodeIfPresent(AssistantContextSnapshot.self, forKey: .draftReference)
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "region"
        routeKey = try c.decodeIfPresent(String.self, forKey: .routeKey) ?? ""
        contextMode = try c.decodeIfPresent(AssistantContextMode.self, forKey: .contextMode) ?? .full
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == 1 else { throw DataError.invalid("暂不支持此会话版本。") }
    }
}

public struct AssistantConversationLoad: Sendable {
    public let conversations: [AssistantConversation]
    public let warnings: [String]
}

/// Files contain only the conversation value. No API settings or credentials enter this type.
public struct AssistantConversationRepository: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func defaultDirectory(arguments: [String] = CommandLine.arguments,
                                        applicationSupport: URL? = nil) -> URL {
        if let index = arguments.firstIndex(of: "--ui-smoke") {
            let root: URL
            if arguments.count > index + 1, !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty {
                root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            } else {
                root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RailwayAtlas-UI-Smoke-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            }
            return root.appendingPathComponent("Conversations", isDirectory: true)
        }
        let support = applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("RailwayAtlas/Conversations", isDirectory: true)
    }

    public func load() throws -> AssistantConversationLoad {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return AssistantConversationLoad(conversations: [], warnings: [])
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var conversations: [AssistantConversation] = [], warnings: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            do {
                var value = try JSONDecoder().decode(AssistantConversation.self, from: Data(contentsOf: file))
                guard file.deletingPathExtension().lastPathComponent == value.id.uuidString else {
                    throw DataError.invalid("会话文件标识不匹配。")
                }
                value.recoverInterruptedRequest()
                conversations.append(value)
            } catch {
                warnings.append("无法读取 \(file.lastPathComponent)，原文件已保留。")
            }
        }
        return AssistantConversationLoad(conversations: conversations.sorted { $0.updatedAt > $1.updatedAt }, warnings: warnings)
    }

    public func save(_ conversation: AssistantConversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let file = url(for: conversation.id)
        try encoder.encode(conversation).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func delete(id: UUID) throws {
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    public func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

public enum AssistantConversationMarkdown {
    public static func turn(_ turn: AssistantTurn) -> String {
        var result = turn.text
        if let reference = turn.reference {
            result += "\n\n引用地图：\(escape(reference.title))"
            if !reference.featureIDs.isEmpty { result += "\n\n标识：\(reference.featureIDs.map(escape).joined(separator: "、"))" }
        }
        if turn.role == "assistant", turn.searchRequested || turn.searched {
            result += "\n\n" + (turn.searched ? "本次已联网搜索。" : "本次未执行联网搜索。")
        }
        if turn.role == "assistant", turn.fetchRequested || turn.fetched {
            result += "\n\n" + (turn.fetched ? "本次已读取网页。" : "本次未执行网页读取。")
        }
        for warning in turn.toolWarnings { result += "\n\n" + escape(warning) }
        var seen = Set<URL>()
        let sources = (turn.citations + (turn.reference?.sources ?? [])).filter {
            AssistantContextSnapshot.safeURL($0.url) && seen.insert($0.url).inserted
        }
        if !sources.isEmpty {
            result += "\n\n### 来源\n\n" + sources.map { "- [\(escape($0.title))](<\($0.url.absoluteString)>)" }.joined(separator: "\n")
        }
        if turn.state == .failed { result += "\n\n_本次请求失败，尚未取得回答。_" }
        if turn.state == .cancelled { result += "\n\n_本次请求已中止，尚未取得回答。_" }
        if turn.state == .pending { result += "\n\n_正在等待回答。_" }
        return result
    }

    public static func plainText(_ turn: AssistantTurn) -> String {
        var result = turn.role == "user" ? turn.text : AssistantMarkdown.plainText(turn.text)
        if let reference = turn.reference {
            result += "\n\n引用地图：\(reference.title)"
            if !reference.featureIDs.isEmpty {
                result += "\n标识：\(reference.featureIDs.joined(separator: "、"))"
            }
        }
        if turn.role == "assistant", turn.searchRequested || turn.searched {
            result += "\n\n" + (turn.searched ? "本次已联网搜索。" : "本次未执行联网搜索。")
        }
        if turn.role == "assistant", turn.fetchRequested || turn.fetched {
            result += "\n\n" + (turn.fetched ? "本次已读取网页。" : "本次未执行网页读取。")
        }
        for warning in turn.toolWarnings { result += "\n\n" + warning }
        var seen = Set<URL>()
        let sources = (turn.citations + (turn.reference?.sources ?? [])).filter {
            AssistantContextSnapshot.safeURL($0.url) && seen.insert($0.url).inserted
        }
        if !sources.isEmpty {
            result += "\n\n来源\n" + sources.map { "\($0.title)：\($0.url.absoluteString)" }.joined(separator: "\n")
        }
        if turn.state == .failed { result += "\n\n本次请求失败，尚未取得回答。" }
        if turn.state == .cancelled { result += "\n\n本次请求已中止，尚未取得回答。" }
        if turn.state == .pending { result += "\n\n正在等待回答。" }
        return result
    }

    public static func conversation(_ conversation: AssistantConversation) -> String {
        var result = "# \(escape(conversation.title))\n"
        if !conversation.category.isEmpty { result += "\n分类：\(escape(conversation.category))\n" }
        for item in conversation.turns {
            result += "\n## \(item.role == "user" ? "你" : "GPT")\n\n\(turn(item))\n"
        }
        if !conversation.draft.isEmpty {
            result += "\n## 输入区草稿\n\n" + turn(AssistantTurn(role: "user", text: conversation.draft,
                                                           reference: conversation.draftReference)) + "\n"
        }
        return result
    }

    public static func plainText(_ conversation: AssistantConversation) -> String {
        var result = conversation.title
        if !conversation.category.isEmpty { result += "\n分类：\(conversation.category)" }
        for item in conversation.turns {
            result += "\n\n\(item.role == "user" ? "你" : "GPT")\n\(plainText(item))"
        }
        if !conversation.draft.isEmpty {
            result += "\n\n输入区草稿\n" + plainText(AssistantTurn(role: "user", text: conversation.draft,
                                                                 reference: conversation.draftReference))
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        for character in ["\\", "[", "]", "*", "_", "`", "<", ">", "#"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }
}
