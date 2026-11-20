#if os(macOS)
import AppKit
import Foundation
import RailwayCore
import SwiftUI

/// Hook flag into RailwayMapStore.start()'s offline flags and OnlineUIValidation.
/// Full Store + real SwiftUI views; local replies only, never Keychain or external requests.
@MainActor
enum AssistantUIValidation {
    static let flag = "--v020-assistant-check"

    static func run(store: RailwayMapStore, window: NSWindow?, directory: URL) async throws {
        guard CommandLine.arguments.contains("--ui-smoke"), store.mapMode == .offline else {
            throw DataError.invalid("Assistant QA requires --ui-smoke <directory> and offline map startup")
        }
        let evidence = directory.appendingPathComponent("assistant-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let repository = AssistantConversationRepository(directory: evidence.appendingPathComponent("Conversations"))
        let report = directory.appendingPathComponent("assistant-ui.txt")
        var notes = ["RUNNING 完整 AssistantStore 本地验证", "证据目录：\(evidence.path)"]
        func writeReport() throws { try Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic) }
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw DataError.invalid("FAIL " + label) }
            notes.append("PASS " + label)
        }
        try writeReport()
        let selection = store.selection, pane = store.inspectorPane, visible = store.inspectorVisible, scale = store.uiScale
        defer {
            store.selection = selection; store.inspectorPane = pane; store.inspectorVisible = visible; store.uiScale = scale
            window?.makeKeyAndOrderFront(nil)
        }
        do {
            let items = store.activeStations.map { RailwayMapStore.item($0) }
                .filter { !$0.name.isEmpty && !$0.name.hasPrefix("未命名") && $0.osmReference != nil }
                .sorted { $0.id < $1.id }
            guard let a = items.first, let b = items.first(where: { $0.id != a.id && $0.name != a.name }) else {
                throw DataError.invalid("Assistant QA needs two distinct named stations in the loaded map")
            }
            let assistant = AssistantStore(repository: repository, notificationCenter: NotificationCenter())
            var references: [AssistantContextSnapshot] = []
            for (index, item) in [a, b].enumerated() {
                store.selection = item
                if index == 0 { assistant.focus(map: store, scope: .feature) } else { assistant.prepare(map: store) }
                guard let reference = assistant.reference else { throw DataError.invalid("Missing prepared reference") }
                try check(reference.title == item.name && reference.featureIDs.contains(item.id), "引用 \(index + 1)：\(item.name) · \(item.id)")
                references.append(reference)
                assistant.turns += [
                    AssistantTurn(role: "user", text: "介绍这个车站。", reference: reference),
                    AssistantTurn(role: "assistant", text: "**本地模拟回答 \(index + 1)**\n\n已保留此站材料，可与前次引用比较。",
                                  citations: reference.sources, reference: reference, model: "本地验证")
                ]
            }
            let expected = assistant.turns, originalID = assistant.current.id
            let draft = "比较 \(a.name) 与 \(b.name)，保留两次引用。"
            assistant.question = draft
            try check(assistant.flushPendingDraft() && assistant.updateConversation(id: originalID, title: "双站引用对比", category: "城市轨道"),
                      "完整 Store 保存两轮回答、草稿、重命名和分类")
            try check(assistant.newConversation(), "新建独立会话")
            let disposableID = assistant.current.id
            assistant.question = "切换前尚未等待去抖的另一份草稿"
            try check(assistant.openConversation(id: originalID), "打开原会话并 flush 离开会话的草稿")
            store.selection = a // Current map intentionally differs from the saved B draft reference.
            let restored = AssistantStore(repository: repository, notificationCenter: NotificationCenter())
            try check(restored.current.id == originalID && restored.turns == expected && restored.question == draft
                      && restored.reference == references[1] && references[0].id != references[1].id
                      && restored.current.title == "双站引用对比" && restored.current.category == "城市轨道"
                      && restored.conversations.count == 2
                      && restored.conversations.first(where: { $0.id == disposableID })?.draft == "切换前尚未等待去抖的另一份草稿"
                      && restored.persistenceError == nil && restored.historyWarnings.isEmpty,
                      "重新初始化完整 Store：原引用、标题、分类及两个草稿均恢复")
            restored.settings = AssistantSettings(); restored.settings.model = "本地验证"
            store.uiScale = 1
            let preview = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 960, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
            preview.isReleasedWhenClosed = false; preview.appearance = NSAppearance(named: .aqua)
            defer { preview.close() }
            func capture<V: View>(_ content: V, name: String, size: CGSize) async throws {
                let host = NSHostingView(rootView: AtlasInterface(scale: 1) { content }
                    .environmentObject(store).environmentObject(restored)
                    .environment(\.colorScheme, .light).tint(.railwayAccent)
                    .background(Color.white).allowsHitTesting(false))
                preview.contentView = host; preview.setContentSize(size); preview.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                _ = try RetinaUIValidation.capture(host, name: name, directory: evidence)
            }
            try await capture(AtlasAssistantView(), name: "assistant-window", size: CGSize(width: 720, height: 820))
            try await capture(AssistantHistoryView(), name: "assistant-history", size: CGSize(width: 650, height: 620))
            try check(restored.reference == references[1] && restored.turns == expected && restored.question == draft,
                      "当前地图切回 A 后挂载实际助手/历史视图，Picker 未覆盖 B 草稿引用或旧材料")
            try Data(restored.conversationMarkdown.utf8).write(to: evidence.appendingPathComponent("conversation.md"), options: .atomic)
            try check(restored.deleteConversation(id: disposableID), "完整 Store 删除另一个测试会话")
            let reopened = AssistantStore(repository: repository, notificationCenter: NotificationCenter())
            try check(reopened.conversations.map(\.id) == [originalID] && reopened.turns == expected
                      && reopened.question == draft && reopened.reference == references[1]
                      && !FileManager.default.fileExists(atPath: repository.url(for: disposableID).path),
                      "删除落盘；再次初始化后剩余历史、引用和草稿完整")
            try await AssistantSubmissionValidation.run(map: store, directory: evidence)
            notes.append("PASS 实际视图及发送／停止动作与本地回复：原生输入框、未确认输入、重复发送、下一条草稿、失败重试、迟到回复回归。")
            notes.append("CAPTURE assistant-window.png：GPT 作为独立 macOS 窗口渲染；右侧栏只保留要素信息。")
            notes.append("CAPTURE assistant-history.png：实际历史视图，删除前两个会话；conversation.md：含来源的整会话 Markdown。")
            notes.append("截图需人工复核正文、复制按钮、输入区和历史菜单；未模拟按钮点击/删除确认，未调用网络或读取 Key。")
            notes.append("PASS 完整 Store 集成流程完成")
            notes[0] = "PASS 完整 AssistantStore 本地验证"
            try writeReport()
        } catch {
            notes.append("FAIL \(error.localizedDescription)"); try? writeReport()
            throw error
        }
    }
}
@MainActor
enum AssistantPersonalizationValidation {
    static func run(map: RailwayMapStore, directory: URL) async throws {
        let report = directory.appendingPathComponent("assistant-personalization.txt")
        var notes = ["RUNNING assistant personalization; local fixtures only"]
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL " + label) }
            notes.append("PASS " + label)
            try Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic)
        }
        let assistant = AssistantStore(repository: .init(directory: directory.appendingPathComponent("PersonalizationConversations")),
                                       notificationCenter: NotificationCenter())
        let config = ConfigurationStore(url: directory.appendingPathComponent("personalization-config.json"))
        config.bind(map: map, assistant: assistant)
        assistant.settings = AssistantSettings()
        let answer = """
        ## 铁路比较

        第一段：北京地铁，保留**粗体（中文标点）**和中文。

        第二段：上海地铁，可以跨段选择。

        - 可选择列表内容
        - 复制局部文字

        *斜体*、~~删除线~~与[**来源链接**](https://example.test/rail)

        ```swift
        let name = "铁道漫游"
        // **保留代码标记**
        ```

        | 线路 | 状态 |
        | --- | --- |
        | 地铁 | 规划 |
        | 铁路 | **在建（示例）**状态 |
        """
        assistant.turns = [.init(role: "assistant", text: answer, model: "本地模拟")]
        assistant.question = "尚未发送的草稿"
        let turnIDs = assistant.turns.map(\.id)
        let preview = NSWindow(contentRect: CGRect(x: 80, y: 100, width: 720, height: 820),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        preview.appearance = NSAppearance(named: .aqua)
        defer { preview.close() }
        func present<V: View>(_ view: V, size: CGSize) async throws -> NSView {
            let host = NSHostingView(rootView: AtlasInterface(scale: 1) { view }
                .environmentObject(map).environmentObject(assistant).environmentObject(config)
                .environment(\.colorScheme, .light).background(Color.white))
            preview.contentView = host; preview.setContentSize(size); preview.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            return host
        }
        func textViews(_ view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView, text.accessibilityIdentifier() == "assistant-selectable-text" { return [text] }
            return view.subviews.flatMap(textViews)
        }
        do {
            let host = try await present(AssistantMarkdownView(answer).padding(20), size: CGSize(width: 560, height: 650))
            guard let text = textViews(host).first, let layout = text.layoutManager, let container = text.textContainer else {
                throw DataError.invalid("No native reply text document")
            }
            try check(text.isSelectable && !text.isEditable && text.string.contains("第一段") && text.string.contains("第二段"),
                      "one selectable native text document contains headings, paragraphs, lists and code")
            let rendered = text.attributedString()
            func bold(_ value: NSAttributedString, _ needle: String) -> Bool {
                let range = (value.string as NSString).range(of: needle)
                guard range.location != NSNotFound,
                      let font = value.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return false }
                return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
            }
            try check(bold(rendered, "粗体（中文标点）") && bold(rendered, "来源链接")
                && !rendered.string.contains("**粗体") && rendered.string.contains("**保留代码标记**"),
                      "native rendering styles Chinese punctuation and link labels while preserving code markers")
            let tableRange = (rendered.string as NSString).range(of: "在建（示例）")
            try check((rendered.attribute(.paragraphStyle, at: tableRange.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.first is NSTextTableBlock, "table cells use native bordered layout in the continuous text document")
            func glyphRect(_ needle: String) -> NSRect {
                let chars = (text.string as NSString).range(of: needle)
                let glyphs = layout.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
                return layout.boundingRect(forGlyphRange: glyphs, in: container)
            }
            let leftCell = glyphRect("线路"), rightCell = glyphRect("状态")
            try check(rightCell.minX > leftCell.maxX && abs(rightCell.minY - leftCell.minY) < 2,
                      "initial table layout places both header cells on the same row")
            preview.makeFirstResponder(text)
            let first = (text.string as NSString).range(of: "第一段")
            let second = (text.string as NSString).range(of: "上海地铁")
            let range = NSRange(location: first.location, length: NSMaxRange(second) - first.location)
            func point(_ character: Int) -> NSPoint {
                let glyph = layout.glyphIndexForCharacter(at: character)
                let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                return text.convert(NSPoint(x: rect.minX + text.textContainerOrigin.x + 0.5,
                                            y: rect.midY + text.textContainerOrigin.y), to: nil)
            }
            let start = point(range.location), end = point(NSMaxRange(range))
            func event(_ kind: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: preview.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseDragged, end), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, end), atStart: false)
            text.mouseDown(with: event(.leftMouseDown, start))
            let selected = (text.string as NSString).substring(with: text.selectedRange())
            try check(selected.contains("第一段") && selected.contains("第二段") && selected.count < text.string.count,
                      "native mouse drag selects a partial reply across paragraph boundaries")
            let board = NSPasteboard(name: .init("RailwayAssistantQA-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            board.declareTypes([.string, .rtf, .html], owner: nil)
            let wrote = text.writeSelection(to: board, types: [.string, .rtf, .html])
            let copied = board.string(forType: .string)
            notes.append("COPY fixture wrote=\(wrote), selected=\(selected.debugDescription), copied=\(String(reflecting: copied))")
            try check(wrote && copied == selected,
                      "native Copy exports exactly the selected text to an isolated pasteboard")
            guard let selectedRTF = board.data(forType: .rtf) else { throw DataError.invalid("No selection RTF") }
            let selectedRich = try NSAttributedString(data: selectedRTF, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                     documentAttributes: nil)
            try check(selectedRich.string == selected && bold(selectedRich, "粗体（中文标点）")
                && board.data(forType: .html) != nil,
                      "selection exports RTF and HTML with the same text and retained bold style")
            let selectedRange = text.selectedRange()
            assistant.question += "，继续输入"
            try await Task.sleep(for: .milliseconds(200))
            try check(text.selectedRange() == selectedRange, "unrelated draft update leaves native reply selection intact")
            _ = try RetinaUIValidation.capture(host, name: "selected-reply", directory: directory)
            try check(AssistantClipboard.writeFormatted(rendered, to: board), "whole-answer formatted copy exports plain text, RTF and HTML")
            guard let fullRTF = board.data(forType: .rtf), let html = board.data(forType: .html) else {
                throw DataError.invalid("Missing rich document representations")
            }
            let roundtrip = try NSAttributedString(data: fullRTF, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                   documentAttributes: nil)
            try check(roundtrip.string.trimmingCharacters(in: .whitespacesAndNewlines) == rendered.string.trimmingCharacters(in: .whitespacesAndNewlines)
                && bold(roundtrip, "粗体（中文标点）") && bold(roundtrip, "在建（示例）")
                && String(decoding: html, as: UTF8.self).contains("<table"),
                      "formatted paste preserves Chinese text, emphasis and table structure through RTF roundtrip")
            for model in assistant.settings.models {
                assistant.selectModel(model)
                try check(assistant.settings.selectedModel == model.name && assistant.settings.provider == model.provider,
                          "model selection routes \(model.name) to \(model.provider.title)")
            }
            assistant.busy = true
            assistant.selectModel(AssistantModel.defaults[0])
            try check(assistant.settings.selectedModel == "claude-fable-5-1", "in-flight model selection is ignored")
            assistant.busy = false
            assistant.settings.claude.webSearch = true
            assistant.settings.claude.webFetch = true
            config.saveNow()
            let webSettings = try AtlasConfiguration.decode(Data(contentsOf: config.url))
            try check(webSettings.assistant.claude.webSearch && webSettings.assistant.claude.webFetch
                      && !webSettings.assistant.webSearch, "Claude web toggles persist separately from GPT search")
            for position in AssistantPresentation.allCases {
                assistant.setPresentation(position, map: map)
                config.saveNow()
                let saved = try AtlasConfiguration.decode(Data(contentsOf: config.url))
                try check(saved.assistant.presentation == position && saved.assistant.provider == .claude
                    && assistant.turns.map(\.id) == turnIDs && assistant.question.contains("尚未发送"),
                          "\(position.rawValue) retains model, history and draft, and persists layout")
                if position != .window {
                    try check(map.inspectorVisible && map.inspectorPane == .assistant
                        && map.inspectorLayout == (position == .sidebar ? .docked : .floating),
                              "\(position.rawValue) uses the requested right panel layout")
                    let view = try await present(AtlasInspectorView(), size: CGSize(width: 380, height: 820))
                    try check(!textViews(view).isEmpty, "embedded assistant renders selectable reply")
                    _ = try RetinaUIValidation.capture(view, name: "assistant-" + position.rawValue, directory: directory)
                    if position == .sidebar {
                        let narrow = try await present(AtlasInspectorView(), size: CGSize(width: 200, height: 760))
                        try check(textViews(narrow).contains { $0.bounds.width > 0 && $0.bounds.width <= 200 },
                                  "200pt sidebar keeps the native answer document within available width")
                        _ = try RetinaUIValidation.capture(narrow, name: "assistant-sidebar-200", directory: directory)
                        func segments(_ view: NSView) -> [NSSegmentedControl] {
                            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segments)
                        }
                        let tabs = segments(narrow).first { control in
                            (0..<control.segmentCount).contains { control.label(forSegment: $0) == "要素" }
                        }
                        try check(tabs?.segmentCount == 2 && tabs?.label(forSegment: 1) == "问答",
                                  "200pt inspector has two side-by-side native tabs instead of a popup")
                        if let tabs {
                            tabs.selectedSegment = 0
                            _ = tabs.sendAction(tabs.action, to: tabs.target)
                            try await Task.sleep(for: .milliseconds(150))
                            try check(map.inspectorPane == .feature, "clicking feature tab switches the inspector content")
                            tabs.selectedSegment = 1
                            _ = tabs.sendAction(tabs.action, to: tabs.target)
                            try await Task.sleep(for: .milliseconds(150))
                            try check(map.inspectorPane == .assistant, "clicking assistant tab restores conversation")
                        }
                    }
                } else {
                    try check(map.inspectorPane == .feature, "independent window restores feature inspector")
                    let view = try await present(AtlasAssistantView(), size: CGSize(width: 720, height: 820))
                    _ = try RetinaUIValidation.capture(view, name: "assistant-window", directory: directory)
                }
            }
            let settings = try await present(AtlasSettingsView(initialPage: .gpt), size: CGSize(width: 680, height: 820))
            _ = try RetinaUIValidation.capture(settings, name: "assistant-settings", directory: directory)
            for mode in [AssistantContextMode.none, .summary] {
                assistant.setContextMode(mode)
                let view = try await present(AtlasAssistantView(embedded: true), size: CGSize(width: 380, height: 820))
                _ = try RetinaUIValidation.capture(view, name: "assistant-context-" + mode.rawValue, directory: directory)
            }
            assistant.setContextMode(.none)
            assistant.turns = [.init(role: "assistant", text: """
                ## 联网资料示例

                **线路信息**来自运营方网页。[1](<https://example.test/rail>)

                这是本地测试回答，用于检查引用、复制和工具状态显示。
                """, citations: [.init(title: "运营方网页（本地示例）", url: URL(string: "https://example.test/rail")!)],
                searchRequested: true, searched: true, model: "Claude · 本地验证",
                fetchRequested: true, fetched: true,
                toolWarnings: ["网页读取失败：另一个测试网页无法访问。"])]
            let webView = try await present(AtlasAssistantView(), size: CGSize(width: 720, height: 820))
            try check(textViews(webView).contains {
                $0.attributedString().string.contains("线路信息")
                && $0.attributedString().length > 0
            }, "Claude web reply renders in the selectable native document")
            _ = try RetinaUIValidation.capture(webView, name: "assistant-claude-web", directory: directory)
            try await AssistantSubmissionValidation.run(map: map, directory: directory)
            notes[0] = "PASS assistant personalization; native mouse selection and isolated Copy; no paid API or Keychain access"
            try Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic)
        } catch {
            notes.append("FAIL \(error.localizedDescription)")
            try? Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic)
            throw error
        }
    }
}
#endif
