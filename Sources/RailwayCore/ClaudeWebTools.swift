import Foundation

/// Anthropic server tools run at the configured Messages service. The app never
/// executes model-provided client tools or fetches model-provided URLs itself.
enum ClaudeWebTools {
    static let maximumContinuations = 3
    static let maximumToolUses = 5

    static func definitions(_ settings: ClaudeAssistantSettings) -> [[String: Any]] {
        var tools: [[String: Any]] = []
        if settings.webSearch {
            tools.append(["type": "web_search_20250305", "name": "web_search", "max_uses": maximumToolUses])
        }
        if settings.webFetch {
            tools.append(["type": "web_fetch_20250910", "name": "web_fetch", "max_uses": maximumToolUses,
                          "max_content_tokens": 12_000, "citations": ["enabled": true]])
        }
        return tools
    }

    static func continuation(_ initial: URLRequest, content: [[String: Any]]) throws -> URLRequest {
        guard let data = initial.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var messages = body["messages"] as? [[String: Any]] else {
            throw DataError.invalid("无法恢复 Claude 工具请求。")
        }
        // Preserve every block, including opaque search content and signatures.
        // Each resumed response continues this same assistant turn.
        messages.append(["role": "assistant", "content": content])
        body["messages"] = messages
        var next = initial
        next.httpBody = try JSONSerialization.data(withJSONObject: body)
        return next
    }

    static func reply(_ object: [String: Any]) throws -> AssistantReply {
        let blocks = object["content"] as? [[String: Any]] ?? []
        if blocks.contains(where: { $0["type"] as? String == "tool_use" })
            || object["stop_reason"] as? String == "tool_use" {
            throw DataError.invalid("Claude 输出未完成：服务返回了需要本地执行的工具调用；本应用支持 Messages 服务端的搜索和网页读取，请核对服务商兼容性。")
        }
        if let reason = object["stop_reason"] as? String,
           ["max_tokens", "model_context_window_exceeded", "pause_turn"].contains(reason) {
            throw DataError.invalid("Claude 输出未完成（\(reason)），请提高输出上限或缩小问题。")
        }
        var calls: [String: String] = [:]
        for block in blocks where block["type"] as? String == "server_tool_use" {
            if let id = block["id"] as? String, let name = block["name"] as? String { calls[id] = name }
        }
        var searched = false, fetched = false
        var warnings: [String] = []
        var citations: [AssistantCitation] = []
        func add(_ source: AssistantCitation) -> Int {
            if let index = citations.firstIndex(where: { $0.url == source.url }) { return index + 1 }
            citations.append(source)
            return citations.count
        }
        var documents: [AssistantCitation?] = []
        for block in blocks {
            let type = block["type"] as? String
            guard type == "web_search_tool_result" || type == "web_fetch_tool_result" else { continue }
            let tool = type == "web_search_tool_result" ? "web_search" : "web_fetch"
            let label = tool == "web_search" ? "联网搜索" : "网页读取"
            if let error = block["content"] as? [String: Any],
               let errorType = error["type"] as? String, errorType.hasSuffix("_error") {
                let message = warning(label: label, code: error["error_code"] as? String)
                if !warnings.contains(message) { warnings.append(message) }
                continue
            }
            guard let id = block["tool_use_id"] as? String, calls[id] == tool else { continue }
            if tool == "web_search", let results = block["content"] as? [[String: Any]] {
                searched = true
                for result in results {
                    if let source = citation(url: result["url"], title: result["title"]) { _ = add(source) }
                }
            } else if tool == "web_fetch", let result = block["content"] as? [String: Any],
                      result["type"] as? String == "web_fetch_result",
                      let document = result["content"] as? [String: Any], document["type"] as? String == "document" {
                fetched = true
                // Retain a slot for invalid URLs so document indices never shift.
                documents.append(citation(url: result["url"], title: document["title"]))
            }
        }
        var paragraphs: [String] = []
        for block in blocks where block["type"] as? String == "text" {
            guard var text = block["text"] as? String else { continue }
            var used = Set<URL>()
            for annotation in block["citations"] as? [[String: Any]] ?? [] {
                let type = annotation["type"] as? String
                let source: AssistantCitation?
                if type == "web_search_result_location" {
                    source = citation(url: annotation["url"], title: annotation["title"])
                } else if ["char_location", "page_location", "content_block_location"].contains(type ?? ""),
                          let index = annotation["document_index"] as? Int, documents.indices.contains(index) {
                    source = documents[index]
                } else { source = nil }
                if let source, used.insert(source.url).inserted {
                    let number = add(source)
                    text += " [\(number)](<\(source.url.absoluteString)>)"
                }
            }
            if !text.isEmpty { paragraphs.append(text) }
        }
        // Also expose successfully read pages when the model omits a citation.
        for document in documents.compactMap({ $0 }) { _ = add(document) }
        let text = paragraphs.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !warnings.isEmpty { throw DataError.invalid(warnings.joined(separator: "\n")) }
            throw DataError.invalid("Claude 没有返回可显示的回答，请核对接口、模型或输出上限。")
        }
        return AssistantReply(text: text, citations: citations, searched: searched,
                              fetched: fetched, toolWarnings: warnings)
    }

    private static func citation(url raw: Any?, title: Any?) -> AssistantCitation? {
        guard let raw = raw as? String, !raw.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }),
              let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        let name = (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AssistantCitation(title: name.isEmpty ? host : name, url: url)
    }

    private static func warning(label: String, code: String?) -> String {
        let detail: String
        switch code {
        case "max_uses_exceeded": detail = "达到本次工具使用上限"
        case "too_many_requests": detail = "服务限流，请稍后重试"
        case "unavailable": detail = "服务暂不可用"
        case "invalid_input": detail = "服务不接受本次工具参数"
        case "query_too_long": detail = "搜索词过长"
        case "url_not_allowed": detail = "服务不允许读取此网址"
        case "url_not_accessible": detail = "网页无法访问"
        case "unsupported_content_type": detail = "网页内容类型不受支持"
        case "too_many_redirects": detail = "网页跳转次数过多"
        case "internal_error": detail = "服务内部错误"
        default: detail = "工具未成功完成，请检查服务商支持情况"
        }
        return "\(label)失败：\(detail)。"
    }
}
