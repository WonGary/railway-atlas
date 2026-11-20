import Combine
import Foundation
import RailwayCore
import Security
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AtlasKeychain {
    private static let service = "app.railwayatlas.assistant"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func read(_ account: String) throws -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data else { throw DataError.invalid("无法读取 GPT 钥匙串凭据。") }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String, account: String) throws {
        guard !key.contains("\n"), !key.contains("\r") else { throw DataError.invalid("API key 不应包含换行。") }
        let query = query(account), attributes = [kSecValueData as String: Data(key.utf8)]
        if key.isEmpty { SecItemDelete(query as CFDictionary); return }
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw DataError.invalid("无法保存 GPT 钥匙串凭据。") }
    }
    static func assistantKey(for settings: AssistantSettings) throws -> String {
        let scoped = try read(settings.credentialAccount())
        if !scoped.isEmpty { return scoped }
        // Only GPT may read a credential saved before provider-specific accounts.
        // Claude never falls back to GPT, even when both use the same gateway.
        guard settings.provider == .gpt else { return "" }
        let base = try settings.url().absoluteString.dropLast(settings.requestProtocol.suffix.count)
        for suffix in [settings.requestProtocol.suffix, AssistantProtocol.responses.suffix, AssistantProtocol.chat.suffix] {
            let legacy = try read(String(base) + suffix)
            if !legacy.isEmpty { return legacy }
        }
        return ""
    }
    static func removeAssistantKey(for settings: AssistantSettings) throws {
        try save("", account: settings.credentialAccount())
        if settings.provider == .gpt {
            let base = String(try settings.credentialAccount().dropFirst("gpt:".count))
            for apiProtocol in [AssistantProtocol.responses, .chat] {
                try save("", account: base + apiProtocol.suffix)
            }
        }
    }
}

enum AssistantScope: String, CaseIterable, Identifiable {
    case feature, region, route
    var id: String { rawValue }
    var title: String { self == .feature ? "所选要素" : self == .route ? "整条线路" : "当前地区" }
}

struct AssistantRouteChoice: Identifiable, Sendable {
    let id: String
    let name: String
    let route: RailRoute?
    let lines: [RailLine]
}

@MainActor
final class AssistantStore: ObservableObject {
    typealias ReplyRequest = @MainActor (AssistantSettings, [AssistantTurn]) async throws -> AssistantReply
    @Published var settings = AssistantSettings()
    @Published private(set) var recentModels: [String] = []
    @Published var scope: AssistantScope = .region
    @Published private(set) var contextMode: AssistantContextMode = .full
    @Published var routeKey = ""
    @Published var turns: [AssistantTurn] = [] { didSet { autosave() } }
    @Published var question = "" { didSet { if question != oldValue { scheduleDraftSave() } } }
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var context = ""
    @Published private(set) var contextTitle = ""
    @Published private(set) var reference: AssistantContextSnapshot?
    @Published private(set) var conversations: [AssistantConversation] = []
    @Published private(set) var current = AssistantConversation()
    @Published private(set) var persistenceError: String?
    @Published private(set) var historyWarnings: [String] = []
    @Published var height = 650.0
    let repository: AssistantConversationRepository
    private let requestReply: ReplyRequest
    private var work: Task<Void, Never>?
    private var requestID = UUID()
    private var pendingTurnID: UUID?
    private var restoring = false
    private var draftSave: Task<Void, Never>?
    private var draftSaveGeneration = UUID()
    private var needsPersistence = false
    private var lifecycleSubscriptions = Set<AnyCancellable>()
    private static let recentModelsKey = "railway.gpt.recentModels"
    init(repository: AssistantConversationRepository? = nil, notificationCenter: NotificationCenter = .default,
         requestReply: ReplyRequest? = nil) {
        self.repository = repository ?? AssistantConversationRepository(directory: AssistantConversationRepository.defaultDirectory())
        self.requestReply = requestReply ?? { settings, turns in
            let key = try AtlasKeychain.assistantKey(for: settings)
            try Task.checkCancellation()
            return try await AtlasAssistantClient.send(settings: settings, key: key, context: "", turns: turns)
        }
        if !CommandLine.arguments.contains("--ui-smoke"),
           let data = UserDefaults.standard.data(forKey: "railway.gpt.settings"),
           let saved = try? JSONDecoder().decode(AssistantSettings.self, from: data) { settings = saved }
        recentModels = CommandLine.arguments.contains("--ui-smoke") ? [] : Self.loadRecentModels()
        rememberModel(settings.model)
        do {
            let loaded = try self.repository.load()
            conversations = loaded.conversations; historyWarnings = loaded.warnings
            if let latest = conversations.first { apply(latest) }
        } catch {
            persistenceError = "无法载入本地会话，原文件未修改：\(error.localizedDescription)"
        }
        observeLifecycle(notificationCenter)
    }
    func save(_ value: AssistantSettings, newKey: String) throws {
        try value.validate()
        let account = try value.credentialAccount()
        if !newKey.isEmpty { try AtlasKeychain.save(newKey, account: account) }
        settings = value
        persistSettings()
        rememberModel(value.selectedModel)
    }
    func save(_ value: AssistantSettings, keys: [AssistantProvider: String]) throws {
        try value.validate()
        guard !keys.values.contains(where: { $0.contains("\n") || $0.contains("\r") }) else {
            throw DataError.invalid("API key 不应包含换行。")
        }
        for (provider, key) in keys where !key.isEmpty {
            try AtlasKeychain.save(key, account: value.selecting(provider).credentialAccount())
        }
        try save(value, newKey: "")
    }
    func selectProvider(_ provider: AssistantProvider) {
        guard !busy else { return }
        settings.provider = provider
        persistSettings()
    }
    func selectModel(_ model: AssistantModel) {
        guard !busy else { return }
        settings.provider = model.provider
        selectModel(model.name)
    }
    func setPresentation(_ value: AssistantPresentation, map: RailwayMapStore) {
        settings.presentation = value
        persistSettings()
        if value == .window {
            if map.inspectorPane == .assistant { map.inspectorPane = .feature }
        } else {
            map.inspectorLayout = value == .sidebar ? .docked : .floating
            map.inspectorPane = .assistant
            map.inspectorVisible = true
        }
    }
    func show(map: RailwayMapStore) {
        if settings.presentation != .window { setPresentation(settings.presentation, map: map) }
    }
    private func persistSettings() {
        guard !CommandLine.arguments.contains("--ui-smoke") else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "railway.gpt.settings")
        }
    }

    /// Select a previously used model without opening the settings sheet.
    /// Endpoint, protocol, key and conversation history remain unchanged.
    func selectModel(_ rawModel: String) {
        guard !busy else { return }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.selectedModel = String(model.prefix(180))
        persistSettings()
        if !settings.selectedModel.isEmpty { rememberModel(settings.selectedModel) }
    }

    private static func loadRecentModels() -> [String] {
        let values = UserDefaults.standard.stringArray(forKey: recentModelsKey) ?? []
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: []) { result, value in
                if !result.contains(value) { result.append(value) }
            }
    }

    private func rememberModel(_ rawModel: String) {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        recentModels.removeAll { $0 == model }
        recentModels.insert(String(model.prefix(180)), at: 0)
        recentModels = Array(recentModels.prefix(8))
        if !CommandLine.arguments.contains("--ui-smoke") {
            UserDefaults.standard.set(recentModels, forKey: Self.recentModelsKey)
        }
    }
    /// Compatibility for old callers: a reset now starts a saved, separate conversation.
    func reset() { _ = newConversation() }

    var conversationMarkdown: String { AssistantConversationMarkdown.conversation(snapshot()) }
    var conversationPlainText: String { AssistantConversationMarkdown.plainText(snapshot()) }
    var sendingReference: AssistantContextSnapshot? { contextMode.project(reference) }
    var sendingContext: String { sendingReference?.text ?? "" }
    var canSend: Bool {
        !busy && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (contextMode == .none || reference?.text.isEmpty == false)
    }

    func setContextMode(_ value: AssistantContextMode) {
        guard !busy, contextMode != value else { return }
        contextMode = value
        persistCurrent()
    }

    private func snapshot() -> AssistantConversation {
        var value = current
        value.turns = turns; value.draft = question; value.draftReference = reference
        value.scope = scope.rawValue; value.routeKey = routeKey
        value.contextMode = contextMode
        value.updatedAt = Date()
        return value
    }

    private func autosave() {
        if !restoring { persistCurrent() }
    }

    private func scheduleDraftSave() {
        guard !restoring else { return }
        needsPersistence = true
        cancelDraftSave()
        let generation = draftSaveGeneration, conversationID = current.id
        draftSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled, self.draftSaveGeneration == generation,
                  self.current.id == conversationID else { return }
            self.draftSave = nil
            self.flushPendingDraft()
        }
    }

    private func cancelDraftSave() {
        draftSave?.cancel(); draftSave = nil
        draftSaveGeneration = UUID()
    }

    /// Synchronous on purpose: termination/backgrounding must not defer the final write.
    /// Also callable from an App-level onReceive hook, even while a reply is in flight.
    @discardableResult
    func flushPendingDraft() -> Bool {
        guard !restoring, needsPersistence else { return true }
        return persistCurrent()
    }

    private func observeLifecycle(_ notificationCenter: NotificationCenter) {
        #if os(macOS)
        let notifications = [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification]
        #else
        let notifications = [UIApplication.willTerminateNotification, UIApplication.willResignActiveNotification,
                             UIApplication.didEnterBackgroundNotification]
        #endif
        // These app lifecycle notifications arrive on the main thread. Do not enqueue a Task here:
        // the process can terminate before that task runs. The store observes even when GPT is hidden.
        for name in notifications {
            notificationCenter.publisher(for: name)
                .sink { [weak self] _ in self?.flushPendingDraft() }
                .store(in: &lifecycleSubscriptions)
        }
    }

    @discardableResult
    func persistCurrent() -> Bool {
        guard !restoring else { return true }
        cancelDraftSave()
        needsPersistence = true
        let value = snapshot()
        current = value
        do {
            try repository.save(value)
            remember(value); persistenceError = nil
            needsPersistence = false
            return true
        } catch {
            persistenceError = "本地会话尚未保存：\(error.localizedDescription) 当前内容仍在内存中，请重试保存。"
            return false
        }
    }

    private func remember(_ value: AssistantConversation) {
        conversations.removeAll { $0.id == value.id }
        conversations.append(value)
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private func apply(_ value: AssistantConversation) {
        cancelDraftSave()
        needsPersistence = false
        restoring = true
        current = value; turns = value.turns; question = value.draft
        scope = AssistantScope(rawValue: value.scope) ?? .region; routeKey = value.routeKey
        contextMode = value.contextMode
        reference = value.draftReference
        context = reference?.text ?? ""; contextTitle = reference?.title ?? "使用当前地图添加引用"
        error = nil
        restoring = false
    }

    @discardableResult
    func newConversation() -> Bool {
        guard !busy, persistCurrent() else { return false }
        let value = AssistantConversation(draftReference: reference, scope: scope.rawValue, routeKey: routeKey,
                                          contextMode: contextMode)
        do {
            try repository.save(value)
            apply(value); remember(value); persistenceError = nil
            return true
        } catch {
            persistenceError = "无法新建会话：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func openConversation(id: UUID) -> Bool {
        guard !busy else { return false }
        if id == current.id { return flushPendingDraft() }
        guard persistCurrent(), var value = conversations.first(where: { $0.id == id }) else { return false }
        value.updatedAt = Date()
        do {
            try repository.save(value)
            apply(value); remember(value); persistenceError = nil
            return true
        } catch {
            persistenceError = "无法打开会话：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func updateConversation(id: UUID, title: String, category: String) -> Bool {
        guard !busy else { return false }
        guard var value = id == current.id ? snapshot() : conversations.first(where: { $0.id == id }) else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        value.title = String(title.prefix(120))
        value.category = String(category.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        value.updatedAt = Date()
        if id == current.id {
            cancelDraftSave()
            needsPersistence = true
        }
        do {
            try repository.save(value)
            if id == current.id { current = value; needsPersistence = false }
            remember(value); persistenceError = nil
            return true
        } catch {
            persistenceError = "无法保存名称或分类：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteConversation(id: UUID) -> Bool {
        guard !busy, persistCurrent() else { return false }
        do {
            try repository.delete(id: id)
            conversations.removeAll { $0.id == id }
            if current.id == id { apply(conversations.first ?? AssistantConversation()) }
            persistenceError = nil
            return true
        } catch {
            persistenceError = "无法删除会话：\(error.localizedDescription)"
            return false
        }
    }

    func focus(map: RailwayMapStore, scope: AssistantScope) {
        guard !busy else { return }
        self.scope = scope
        prepare(map: map)
    }
    func cancel() {
        guard busy else { return }
        requestID = UUID(); work?.cancel(); work = nil; busy = false
        if let index = turns.firstIndex(where: { $0.id == pendingTurnID }) {
            restoring = true; turns[index].state = .cancelled; restoring = false
        }
        pendingTurnID = nil
        error = "已停止本次请求；问题、引用和历史已保留，可编辑后重新发送。"
        persistCurrent()
    }
    func send() {
        let rawQuestion = question
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let mode = contextMode
        var reference = sendingReference
        if mode == .summary, let compact = reference {
            // A compact attachment is its own material version; never alias its full snapshot UUID.
            reference = turns.reversed().compactMap(\.reference).first {
                $0.matches(title: compact.title, scope: compact.scope, featureIDs: compact.featureIDs, text: compact.text)
            } ?? AssistantContextSnapshot(title: compact.title, scope: compact.scope,
                                          featureIDs: compact.featureIDs, text: compact.text, capturedAt: compact.capturedAt)
        }
        let settings = settings
        restoring = true
        // Retrying an unchanged failed/cancelled question keeps its original turn and reference.
        if let last = turns.indices.last, turns[last].role == "user",
           [.failed, .cancelled].contains(turns[last].state),
           turns[last].text == question, turns[last].reference?.id == reference?.id,
           turns[last].contextMode == mode {
            turns[last].state = .pending
        } else {
            turns.append(AssistantTurn(role: "user", text: question, reference: reference, state: .pending,
                                       contextMode: mode))
        }
        if current.title == "新对话" { current.title = String(question.prefix(48)) }
        let userID = turns.last!.id
        restoring = false
        // Durably save the pending question before reading credentials or making a request.
        guard persistCurrent() else {
            restoring = true; turns[turns.count - 1].state = .failed; restoring = false
            return
        }
        let pending = turns
        let id = UUID()
        requestID = id; pendingTurnID = userID
        busy = true; error = nil
        work = Task {
            defer { if requestID == id { busy = false; work = nil; pendingTurnID = nil } }
            do {
                try Task.checkCancellation()
                guard requestID == id else { return }
                let reply = try await requestReply(settings, pending)
                guard !Task.isCancelled, requestID == id else { return }
                restoring = true
                if let index = turns.firstIndex(where: { $0.id == userID }) { turns[index].state = .complete }
                turns.append(AssistantTurn(role: "assistant", text: reply.text, citations: reply.citations,
                                           searchRequested: settings.searchEnabled, searched: reply.searched,
                                           reference: reference, model: settings.selectedModel, contextMode: mode,
                                           fetchRequested: settings.fetchEnabled, fetched: reply.fetched,
                                           toolWarnings: reply.toolWarnings))
                // Marked text may not yet have reached the binding. Never clear
                // a draft while an input method still owns an unfinished word.
                let clearDraft = self.question == rawQuestion && !Self.hasMarkedText
                if clearDraft { self.question = "" }
                restoring = false
                if !persistCurrent(), clearDraft {
                    restoring = true; self.question = rawQuestion; restoring = false
                }
            } catch {
                guard requestID == id else { return }
                restoring = true
                if let index = turns.firstIndex(where: { $0.id == userID }) {
                    turns[index].state = Task.isCancelled ? .cancelled : .failed
                }
                restoring = false
                self.error = Task.isCancelled ? "本次请求已中止，问题与引用已保留。" : error.localizedDescription
                persistCurrent()
            }
        }
    }

    private static var hasMarkedText: Bool {
        #if os(macOS)
        // A reply can arrive after the app loses key-window status while its
        // field editor still holds marked text. Preserve that background draft.
        NSApp.windows.contains { ($0.firstResponder as? NSTextView)?.hasMarkedText() == true }
        #else
        false
        #endif
    }
    func prepare(map: RailwayMapStore) {
        guard !busy, contextMode != .none else { return }
        var featureIDs: [String] = []
        var object: [String: Any] = ["scope": scope.title, "coverage": "仅包含已载入数据；OSM 标签可能缺失或过时",
                                     "coordinate_system": "WGS84", "source": map.activeProviders,
                                     "timestamp": ISO8601DateFormatter().string(from: Date())]
        func feature(_ item: RailwaySelection) -> [String: Any] {
            var result: [String: Any] = ["id": item.id, "name": item.name,
                "latitude": item.coordinate.latitude, "longitude": item.coordinate.longitude,
                "tags": item.tags]
            if let reference = item.osmReference { result["url"] = "https://www.openstreetmap.org/" + reference }
            return result
        }
        switch scope {
        case .feature:
            guard let item = map.selection else { clearReference("请先点选线路或车站"); return }
            contextTitle = item.name
            featureIDs = [item.id]
            if let osm = item.osmReference, osm != item.id { featureIDs.append(osm) }
            object["feature"] = feature(item)
        case .route:
            guard let choice = map.assistantRoutes.first(where: { $0.id == routeKey }) else {
                clearReference("请选择已载入线路"); return
            }
            contextTitle = choice.name
            featureIDs = [choice.id]
            if let route = choice.route {
                if route.id != choice.id { featureIDs.append(route.id) }
                object["route"] = ["id": route.id, "name": route.name, "tags": route.tags,
                                   "colour_source": route.colorSourceName, "colour_url": route.colorSourceURL.absoluteString]
            } else {
                object["route_name"] = choice.name
                object["grouping"] = "已载入的同名、同编号、同运营网络和公司区段；不保证完整线路"
            }
            let lines = choice.lines
            let stations = map.activeStations.filter { ($0.routes ?? []).contains { $0.visibilityKey == routeKey } }
            object["segments"] = lines.count
            object["segments_sample"] = lines.prefix(30).map { feature(RailwayMapStore.item($0)) }
            object["stations"] = stations.prefix(60).map { feature(RailwayMapStore.item($0)) }
        case .region:
            contextTitle = "当前视野"
            let bounds = map.viewportBounds
            featureIDs = ["bounds:\(bounds.south),\(bounds.west),\(bounds.north),\(bounds.east)"]
            object["bounds"] = ["south": bounds.south, "north": bounds.north, "west": bounds.west, "east": bounds.east]
            let features = map.assistantFeatures(in: bounds), lines = features.lines
            object["loaded_segment_count"] = lines.count
            object["categories"] = Dictionary(grouping: lines, by: { $0.category.title }).mapValues(\.count)
            object["railways_sample"] = lines.prefix(30).map { feature(RailwayMapStore.item($0)) }
            object["stations_sample"] = features.stations.prefix(30)
                .map { feature(RailwayMapStore.item($0)) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            // Preserve a valid, immutable local JSON snapshot. Only the request projection is truncated.
            context = String(decoding: data, as: UTF8.self)
            let previous = ([reference].compactMap { $0 } + turns.reversed().compactMap(\.reference)).first {
                $0.matches(title: contextTitle, scope: scope.rawValue, featureIDs: featureIDs, text: context)
            }
            reference = previous ?? AssistantContextSnapshot(title: contextTitle, scope: scope.rawValue,
                                                             featureIDs: featureIDs, text: context)
            context = reference!.text
            persistCurrent()
        } else {
            clearReference("无法生成地图材料，请重新选择")
        }
    }

    private func clearReference(_ title: String) {
        context = ""; contextTitle = title; reference = nil
        persistCurrent()
    }
}
