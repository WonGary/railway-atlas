#if os(macOS)
import AppKit
import Foundation
import RailwayCore
import SwiftUI

/// Exercises the Send/Stop store actions with the real view and AppKit field editor.
/// The injected reply never reads Keychain, opens a socket or incurs API charges.
@MainActor
enum AssistantSubmissionValidation {
    static func run(map: RailwayMapStore, directory: URL) async throws {
        guard CommandLine.arguments.contains("--ui-smoke") else {
            throw DataError.invalid("Submission QA requires isolated --ui-smoke mode")
        }
        let report = directory.appendingPathComponent("assistant-submission.txt")
        var notes = ["RUNNING native GPT submission / marked text regression"]
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL " + label) }
            notes.append("PASS " + label)
            try Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic)
        }
        try Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic)
        let fixture = ReplyFixture()
        let repository = AssistantConversationRepository(directory: directory.appendingPathComponent("SubmissionConversations"))
        let assistant = AssistantStore(repository: repository, notificationCenter: NotificationCenter(),
                                       requestReply: { settings, turns in try await fixture.send(settings, turns) })
        assistant.focus(map: map, scope: .region)
        assistant.question = "请介绍北京地铁。\n请同时说明在建线路颜色。"
        let rawQuestion = assistant.question
        let preview = NSWindow(contentRect: CGRect(x: 120, y: 100, width: 440, height: 720),
                               styleMask: [.titled], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        preview.title = "GPT 输入法回归 · 本地回复"
        preview.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView:
            AtlasInterface(scale: 1) { AtlasAssistantView(embedded: true) }
                .environmentObject(map).environmentObject(assistant)
                .environment(\.colorScheme, .light)
                .tint(.railwayAccent).background(Color.white))
        preview.contentView = host
        preview.makeKeyAndOrderFront(nil)
        defer {
            assistant.cancel()
            fixture.finish(.failure(CancellationError()))
            preview.close()
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
        }
        func awaitPending() async throws {
            for _ in 0..<30 {
                if fixture.pending != nil { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw DataError.invalid("Request did not reach local reply fixture")
        }
        func awaitIdle() async throws {
            for _ in 0..<30 {
                if !assistant.busy { try await settle(); return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw DataError.invalid("Reply did not release pending state")
        }
        do {
            try await settle()
            let fields = nativeFields(in: host).filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
            guard fields.count == 1, let field = fields.first else {
                throw DataError.invalid("Expected one native question field, got \(fields.count)")
            }
            preview.makeFirstResponder(field)
            try await settle()
            guard let editor = field.currentEditor() as? NSTextView else {
                throw DataError.invalid("Question field has no native field editor")
            }
            func visibleLineRects(_ editor: NSTextView) throws -> [NSRect] {
                guard let layout = editor.layoutManager, let container = editor.textContainer else {
                    throw DataError.invalid("Question editor has no text layout")
                }
                layout.ensureLayout(for: container)
                var rects: [NSRect] = []
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, used, _, _, _ in
                    rects.append(used.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y))
                }
                return rects
            }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.setMarkedText("bei", selectedRange: NSRange(location: 3, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            try check(editor.hasMarkedText(), "native field editor has an unfinished IME composition before Send")
            assistant.send()
            try await awaitPending()
            assistant.send() // Duplicate invocations must not create another turn/request.
            try await settle()
            try check(assistant.busy && fixture.calls.count == 1 && assistant.turns.count == 1,
                      "Send action starts one request; a duplicate submit is ignored")
            try check(field.isEnabled && field.isEditable && field.currentEditor() === editor
                      && editor.window === preview && editor.hasMarkedText(),
                      "busy transition retains the enabled native editor, focus and marked text")
            try check(fixture.calls[0].last?.text == rawQuestion,
                      "submitted question is immutable while marked text is still being composed")
            let composingText = editor.string
            preview.resignKey()
            try check(!preview.isKeyWindow && editor.hasMarkedText(),
                      "unfinished IME composition remains in a background window")
            fixture.finish(.success(try ReplyFixture.reply()))
            try await awaitIdle()
            try check(assistant.turns.count == 2 && assistant.turns.last?.role == "assistant"
                      && assistant.question.hasPrefix(rawQuestion) && editor.string == composingText && editor.hasMarkedText(),
                      "successful reply renders without clearing the background window's still-composing draft")

            preview.makeKeyAndOrderFront(nil)
            editor.insertText("下一轮问题", replacementRange: editor.markedRange())
            try await settle()
            try check(!editor.hasMarkedText() && assistant.question.contains("下一轮问题"),
                      "committing marked text updates the draft after the reply")
            let requestQuestion = assistant.question
            assistant.send()
            try await awaitPending()
            editor.selectAll(nil)
            editor.insertText("继续编辑的下一条草稿", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            try await settle()
            let nextDraft = assistant.question
            fixture.finish(.success(try ReplyFixture.reply()))
            try await awaitIdle()
            try check(nextDraft != requestQuestion && assistant.question == nextDraft
                      && fixture.calls.last?.last?.text == requestQuestion
                      && assistant.turns.count == 4,
                      "typing during a request preserves the next draft and original request")
            let saved = try repository.load().conversations.first { $0.id == assistant.current.id }
            try check(saved?.draft == nextDraft && saved?.turns == assistant.turns,
                      "successful reply and next draft persist together")
            _ = try RetinaUIValidation.capture(host, name: "assistant-submission-success", directory: directory)

            assistant.send()
            try await awaitPending()
            let retryID = assistant.turns.last?.id
            fixture.finish(.failure(DataError.invalid("本地模拟连接失败")))
            try await awaitIdle()
            try check(assistant.question == nextDraft && assistant.turns.last?.state == .failed && assistant.error != nil,
                      "failed request retains question and reference")
            assistant.send()
            try await awaitPending()
            try check(assistant.turns.last?.id == retryID && assistant.turns.last?.state == .pending,
                      "retry reuses the failed question without duplicating history")
            try await settle()
            assistant.cancel()
            let stopped = assistant.turns
            fixture.finish(.success(try ReplyFixture.reply()))
            try await awaitIdle()
            try check(assistant.turns == stopped && assistant.turns.last?.state == .cancelled
                      && assistant.question == nextDraft,
                      "Stop retains the draft; a late reply cannot change cancelled history")

            editor.unmarkText()
            assistant.send()
            try await awaitPending()
            fixture.finish(.success(try ReplyFixture.reply()))
            try await awaitIdle()
            try check(assistant.question.isEmpty && assistant.turns.last?.role == "assistant"
                      && field.isEnabled && nativeFields(in: host).contains(where: { $0 === field }),
                      "ordinary completion clears only an unchanged committed draft and reuses the question field")
            // TextKit layout introspection is done after the IME assertions:
            // accessing layoutManager can change the field editor's text system.
            editor.selectAll(nil)
            editor.insertText(rawQuestion, replacementRange: editor.selectedRange())
            try await settle()
            let twoLines = try visibleLineRects(editor)
            try check(editor.string == rawQuestion && twoLines.count == 2
                      && twoLines.allSatisfy { editor.visibleRect.insetBy(dx: -1, dy: -1).contains($0) },
                      "both lines of the question are laid out and fully visible in the native editor (\(Int(field.bounds.height))pt)")
            _ = try RetinaUIValidation.capture(host, name: "assistant-input-two-lines", directory: directory)
            let longDraft = (1...12).map { "第\($0)行：请说明在建地铁的显示方式，并保留这段长文字用于换行检查。" }.joined(separator: "\n")
            editor.selectAll(nil)
            editor.insertText(longDraft, replacementRange: editor.selectedRange())
            try await settle()
            editor.scrollRangeToVisible(NSRange(location: (editor.string as NSString).length - 1, length: 1))
            try await settle()
            let longLines = try visibleLineRects(editor)
            try check(assistant.question == longDraft && longLines.count > 12
                      && longLines.last.map { editor.visibleRect.intersects($0) } == true
                      && !editor.visibleRect.intersects(longLines[0]) && field.bounds.height < 180,
                      "long input wraps and scrolls to its last line without expanding over the conversation")
            _ = try RetinaUIValidation.capture(host, name: "assistant-input-scroll", directory: directory)
            var bareCalls: [[AssistantTurn]] = []
            let bareRepository = AssistantConversationRepository(directory: directory.appendingPathComponent("NoMapConversations"))
            let bare = AssistantStore(repository: bareRepository, notificationCenter: NotificationCenter(),
                                      requestReply: { _, turns in
                bareCalls.append(turns)
                return try ReplyFixture.reply()
            })
            bare.setContextMode(.none); bare.question = "不选择地图也可以提问"
            try check(bare.reference == nil && bare.context.isEmpty && bare.canSend,
                      "no-material mode enables Send with no map selection or prepared snapshot")
            bare.send()
            bare.setContextMode(.full)
            try check(bare.busy && bare.contextMode == .none, "in-flight disclosure choice is frozen")
            for _ in 0..<30 {
                if !bare.busy { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(!bare.busy && bareCalls.count == 1 && bare.turns.count == 2
                && bare.turns.allSatisfy { $0.reference == nil && $0.contextMode == .none },
                      "no-map question and local reply complete with no captured attachment")
            let restoredBare = AssistantStore(repository: bareRepository, notificationCenter: NotificationCenter())
            try check(restoredBare.contextMode == .none && restoredBare.turns == bare.turns,
                      "reopening the conversation retains no-material mode and history")
            bare.setContextMode(.summary); bare.focus(map: map, scope: .region)
            bare.question = "这次只附少量材料"
            try check(bare.canSend && bare.sendingContext.contains("\"context_detail\":\"summary\"")
                && !bare.sendingContext.contains("\"bounds\""), "summary preview shows the actual compact attachment")
            bare.send()
            for _ in 0..<30 {
                if !bare.busy { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(bareCalls.count == 2 && bare.turns.last?.contextMode == .summary
                && bare.turns.last?.reference?.text == bare.sendingContext
                && bare.turns.last?.reference?.id != bare.reference?.id,
                      "summary submission stores its own compact material version and returns normally")
            notes[0] = "PASS native GPT submission / marked text regression"
            notes.append("Local AppKit marked-text simulation; no external GPT request, Keychain access or input-source change.")
            try Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic)
        } catch {
            notes.append(error.localizedDescription)
            _ = try? RetinaUIValidation.capture(host, name: "assistant-submission-failure", directory: directory)
            try? Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic)
            throw error
        }
    }

    private static func nativeFields(in parent: NSView) -> [NSTextField] {
        (parent as? NSTextField).map { [$0] } ?? parent.subviews.flatMap { nativeFields(in: $0) }
    }

    @MainActor
    private final class ReplyFixture {
        var calls: [[AssistantTurn]] = []
        var pending: CheckedContinuation<AssistantReply, Error>?

        func send(_ settings: AssistantSettings, _ turns: [AssistantTurn]) async throws -> AssistantReply {
            calls.append(turns)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        func finish(_ result: Result<AssistantReply, Error>) {
            let continuation = pending
            pending = nil
            continuation?.resume(with: result)
        }

        static func reply() throws -> AssistantReply {
            try AtlasAssistantClient.reply(Data("""
            {"output":[{"type":"message","content":[{"type":"output_text","text":"## 本地验证回答\\n\\n输入框应保持可编辑。\\n\\n- 已保留引用\\n- 可继续编辑草稿"}]}]}
            """.utf8), apiProtocol: .responses)
        }
    }
}
#endif
