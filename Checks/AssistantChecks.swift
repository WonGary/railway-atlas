import Foundation
import RailwayCore

enum AssistantChecks {
    static func run() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL: " + label) }
            count += 1; print("PASS " + label)
        }
        func rejects(_ label: String, _ work: () throws -> Void) throws {
            do { try work() } catch { count += 1; print("PASS " + label); return }
            throw DataError.invalid("FAIL: " + label)
        }
        var settings = AssistantSettings()
        settings.model = "fixture-model"
        settings.endpoint = "https://example.test/v1"
        let request = try AtlasAssistantClient.request(settings: settings, key: "fixture-key", context: #"{"name":"测试"}"#,
                                                       turns: [AssistantTurn(role: "user", text: "有哪些车站？")])
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try check(request.url?.path == "/v1/responses" && body["model"] as? String == "fixture-model",
                  "GPT custom base URL normalizes to chosen Responses endpoint")
        try check(body["store"] as? Bool == false && body["stream"] as? Bool == false
                  && body["tools"] == nil
                  && String(decoding: request.httpBody!, as: UTF8.self).contains("有哪些车站"),
                  "GPT sends explicit context and question with storage disabled")
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key"
                  && !String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("fixture-key"),
                  "GPT key is in authorization only, absent from serializable settings")
        settings.endpoint = "http://evil.example/v1/responses"
        try rejects("nonlocal cleartext GPT endpoint rejected") { _ = try settings.url() }
        settings.endpoint = "https://example.test/v1/responses?key=hidden"
        try rejects("GPT URL embedded credentials rejected") { _ = try settings.url() }
        settings.endpoint = "http://127.0.0.1:9876/v1/responses"
        try check(try settings.url().scheme == "http", "local model endpoint supported")
        settings.apiProtocol = .chat; settings.endpoint = "https://example.test/v1"
        let chat = try AtlasAssistantClient.request(settings: settings, key: "fixture", context: "OSM",
                                                   turns: [AssistantTurn(role: "user", text: "explain")])
        let chatBody = try JSONSerialization.jsonObject(with: chat.httpBody!) as! [String: Any]
        try check(chat.url?.path == "/v1/chat/completions" && (chatBody["messages"] as? [[String: String]])?.count == 2,
                  "Chat Completions preserves system guidance and pairs context with its question")
        let response = Data(#"{"status":"completed","error":null,"output":[{"type":"message","content":[{"type":"output_text","text":"测试回答"}]}]}"#.utf8)
        try check(try AtlasAssistantClient.text(response, apiProtocol: .responses) == "测试回答", "Responses output message decoded")
        try check(try AtlasAssistantClient.text(Data(#"{"choices":[{"message":{"content":"chat answer"},"finish_reason":"stop"}]}"#.utf8),
                                               apiProtocol: .chat) == "chat answer", "Chat output message decoded")
        try rejects("incomplete GPT answer never shown as complete") {
            _ = try AtlasAssistantClient.text(Data(#"{"status":"incomplete","output_text":"partial"}"#.utf8), apiProtocol: .responses)
        }
        settings.apiProtocol = .responses
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AssistantFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let actual = try await AtlasAssistantClient.send(settings: settings, key: "fixture", context: "selected line",
                                                         turns: [AssistantTurn(role: "user", text: "question")], session: session)
        try check(actual.text == "经过网络层的测试回答" && !actual.searched,
                  "GPT full request/response path works against local protocol fixture")
        var claude = AssistantSettings()
        claude.provider = .claude
        claude.claude.endpoint = "https://claude-success.test/v1"
        for authentication in [ClaudeAuthentication.apiKey, .bearer] {
            claude.claude.authentication = authentication
            let reply = try await AtlasAssistantClient.send(settings: claude, key: "claude-fixture",
                context: "", turns: [AssistantTurn(role: "user", text: "test")], session: session)
            try check(reply.text == "Claude 本地协议回答" && !reply.searched,
                      "Claude \(authentication.rawValue) completes a Messages request through the local network fixture")
        }
        for (host, expected) in [
            ("claude-forbidden.test", "HTTP 403"), ("claude-missing.test", "HTTP 404"),
            ("claude-html.test", "不是有效 JSON")
        ] {
            claude.claude.endpoint = "https://\(host)/v1"
            do {
                _ = try await AtlasAssistantClient.send(settings: claude, key: "claude-fixture",
                    context: "", turns: [AssistantTurn(role: "user", text: "test")], session: session)
                throw DataError.invalid("Fixture unexpectedly succeeded")
            } catch {
                try check(error.localizedDescription.contains(expected)
                          && error.localizedDescription.contains(host + "/v1/messages"),
                          "Claude \(host) exposes status and the failing Messages address")
            }
        }
        claude.endpoint = "https://gateway.test/tenant/v1/chat/completions"
        claude.apiProtocol = .chat
        let originalClaude = claude.claude.endpoint
        try check(claude.messagesEndpointForGPTGateway?.absoluteString == "https://gateway.test/tenant/v1/messages"
                  && claude.claude.endpoint == originalClaude,
                  "Messages gateway suggestion preserves its prefix without changing the configured Claude endpoint")
        claude.endpoint = "https://api.openai.com/v1"
        try check(claude.messagesEndpointForGPTGateway == nil, "official GPT endpoint has no Claude gateway suggestion")
        claude.claude.authentication = .apiKey
        claude.claude.endpoint = "https://claude-error.test/v1"
        let claudeErrorSession = URLSession(configuration: config)
        do {
            _ = try await AtlasAssistantClient.send(settings: claude, key: "claude-fixture",
                                                    context: "", turns: [AssistantTurn(role: "user", text: "test")],
                                                    session: claudeErrorSession)
            throw DataError.invalid("Claude authentication fixture unexpectedly succeeded")
        } catch {
            try check(error.localizedDescription.contains("HTTP 401")
                      && error.localizedDescription.contains("authentication_error")
                      && error.localizedDescription.contains("请求编号：req-claude-401")
                      && !error.localizedDescription.contains("claude-fixture"),
                      "Claude HTTP authentication errors expose actionable provider detail without the API key")
        }
        claude.claude.endpoint = "https://offline.test/v1"
        do {
            _ = try await AtlasAssistantClient.send(settings: claude, key: "claude-fixture",
                                                    context: "", turns: [AssistantTurn(role: "user", text: "test")],
                                                    session: URLSession(configuration: config))
            throw DataError.invalid("Claude network fixture unexpectedly succeeded")
        } catch {
            try check(error.localizedDescription.contains("无法连接服务")
                      && error.localizedDescription.contains("网络错误"),
                      "Claude network failures explain address/connectivity instead of only saying connection failed")
        }
        settings.webSearch = true
        let searchRequest = try AtlasAssistantClient.request(settings: settings, key: "fixture", context: "OSM",
                                                            turns: [AssistantTurn(role: "user", text: "铁路的最新进展")])
        let searchBody = try JSONSerialization.jsonObject(with: searchRequest.httpBody!) as! [String: Any]
        try check((searchBody["tools"] as? [[String: String]])?.first?["type"] == "web_search"
                  && (searchBody["instructions"] as? String)?.contains("主动搜索") == true,
                  "search toggle includes a real web_search tool and search-aware instructions")
        settings.apiProtocol = .chat
        try rejects("unsupported Chat search fails before any network request") {
            _ = try AtlasAssistantClient.request(settings: settings, key: "fixture", context: "OSM", turns: [])
        }
        let searched = try AtlasAssistantClient.reply(Data("""
        {"status":"completed","output":[
          {"type":"web_search_call","status":"completed"},
          {"type":"message","content":[{"type":"output_text","text":"根据来源的回答",
           "annotations":[
             {"type":"url_citation","url":"https://example.test/rail","title":"运营方"},
             {"type":"url_citation","url":"https://example.test/rail","title":"重复"},
             {"type":"url_citation","url":"javascript:alert(1)","title":"不安全链接"}]}]}]}
        """.utf8), apiProtocol: .responses)
        try check(searched.searched && searched.citations.count == 1
                  && searched.citations[0].title == "运营方", "completed search and unique safe source links are parsed independently of prose")
        let noSearch = try AtlasAssistantClient.reply(Data(#"{"output_text":"我搜索了网页","output":[]}"#.utf8), apiProtocol: .responses)
        try check(!noSearch.searched, "model prose alone cannot set the searched indicator")
        let failedSearch = try AtlasAssistantClient.reply(Data(#"{"output_text":"暂无来源","output":[{"type":"web_search_call","status":"failed"}]}"#.utf8), apiProtocol: .responses)
        try check(!failedSearch.searched, "failed search is never marked as completed")
        let legacy = try JSONDecoder().decode(AssistantSettings.self, from: Data(#"{"model":"legacy","endpoint":"https://example.test/v1","apiProtocol":"responses","maxOutputTokens":4000}"#.utf8))
        try check(!legacy.webSearch && legacy.model == "legacy" && legacy.maxOutputTokens == 4000,
                  "legacy GPT settings retain endpoint/model and default search off")
        settings.apiProtocol = .responses; settings.endpoint = "https://unsupported.test/v1/responses"
        do {
            _ = try await AtlasAssistantClient.send(settings: settings, key: "fixture", context: "OSM", turns: [], session: session)
            throw DataError.invalid("FAIL: unsupported service accepted search")
        } catch {
            try check(error.localizedDescription.contains("未自动降级") && error.localizedDescription.contains("400"),
                      "service search rejection is explicit without silent ordinary-answer retry")
        }
        let markdown = AssistantMarkdown.parse("""
        ## 地铁线路
        **配色**与[来源](https://example.test)

        3. 保留编号
          - 子项

        | 线路 | 字段 |
        | --- | :---: |
        | 2号线 | `a|b` |
        | A\\|B | 值 |

        ```swift
        let tag = "<script>plain text</script>"
        ```
        """)
        try check(markdown.contains(.heading(2, "地铁线路"))
                  && markdown.contains(.item(marker: "3.", text: "保留编号", depth: 0))
                  && markdown.contains(.item(marker: "•", text: "子项", depth: 1)),
                  "reply headings and list numbering/nesting are automatically parsed")
        try check(markdown.contains(.table(headers: ["线路", "字段"], rows: [["2号线", "`a|b`"], ["A\\|B", "值"]])),
                  "Markdown tables preserve inline-code and escaped pipes")
        try check(markdown.contains(.code(language: "swift", text: #"let tag = "<script>plain text</script>""#)),
                  "fenced code is preserved verbatim for rendering and copying")
        try check(AssistantMarkdown.parse("~~~json\n{\"partial\":true}") == [.code(language: "json", text: "{\"partial\":true}")],
                  "unfinished code fence preserves the received content")
        try check(AssistantMarkdown.parse("text | prose\nis not a table") == [.paragraph("text | prose\nis not a table")],
                  "ordinary prose with a pipe is not turned into a table")
        session.invalidateAndCancel()
        try await webTools()
        try personalization()
        try contextAndRendering()
        try conversations()
        print("\(count) GPT protocol checks passed; no paid API calls.")
    }

    static func webTools() async throws {
        var settings = AssistantSettings()
        settings.provider = .claude
        settings.claude.endpoint = "https://claude-tools.test/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL " + label) }
            print("PASS " + label)
        }
        for (search, fetch, expectedTypes) in [
            (true, false, ["web_search_20250305"]),
            (false, true, ["web_fetch_20250910"]),
            (true, true, ["web_search_20250305", "web_fetch_20250910"])
        ] {
            settings.claude.webSearch = search
            settings.claude.webFetch = fetch
            let request = try AtlasAssistantClient.request(settings: settings, key: "claude-fixture", context: "",
                                                           turns: [AssistantTurn(role: "user", text: "查一下")])
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let tools = body["tools"] as? [[String: Any]] ?? []
            try check(tools.compactMap { $0["type"] as? String } == expectedTypes,
                      "Claude Messages request includes exactly the enabled server tools")
            try check((body["system"] as? String)?.contains("web_fetch") == fetch,
                      "Claude tool guidance tracks the fetch toggle")
        }
        settings.claude.webSearch = true
        settings.claude.webFetch = true
        AssistantFixtureProtocol.toolRequests = []
        AssistantFixtureProtocol.toolRequestCount = 0
        let reply = try await AtlasAssistantClient.send(settings: settings, key: "claude-fixture",
            context: "", turns: [AssistantTurn(role: "user", text: "查阅线路资料")], session: session)
        try check(reply.text.contains("[2](<https://example.test/official>)")
                  && reply.searched && reply.fetched && reply.citations.count == 2
                  && reply.citations.map { $0.url.absoluteString } == [
                      "https://search.example.test/rail", "https://example.test/official"
                  ],
                  "Claude search and fetch resume to a final answer with deduplicated, linked citations")
        let requests = AssistantFixtureProtocol.toolRequests
        try check(requests.count == 3, "Claude search and fetch produce three Messages exchanges")
        let firstResume = requests.count > 1 ? (requests[1]["messages"] as? [[String: Any]] ?? []) : []
        let secondResume = requests.count > 2 ? (requests[2]["messages"] as? [[String: Any]] ?? []) : []
        try check(firstResume.contains { $0["role"] as? String == "assistant" },
                  "Claude first continuation sends the assistant search blocks back")
        try check(secondResume.contains { $0["role"] as? String == "assistant" },
                  "Claude second continuation sends the accumulated assistant tool blocks back")
        let resumedBlocks = secondResume.last?["content"] as? [[String: Any]] ?? []
        let originalTools = requests[0]["tools"] as? NSArray
        try check(firstResume.count == 2 && secondResume.count == 2 && resumedBlocks.count == 4
                  && resumedBlocks[1]["type"] as? String == "web_search_tool_result"
                  && resumedBlocks[3]["type"] as? String == "web_fetch_tool_result"
                  && originalTools?.isEqual(requests[2]["tools"] as? NSArray) == true
                  && ((resumedBlocks[1]["content"] as? [[String: Any]])?.first?["encrypted_content"] as? String) == "opaque-search-token",
                  "resuming preserves opaque tool data and definitions in one accumulated assistant turn")
        settings.claude.endpoint = "https://claude-tool-error.test/v1"
        let failure = try await AtlasAssistantClient.send(settings: settings, key: "claude-fixture",
            context: "", turns: [AssistantTurn(role: "user", text: "查阅资料")], session: session)
        try check(!failure.searched && !failure.fetched
                  && failure.toolWarnings == ["联网搜索失败：达到本次工具使用上限。"],
                  "Claude tool failures are reported without claiming successful search")
        for (host, message) in [("claude-tools-unsupported.test", "未自动降级"),
                                ("claude-tools-paused.test", "自动续接上限"),
                                ("claude-tools-empty.test", "返回空内容")] {
            settings.claude.endpoint = "https://\(host)/v1"
            do {
                _ = try await AtlasAssistantClient.send(settings: settings, key: "claude-fixture", context: "",
                    turns: [AssistantTurn(role: "user", text: "问题")], session: session)
                throw DataError.invalid("Unexpected tool fixture success")
            } catch {
                try check(error.localizedDescription.contains(message)
                          && !error.localizedDescription.contains("claude-fixture"),
                          "\(host) stops with an actionable error and no credential disclosure")
            }
        }
        let proseOnly = try AtlasAssistantClient.reply(Data(#"{"content":[{"type":"text","text":"我已经搜索并读取网页"}],"stop_reason":"end_turn"}"#.utf8),
                                                        apiProtocol: .messages)
        try check(!proseOnly.searched && !proseOnly.fetched, "Claude prose alone cannot set search or fetch success")
        let unsafe = try AtlasAssistantClient.reply(Data(#"{"content":[{"type":"text","text":"来源","citations":[{"type":"web_search_result_location","url":"javascript:alert(1)"},{"type":"web_search_result_location","url":"https://user:secret@example.test/"}]}],"stop_reason":"end_turn"}"#.utf8),
                                                    apiProtocol: .messages)
        try check(unsafe.citations.isEmpty && unsafe.text == "来源", "Claude citations reject scripts and embedded credentials")
        let missingBody = try AtlasAssistantClient.reply(Data(#"{"content":[{"type":"server_tool_use","name":"web_fetch","id":"f"},{"type":"web_fetch_tool_result","tool_use_id":"f","content":{"type":"web_fetch_tool_result_error","error_code":"url_not_accessible"}},{"type":"text","text":"网页打不开"}],"stop_reason":"end_turn"}"#.utf8),
                                                         apiProtocol: .messages)
        try check(!missingBody.fetched && missingBody.toolWarnings == ["网页读取失败：网页无法访问。"],
                  "fetch errors are distinct from successful webpage reads")
        let turn = AssistantTurn(role: "assistant", text: reply.text, citations: reply.citations,
            searchRequested: true, searched: reply.searched, fetchRequested: true, fetched: reply.fetched,
            toolWarnings: failure.toolWarnings)
        let savedTurn = try JSONDecoder().decode(AssistantTurn.self, from: JSONEncoder().encode(turn))
        try check(savedTurn == turn && AssistantConversationMarkdown.plainText(savedTurn).contains("本次已读取网页")
                  && AssistantConversationMarkdown.turn(savedTurn).contains("https://example.test/official")
                  && AssistantConversationMarkdown.turn(savedTurn).contains("联网搜索失败"),
                  "history and plain/Markdown exports preserve tool states, warnings and sources")
        let legacy = try JSONDecoder().decode(ClaudeAssistantSettings.self,
            from: Data(#"{"endpoint":"https://legacy.test/v1/messages","model":"legacy-claude"}"#.utf8))
        try check(!legacy.webSearch && !legacy.webFetch && legacy.model == "legacy-claude",
                  "legacy Claude settings keep tools disabled until the user enables them")
        let migrated = try AtlasConfiguration.decode(Data(#"{"assistant":{"webSearch":true,"claude":{"webSearch":true,"webFetch":true,"model":"custom"}}}"#.utf8))
        try check(migrated.assistant.webSearch && migrated.assistant.claude.webSearch && migrated.assistant.claude.webFetch,
                  "configuration persists GPT search and both Claude tools independently")
        let cancelled = Task {
            try Task.checkCancellation()
            return try await AtlasAssistantClient.send(settings: settings, key: "claude-fixture", context: "",
                turns: [AssistantTurn(role: "user", text: "问题")], session: session)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw DataError.invalid("Cancelled tool request completed") }
        catch is CancellationError { print("PASS cancelled Claude tool request stops before continuation") }
    }

    static func contextAndRendering() throws {
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL " + label) }
            print("PASS " + label)
        }
        for source in ["例如**中文（标点）**后续", "这里是**“带引号的粗体”**中文", "这是**中文。**下一句",
                       "**粗体**和*斜体*", "[**中文（标点）**](https://example.test/rail)"] {
            let value = AssistantMarkdown.inline(source)
            try check(!String(value.characters).contains("**")
                && value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
                "inline CJK and standard bold render: \(source)")
        }
        let literal = AssistantMarkdown.inline(#"保留\*\*原样\*\*、`**代码**`和 2 ** 3"#)
        try check(String(literal.characters) == "保留**原样**、**代码**和 2 ** 3"
            && !literal.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
            "escaped stars, code literals and arithmetic are not swallowed as emphasis")
        let mixed = AssistantMarkdown.inline(#"\*\*字面\*\*及**中文（标点）**后续和`**代码**`"#)
        try check(String(mixed.characters) == "**字面**及中文（标点）后续和**代码**",
                  "CJK fallback coexists with escaped delimiters and code in the same paragraph")
        let plain = AssistantConversationMarkdown.plainText(AssistantTurn(role: "assistant", text: """
        ## 标题
        **中文（标点）**后续与*斜体*、[来源](https://example.test/rail)
        ```python
        power = 2 ** 3
        key = "__name__"
        ```
        """))
        try check(plain.contains("中文（标点）后续与斜体") && plain.contains("https://example.test/rail")
                  && plain.contains("power = 2 ** 3") && plain.contains(#"key = "__name__""#)
                  && !plain.contains("##") && !plain.contains("```") && !plain.contains("python"),
                  "plain copy removes presentation syntax while preserving code exactly and keeping source URLs")

        let full = AssistantContextSnapshot(title: "示例线", scope: "route", featureIDs: ["relation/100"],
            text: #"{"route":{"id":"relation/100","name":"示例线","tags":{"operator":"示例运营方","secret_tag":"PRIVATE_TAG"}},"segments":30,"segments_sample":[{"latitude":38.123456,"longitude":116.987654,"tags":{"private":"PRIVATE_SEGMENT"}}],"stations":[{"name":"甲站"},{"name":"乙站"}],"bounds":{"secret":"PRIVATE_BOUNDS"}}"#)
        let compact = full.summarized()
        try check(compact.text.count < 1200 && compact.text.contains("示例运营方")
            && compact.text.contains("甲站") && !compact.text.contains("PRIVATE")
            && !compact.text.contains("latitude") && !compact.text.contains("segments_sample")
            && (try JSONSerialization.jsonObject(with: Data(compact.text.utf8))) is [String: Any],
            "compact material is small valid JSON with named facts but no arbitrary tags, coordinates or segment data")
        try check(compact.summarized() == compact && full.text.contains("PRIVATE_SEGMENT"),
                  "compact projection is stable and leaves the full local snapshot intact")
        let prior = [AssistantTurn(role: "user", text: "先前的问题", reference: full),
                     AssistantTurn(role: "assistant", text: "先前的回答", reference: full)]
        for mode in AssistantContextMode.allCases {
            let turns = prior + [AssistantTurn(role: "user", text: "现在的问题", reference: full, contextMode: mode)]
            for proto in AssistantProtocol.allCases {
                var settings = AssistantSettings()
                if proto == .messages { settings.provider = .claude }
                else { settings.apiProtocol = proto }
                settings.endpoint = "https://fixture.test/v1"
                settings.claude.endpoint = "https://fixture.test/v1"
                let request = try AtlasAssistantClient.request(settings: settings, key: "fixture",
                                                               context: "LEGACY_MATERIAL", turns: turns)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let history = (body[proto == .responses ? "input" : "messages"] as! [[String: String]])
                    .filter { $0["role"] != "system" }.compactMap { $0["content"] }.joined()
                try check(history.contains("先前的问题") && history.contains("先前的回答") && history.contains("现在的问题"),
                          "\(proto.rawValue) \(mode.rawValue) retains chronological conversation text")
                switch mode {
                case .none:
                    try check(!history.contains("示例") && !history.contains("PRIVATE") && !history.contains("snapshot_id")
                        && !history.contains("relation/100") && !history.contains("LEGACY_MATERIAL"),
                        "\(proto.rawValue) none removes new, old and legacy map attachments before transport")
                case .summary:
                    try check(history.contains("示例运营方") && !history.contains("PRIVATE")
                        && !history.contains("38.123456"), "\(proto.rawValue) summary reduces all historical attachments")
                case .full:
                    try check(history.contains("PRIVATE_SEGMENT"), "\(proto.rawValue) full retains the requested map detail")
                }
            }
            let conversation = AssistantConversation(turns: turns, contextMode: mode)
            let reopened = try JSONDecoder().decode(AssistantConversation.self, from: JSONEncoder().encode(conversation))
            try check(reopened == conversation && reopened.turns.last?.contextMode == mode,
                      "\(mode.rawValue) disclosure choice persists per conversation and turn")
        }
        let legacy = try JSONDecoder().decode(AssistantTurn.self, from: Data(#"{"role":"user","text":"旧问题"}"#.utf8))
        try check(legacy.contextMode == .full, "old histories without disclosure mode retain their prior behavior")
    }

    static func personalization() throws {
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL " + label) }
            print("PASS " + label)
        }
        var settings = AssistantSettings()
        try check(settings.models.prefix(6).map(\.name) == ["gpt-6-astra", "gpt-5.6-sol", "gpt-6.1-sol",
            "claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1"], "six requested model IDs preserved exactly")
        let legacy = try AtlasConfiguration.decode(Data(#"{"assistant":{"model":"old-custom","endpoint":"https://gateway.test/v1","webSearch":true}}"#.utf8))
        try check(legacy.assistant.model == "old-custom" && legacy.assistant.webSearch
            && legacy.assistant.provider == .gpt && legacy.assistant.presentation == .window
            && legacy.assistant.models.count >= 6
            && Set(legacy.assistant.models.map(\.name)).isSuperset(of: Set([
                "gpt-6-astra", "gpt-5.6-sol", "gpt-6.1-sol",
                "claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1"
            ])), "old GPT config keeps endpoint, custom model, search and independent-window default")
        for provider in [AssistantProvider.deepseek, .doubao, .custom] {
            var profile = legacy.assistant.selecting(provider)
            if provider == .custom { profile.compatibleProfile.endpoint = "https://api.example.test/proxy/v3" }
            profile.selectedModel = provider == .doubao ? "ep-example" : "my-model"
            let request = try AtlasAssistantClient.request(settings: profile, key: "test-only", context: "",
                turns: [AssistantTurn(role: "user", text: "你好")])
            let fields = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try check(request.url?.path.hasSuffix("/chat/completions") == true && fields["model"] as? String == profile.selectedModel
                && fields["tools"] == nil && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only",
                "\(provider.title) sends the selected chat model without inheriting GPT tools")
            let roundTrip = try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(profile))
            try check(try roundTrip.credentialAccount() == profile.credentialAccount() && roundTrip.selectedModel == profile.selectedModel,
                "\(provider.title) retains its own endpoint, credential scope and model")
        }
        settings.endpoint = "https://gateway.test/v1"
        settings.claude.endpoint = "https://gateway.test/v1"
        let gptAccount = try settings.credentialAccount()
        settings.apiProtocol = .chat
        try check(try settings.credentialAccount() == gptAccount, "GPT credential survives protocol switching on same gateway")
        settings.provider = .claude
        let claudeAccount = try settings.credentialAccount()
        try check(gptAccount != claudeAccount && claudeAccount.hasPrefix("claude:"), "GPT and Claude credential accounts never collide")
        settings.webSearch = true
        let turns = [AssistantTurn(role: "user", text: "甲站"), AssistantTurn(role: "assistant", text: "答复"),
                     AssistantTurn(role: "user", text: "乙站")]
        for auth in ClaudeAuthentication.allCases {
            settings.claude.authentication = auth
            let request = try AtlasAssistantClient.request(settings: settings, key: "claude-fixture", context: "", turns: turns)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try check(request.url?.path == "/v1/messages" && body["model"] as? String == "claude-opus-5-5"
                && body["max_tokens"] as? Int == 3000 && body["system"] is String
                && (body["messages"] as? [[String: String]]) == AssistantRequestHistory.messages(turns: turns)
                && body["tools"] == nil && body["input"] == nil && body["store"] == nil,
                "Claude \(auth.rawValue) uses Messages schema and preserves chronological references without GPT search fields")
            try check(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
                && request.value(forHTTPHeaderField: auth == .apiKey ? "x-api-key" : "Authorization") == (auth == .apiKey ? "claude-fixture" : "Bearer claude-fixture")
                && request.value(forHTTPHeaderField: auth == .apiKey ? "Authorization" : "x-api-key") == nil,
                "Claude \(auth.rawValue) sends only the selected credential header")
        }
        let reply = try AtlasAssistantClient.reply(Data(#"{"type":"message","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"第一段"},{"type":"text","text":"第二段"}],"stop_reason":"end_turn"}"#.utf8), apiProtocol: .messages)
        try check(reply.text == "第一段\n第二段" && !reply.searched, "Claude text blocks combine without exposing thinking blocks or claiming search")
        for reason in ["max_tokens", "pause_turn"] {
            do {
                _ = try AtlasAssistantClient.reply(Data("{\"content\":[{\"type\":\"text\",\"text\":\"partial\"}],\"stop_reason\":\"\(reason)\"}".utf8), apiProtocol: .messages)
                throw DataError.invalid("accepted incomplete Claude \(reason)")
            } catch {
                try check(error.localizedDescription.contains("输出未完成"), "Claude \(reason) is not reported as a completed answer")
            }
        }
        do {
            _ = try AtlasAssistantClient.reply(Data(#"{"content":[{"type":"tool_use","id":"local","name":"computer","input":{}}],"stop_reason":"tool_use"}"#.utf8),
                                               apiProtocol: .messages)
            throw DataError.invalid("accepted a Claude client-side tool call")
        } catch {
            try check(error.localizedDescription.contains("本地执行的工具调用"),
                      "Claude client-side tool calls fail closed with a clear unsupported-tool message")
        }
        settings.models.append(.init(provider: .claude, name: "custom-model", label: "常用", note: "自己的网关"))
        settings.selectedModel = "custom-model"; settings.presentation = .floating
        var config = AtlasConfiguration(); config.assistant = settings
        let reopened = try AtlasConfiguration.decode(config.encoded())
        try check(reopened.assistant.selectedModel == "custom-model" && reopened.assistant.models.last?.note == "自己的网关"
            && reopened.assistant.models.last?.label == "常用" && reopened.assistant.presentation == .floating
            && reopened.assistant.models.last?.provider == .claude, "custom model metadata, provider and window preference survive configuration round trip")
        try check(!String(decoding: try config.encoded(), as: UTF8.self).contains("claude-fixture"),
                  "API secrets never enter serialized model or layout settings")
        for json in [
            #"{"assistant":{"claude":{"endpoint":"http://evil.test/v1"}}}"#,
            #"{"assistant":{"claude":{"apiKey":"secret"}}}"#,
            #"{"assistant":{"claude":{"apiVersion":"bad\nheader"}}}"#,
            #"{"assistant":{"models":[{"id":"00000000-0000-0000-0000-000000000001","provider":"gpt","name":"","label":"","note":""}]}}"#,
            #"{"assistant":{"presentation":"unknown"}}"#
        ] {
            do { _ = try AtlasConfiguration.decode(Data(json.utf8)) }
            catch { print("PASS invalid provider/model configuration rejected"); continue }
            throw DataError.invalid("FAIL invalid assistant config was accepted")
        }
    }

    /// Separate hook for the main check runner; run() already includes these offline regressions.
    static func conversations() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL: " + label) }
            count += 1; print("PASS " + label)
        }
        let old = AssistantContextSnapshot(title: "甲站", scope: "feature", featureIDs: ["node/101"],
                                           text: #"{"feature":{"id":"node/101","name":"甲站","url":"https://www.openstreetmap.org/node/101"},"timestamp":"old"}"#)
        let new = AssistantContextSnapshot(title: "乙线", scope: "route", featureIDs: ["relation/202"],
                                           text: #"{"route":{"id":"relation/202","name":"乙线","url":"https://www.openstreetmap.org/relation/202"},"timestamp":"new"}"#)
        let turns = [
            AssistantTurn(role: "user", text: "甲站在哪里？", reference: old),
            AssistantTurn(role: "assistant", text: "甲站的旧回答"),
            AssistantTurn(role: "user", text: "介绍新增乙线", reference: new),
            AssistantTurn(role: "assistant", text: "乙线的独立回答"),
            AssistantTurn(role: "user", text: "对比甲站和乙线，换乘联系是什么？", reference: new)
        ]
        let projected = AssistantRequestHistory.messages(turns: turns, legacyContext: "不应倒灌的最新地图")
        let contents = projected.compactMap { $0["content"] }
        try check(projected.map { $0["role"]! } == turns.map(\.role)
                  && contents[0].contains(old.text) && contents[0].contains("甲站在哪里")
                  && !contents[0].contains(new.text) && contents[2].contains(new.text)
                  && contents[2].contains("介绍新增乙线") && contents[4].contains("对比甲站和乙线")
                  && !contents.joined().contains("不应倒灌"),
                  "reference A/question A precede answer A and reference B/question B in chronological order")
        try check(contents[2].contains("不替换、不纠正") && contents[4].contains("沿用")
                  && contents.joined().components(separatedBy: new.text).count == 2,
                  "a new feature is additive and repeated identical snapshots are included only once")
        var comparisonHistory = Array(turns.prefix(4))
        for index in 0..<20 {
            comparisonHistory.append(AssistantTurn(role: "user", text: "乙线的补充问题 \(index)", reference: new))
            comparisonHistory.append(AssistantTurn(role: "assistant", text: "乙线的补充回答 \(index)"))
        }
        comparisonHistory.append(turns[4])
        let comparison = AssistantRequestHistory.messages(turns: comparisonHistory)
        let comparisonText = comparison.compactMap { $0["content"] }.joined(separator: "\n")
        try check(comparison.first?["content"]?.contains(old.text) == true
                  && comparisonText.contains(new.text)
                  && comparisonText.range(of: old.text)!.lowerBound < comparisonText.range(of: new.text)!.lowerBound
                  && comparison.last?["content"]?.contains("对比甲站和乙线") == true
                  && comparisonText.components(separatedBy: old.text).count == 2
                  && comparisonText.components(separatedBy: new.text).count == 2
                  && comparisonText.contains("已省略"),
                  "A then B then compare retains both original anchors even after recent-history trimming")
        try check(old.matches(title: old.title, scope: old.scope, featureIDs: old.featureIDs,
                              text: old.text.replacingOccurrences(of: "\"old\"", with: "\"fresh\""))
                  && !old.matches(title: old.title, scope: old.scope, featureIDs: old.featureIDs,
                                  text: old.text.replacingOccurrences(of: "甲站", with: "已改名的甲站")),
                  "capture timestamps alone do not duplicate references, but changed map fields do")
        let changed = AssistantContextSnapshot(title: old.title, scope: old.scope, featureIDs: old.featureIDs,
                                               text: #"{"feature":{"id":"node/101","name":"甲站","operator":"新运营方"}}"#)
        let versions = AssistantRequestHistory.messages(turns: [
            turns[0], turns[1], AssistantTurn(role: "user", text: "现在的运营方呢？", reference: changed)
        ])
        try check(versions[0]["content"]!.contains(old.text) && versions[2]["content"]!.contains(changed.text),
                  "new versions of the same feature preserve the original turn's material")

        var settings = AssistantSettings()
        settings.endpoint = "https://example.test/v1"; settings.model = "fixture"
        func body(_ settings: AssistantSettings) throws -> [String: Any] {
            let request = try AtlasAssistantClient.request(settings: settings, key: "fixture-secret",
                                                           context: "", turns: turns)
            return try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        }
        let responses = try body(settings)
        settings.apiProtocol = .chat
        let chat = try body(settings)
        try check((responses["input"] as? [[String: String]]) == projected
                  && Array((chat["messages"] as! [[String: String]]).dropFirst()) == projected,
                  "Responses and Chat share exactly the same per-turn chronology")
        try check(Set(responses.keys) == Set(["model", "stream", "instructions", "input", "store", "max_output_tokens"])
                  && Set(chat.keys) == Set(["model", "stream", "messages", "max_tokens"]),
                  "local conversation history introduces no API fields or server-side conversation state")
        let legacyID = UUID()
        let legacy = try JSONDecoder().decode(AssistantTurn.self, from: Data("""
        {"id":"\(legacyID.uuidString)","role":"user","text":"旧问题"}
        """.utf8))
        let legacyAnswer = try JSONDecoder().decode(AssistantTurn.self, from: Data("""
        {"role":"assistant","text":"旧回答","citations":[],"searchRequested":true,"searched":false}
        """.utf8))
        try check(legacy.id == legacyID && legacy.reference == nil && legacy.state == .complete
                  && legacy.citations.isEmpty && !legacy.searched && legacyAnswer.searchRequested,
                  "legacy turn JSON decodes with absent snapshot, date, state and search fields")
        let migrated = AssistantRequestHistory.messages(turns: [
            legacy, legacyAnswer, AssistantTurn(role: "user", text: "新问题")
        ], legacyContext: "仅给新问题的地图")
        try check(migrated.count == 3 && !migrated[0]["content"]!.contains("仅给新问题的地图")
                  && migrated[0]["content"]!.contains("未保存引用") && migrated[2]["content"]!.contains("仅给新问题的地图"),
                  "legacy compatibility binds fallback material only to the latest user question")
        let roleFiltered = AssistantRequestHistory.messages(turns: [
            AssistantTurn(role: "system", text: "导入的角色声明"), turns[0]
        ])
        try check(roleFiltered.count == 1 && roleFiltered[0]["role"] == "user",
                  "imported conversation roles cannot create a system message")

        var longHistory: [AssistantTurn] = []
        let large = String(repeating: "参考字段🚆", count: 20_000)
        for index in 0..<45 {
            let snapshot = AssistantContextSnapshot(title: "要素\(index)", scope: "feature",
                featureIDs: ["node/\(index)"], text: "快照\(index)的关键字段\n" + large)
            longHistory += [
                AssistantTurn(role: "user", text: "问题\(index)\n" + large, reference: snapshot),
                AssistantTurn(role: "assistant", text: "回答\(index)\n" + large)
            ]
        }
        longHistory.append(AssistantTurn(role: "user", text: "请比较要素0、要素17与当前要素44",
                                         reference: longHistory[88].reference))
        let originalCount = longHistory.count
        let bounded = AssistantRequestHistory.messages(turns: longHistory)
        let boundedText = bounded.compactMap { $0["content"] }.joined()
        try check(bounded.reduce(0, { $0 + ($1["content"]?.count ?? 0) }) <= AssistantRequestHistory.maximumCharacters
                  && bounded.count <= AssistantRequestHistory.recentTurnLimit + AssistantRequestHistory.olderReferenceLimit,
                  "large histories stay within explicit message and character budgets")
        try check(bounded.first?["content"]?.contains("快照0的关键字段") == true
                  && boundedText.contains("快照17的关键字段") && boundedText.contains("快照44的关键字段")
                  && bounded.last?["content"]?.contains("请比较要素0、要素17与当前要素44") == true
                  && boundedText.contains("已省略") && boundedText.contains("材料节选")
                  && longHistory.count == originalCount && longHistory[0].reference!.text.count > 32_000,
                  "important old reference anchors and latest question survive without pruning saved history")

        let source = AssistantCitation(title: "运营方 [资料]", url: URL(string: "https://example.test/rail?a=1&b=2")!)
        let answer = AssistantTurn(role: "assistant", text: "## 回答\n\n```swift\nlet route = \"甲站\"\n```",
                                   citations: [source, source], searchRequested: true, searched: true, reference: old)
        let copied = AssistantConversationMarkdown.turn(answer)
        try check(copied.hasPrefix(answer.text) && copied.contains("[运营方 \\[资料\\]]")
                  && copied.contains("https://example.test/rail?a=1&b=2")
                  && copied.contains("https://www.openstreetmap.org/node/101")
                  && copied.components(separatedBy: source.url.absoluteString).count == 2,
                  "answer copy preserves full Markdown, deduplicated search sources and map links")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RailwayAssistantChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AssistantConversationRepository(directory: root.appendingPathComponent("Conversations"))
        var conversation = AssistantConversation(title: "甲站与乙线", category: "换乘研究", turns: turns + [answer],
                                                  draft: "待补充的问题", draftReference: new, scope: "route", routeKey: "relation/202")
        try repository.save(conversation)
        let disk = try Data(contentsOf: repository.url(for: conversation.id))
        let loaded = try repository.load()
        try check(loaded.conversations == [conversation] && loaded.warnings.isEmpty,
                  "atomic local persistence round-trips every turn, citation, draft, route and snapshot")
        let savedObject = try JSONSerialization.jsonObject(with: disk) as! [String: Any]
        try check(Set(savedObject.keys).isSubset(of: Set(["id", "title", "category", "createdAt", "updatedAt", "turns",
                                                       "draft", "draftReference", "scope", "routeKey", "contextMode", "schemaVersion"]))
                  && !String(decoding: disk, as: UTF8.self).contains("fixture-secret"),
                  "conversation JSON contains only the conversation schema and never the request credential")
        try check(conversation.matches("换乘 node/101") && conversation.matches("待补充")
                  && conversation.matches("旧回答") && !conversation.matches("不存在的内容"),
                  "history search matches categories, IDs, drafts and historical replies")
        let exported = AssistantConversationMarkdown.conversation(conversation)
        try check(exported.contains("# 甲站与乙线") && exported.contains("分类：换乘研究")
                  && exported.contains("## 输入区草稿") && exported.contains(answer.text)
                  && exported.range(of: "甲站在哪里")!.lowerBound < exported.range(of: "介绍新增乙线")!.lowerBound,
                  "whole-conversation copy keeps chronological messages, references, category and draft")
        conversation.title = "重命名后的比较"; conversation.category = "已整理"
        conversation.draft = "更新后的草稿"; conversation.updatedAt = Date()
        try repository.save(conversation)
        try check(try repository.load().conversations == [conversation],
                  "renaming, recategorizing and draft autosaves replace the same UUID file")
        let validBytes = try Data(contentsOf: repository.url(for: conversation.id))
        var invalid = conversation
        invalid.updatedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        var rejected = false
        do { try repository.save(invalid) } catch { rejected = true }
        try check(rejected && (try Data(contentsOf: repository.url(for: conversation.id))) == validBytes,
                  "a failed save leaves the previously committed JSON intact")
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("unchanged".utf8).write(to: blockingFile, options: .atomic)
        rejected = false
        do { try AssistantConversationRepository(directory: blockingFile).save(conversation) } catch { rejected = true }
        try check(rejected && (try Data(contentsOf: blockingFile)) == Data("unchanged".utf8),
                  "an unavailable storage directory reports failure without damaging existing files")

        let pending = AssistantTurn(role: "user", text: "中断前的问题", reference: old, state: .pending)
        let interrupted = AssistantConversation(title: "中断请求", turns: [pending], draftReference: old)
        try repository.save(interrupted)
        let recovered = try repository.load().conversations.first { $0.id == interrupted.id }!
        try check(recovered.turns[0].id == pending.id && recovered.turns[0].state == .cancelled
                  && recovered.draft == pending.text && recovered.draftReference == old,
                  "restart recovers an interrupted pending turn and its draft without fabricating an answer")
        var editedPending = AssistantConversation(turns: [pending], draft: "用户随后编辑的草稿", draftReference: new)
        editedPending.recoverInterruptedRequest()
        try check(editedPending.draft == "用户随后编辑的草稿" && editedPending.draftReference == new,
                  "interruption recovery never overwrites a newer existing draft")
        for state in [AssistantTurnState.failed, .cancelled] {
            var value = conversation
            value.turns.append(AssistantTurn(role: "user", text: "可重试的问题", reference: old, state: state))
            value.draft = "可重试的问题"
            try repository.save(value)
            let restored = try repository.load().conversations.first { $0.id == value.id }!
            try check(restored == value, "\(state.rawValue) request preserves its draft, prior answers and original reference")
        }
        let corruptedURL = repository.directory.appendingPathComponent(UUID().uuidString + ".json")
        let corrupted = Data("{unfinished JSON".utf8)
        try corrupted.write(to: corruptedURL, options: .atomic)
        let partial = try repository.load()
        try check(partial.conversations.count == 2 && partial.warnings.count == 1
                  && (try Data(contentsOf: corruptedURL)) == corrupted,
                  "one corrupt conversation is reported and preserved without hiding healthy history")
        try repository.delete(id: conversation.id)
        try check(!FileManager.default.fileExists(atPath: repository.url(for: conversation.id).path)
                  && FileManager.default.fileExists(atPath: repository.url(for: interrupted.id).path)
                  && FileManager.default.fileExists(atPath: corruptedURL.path),
                  "deleting one conversation removes only that UUID file")

        let support = root.appendingPathComponent("Application Support")
        let normal = AssistantConversationRepository.defaultDirectory(arguments: ["app"], applicationSupport: support)
        let smoke = AssistantConversationRepository.defaultDirectory(arguments: ["app", "--ui-smoke", root.path], applicationSupport: support)
        let missingSmokePath = AssistantConversationRepository.defaultDirectory(arguments: ["app", "--ui-smoke"], applicationSupport: support)
        try check(normal.path == support.appendingPathComponent("RailwayAtlas/Conversations").path
                  && smoke.path == root.appendingPathComponent("Conversations").path
                  && smoke != normal && missingSmokePath != normal
                  && missingSmokePath.path.contains("RailwayAtlas-UI-Smoke-"),
                  "normal storage uses Application Support while every ui-smoke invocation is isolated")
        print("\(count) assistant conversation checks passed; local fixtures only.")
    }
}

#if ASSISTANT_STORE_CHECKS
// Opt-in same-module fixture for AssistantStore's persistence-only prefix; no map, keychain
// calls, API transport or running app is needed. The normal RailwayCore runner is unchanged.
extension AssistantChecks {
    @MainActor
    static func draftAutosave() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL: " + label) }
            count += 1; print("PASS " + label)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RailwayDraftChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AssistantConversationRepository(directory: root.appendingPathComponent("Conversations"))
        let referenceA = AssistantContextSnapshot(title: "历史甲站", scope: "feature", featureIDs: ["node/101"], text: #"{"name":"历史甲站"}"#)
        let referenceB = AssistantContextSnapshot(title: "历史乙线", scope: "route", featureIDs: ["relation/202"], text: #"{"name":"历史乙线"}"#)
        let a = AssistantConversation(title: "A", draft: "已保存草稿", draftReference: referenceA,
                                      scope: "feature", now: Date(timeIntervalSince1970: 200))
        let b = AssistantConversation(title: "B", draft: "B 的历史草稿", draftReference: referenceB,
                                      scope: "route", routeKey: "relation/202", now: Date(timeIntervalSince1970: 100))
        try repository.save(a); try repository.save(b)
        let notifications = NotificationCenter()
        let store = AssistantStore(repository: repository, notificationCenter: notifications)
        var saveAttempts = 0
        let observer = store.$current.dropFirst().sink { _ in saveAttempts += 1 }
        defer { observer.cancel() }
        func bytes(_ id: UUID) throws -> Data { try Data(contentsOf: repository.url(for: id)) }
        func saved(_ id: UUID) throws -> AssistantConversation {
            try JSONDecoder().decode(AssistantConversation.self, from: bytes(id))
        }

        let original = try bytes(a.id)
        for index in 0..<30 { store.question = "连续输入 \(index)" }
        try check(saveAttempts == 0 && (try bytes(a.id)) == original && store.question == "连续输入 29",
                  "draft keystrokes update memory without encoding, disk writes or history-list updates")
        try await Task.sleep(for: .milliseconds(650))
        try check(saveAttempts == 1 && (try saved(a.id)).draft == "连续输入 29",
                  "one quiet-period save coalesces a burst of thirty draft edits")

        store.busy = true
        store.question = "请求忙时的新草稿"
        try check(!store.newConversation() && !store.openConversation(id: b.id) && !store.deleteConversation(id: b.id)
                  && store.question == "请求忙时的新草稿", "busy guards retain the live, not-yet-flushed draft")
        try check(store.flushPendingDraft() && (try saved(a.id)).draft == "请求忙时的新草稿" && store.busy,
                  "explicit lifecycle-style flush saves drafts while a reply is busy")
        let flushed = try bytes(a.id), attemptsAfterFlush = saveAttempts
        try await Task.sleep(for: .milliseconds(650))
        try check(saveAttempts == attemptsAfterFlush && (try bytes(a.id)) == flushed
                  && store.flushPendingDraft() && saveAttempts == attemptsAfterFlush,
                  "flushing cancels the timer and clean flushes do not rewrite unchanged history")
        store.busy = false

        // Temporarily block ONLY this fixture's directory to exercise a real write failure.
        let parked = root.appendingPathComponent("parked-conversations")
        try FileManager.default.moveItem(at: repository.directory, to: parked)
        try Data("fixture blocker".utf8).write(to: repository.directory, options: .atomic)
        store.question = "写盘失败仍保留"
        try check(!store.flushPendingDraft() && store.persistenceError != nil
                  && !store.openConversation(id: b.id) && !store.newConversation()
                  && !store.deleteConversation(id: b.id) && store.current.id == a.id
                  && store.question == "写盘失败仍保留", "failed flush blocks destructive navigation and retains the live draft")
        try FileManager.default.removeItem(at: repository.directory)
        try FileManager.default.moveItem(at: parked, to: repository.directory)
        try check(store.flushPendingDraft() && store.persistenceError == nil && (try saved(a.id)).draft == "写盘失败仍保留",
                  "failed persistence remains dirty and retries successfully without another edit")

        store.question = "A 切换前的最后输入"
        try check(store.openConversation(id: b.id) && (try saved(a.id)).draft == "A 切换前的最后输入"
                  && store.question == b.draft && store.reference == referenceB
                  && store.scope == .route && store.routeKey == "relation/202",
                  "opening B flushes A and restores B's original draft, scope and reference")
        let restoredB = try bytes(b.id), attemptsAfterOpen = saveAttempts
        try await Task.sleep(for: .milliseconds(650))
        try check((try bytes(b.id)) == restoredB && saveAttempts == attemptsAfterOpen
                  && store.reference == referenceB && store.context == referenceB.text,
                  "restore schedules no draft write and a stale timer cannot touch the opened conversation")
        store.question = "B 新建前的最后输入"
        try check(store.newConversation() && (try saved(b.id)).draft == "B 新建前的最后输入" && store.question.isEmpty,
                  "new conversation flushes the previous draft before clearing the input")
        let freshID = store.current.id
        store.question = "删除其他对话前的输入"
        try check(store.deleteConversation(id: a.id) && (try saved(freshID)).draft == "删除其他对话前的输入"
                  && !FileManager.default.fileExists(atPath: repository.url(for: a.id).path),
                  "deletion flushes the active draft and removes only the selected conversation")

        store.busy = true
        store.question = "退出前最后输入"
        #if os(macOS)
        let termination = NSApplication.willTerminateNotification
        let background = NSApplication.didResignActiveNotification
        #else
        let termination = UIApplication.willTerminateNotification
        let background = UIApplication.didEnterBackgroundNotification
        #endif
        notifications.post(name: termination, object: nil)
        try check((try saved(freshID)).draft == "退出前最后输入" && store.busy,
                  "termination notification synchronously flushes even without a mounted assistant view")
        store.question = "进入后台前最后输入"
        notifications.post(name: background, object: nil)
        try check((try saved(freshID)).draft == "进入后台前最后输入",
                  "background/inactive notification synchronously flushes the final edit")
        let finalBytes = try bytes(freshID)
        try await Task.sleep(for: .milliseconds(650))
        try check((try bytes(freshID)) == finalBytes && !FileManager.default.fileExists(atPath: repository.url(for: a.id).path),
                  "cancelled timers neither rewrite the current conversation nor resurrect a deleted one")
        print("\(count) assistant draft autosave checks passed; isolated filesystem and notification fixtures only.")
    }
}
#endif

private final class AssistantFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var toolRequests: [[String: Any]] = []
    nonisolated(unsafe) static var toolRequestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "claude-tools.test" {
            let body = Self.bodyObject(request)
            Self.toolRequests.append(body)
            let responseBody: String
            switch Self.toolRequestCount {
            case 0:
                responseBody = #"{"type":"message","content":[{"type":"server_tool_use","id":"search-1","name":"web_search","input":{"query":"railway"}},{"type":"web_search_tool_result","tool_use_id":"search-1","content":[{"type":"web_search_result","title":"Search source","url":"https://search.example.test/rail","encrypted_content":"opaque-search-token"}]}],"stop_reason":"pause_turn"}"#
            case 1:
                responseBody = #"{"type":"message","content":[{"type":"server_tool_use","id":"fetch-1","name":"web_fetch","input":{"url":"https://example.test/official"}},{"type":"web_fetch_tool_result","tool_use_id":"fetch-1","content":{"type":"web_fetch_result","url":"https://example.test/official","retrieved_at":"2026-11-17T05:00:00Z","content":{"type":"document","title":"Operator page","source":{"type":"text","media_type":"text/plain","data":"Rail line"},"citations":{"enabled":true}}}}],"stop_reason":"pause_turn"}"#
            default:
                responseBody = #"{"type":"message","content":[{"type":"text","text":"根据网页资料，线路信息已核对。","citations":[{"type":"char_location","cited_text":"Rail line","document_index":0,"document_title":"Operator page","start_char_index":0,"end_char_index":9},{"type":"web_search_result_location","cited_text":"Search result","encrypted_index":"fixture","title":"Search source","url":"https://search.example.test/rail"}]}],"stop_reason":"end_turn"}"#
            }
            Self.toolRequestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if request.url?.host == "claude-tool-error.test" {
            let responseBody = #"{"type":"message","content":[{"type":"server_tool_use","id":"search-error","name":"web_search","input":{"query":"railway"}},{"type":"web_search_tool_result","tool_use_id":"search-error","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}},{"type":"text","text":"本次搜索没有成功。"}],"stop_reason":"end_turn"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if request.url?.host == "offline.test" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let isClaudeError = request.url?.host == "claude-error.test"
        let status: Int
        let body: String
        switch request.url?.host {
        case "claude-tools-unsupported.test":
            status = 400
            body = #"{"type":"error","error":{"type":"invalid_request_error","message":"Unsupported tools for this model, x-api-key: claude-fixture"}}"#
        case "claude-tools-paused.test":
            status = 200
            body = #"{"type":"message","content":[{"type":"text","text":"pending"}],"stop_reason":"pause_turn"}"#
        case "claude-tools-empty.test":
            status = 200
            body = #"{"type":"message","content":[],"stop_reason":"pause_turn"}"#
        case "claude-error.test":
            status = 401
            body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key: claude-fixture"}}"#
        case "claude-forbidden.test":
            status = 403
            body = #"{"type":"error","error":{"type":"permission_error","message":"Access denied"}}"#
        case "claude-missing.test":
            status = 404
            body = #"{"type":"error","error":{"type":"not_found_error","message":"Model not found"}}"#
        case "claude-html.test":
            status = 200
            body = "<html><body>Login page</body></html>"
        case "claude-success.test":
            let apiKey = request.value(forHTTPHeaderField: "x-api-key") == "claude-fixture"
            let bearer = request.value(forHTTPHeaderField: "Authorization") == "Bearer claude-fixture"
            status = request.httpMethod == "POST" && request.url?.path == "/v1/messages"
                && request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
                && apiKey != bearer ? 200 : 400
            body = #"{"type":"message","role":"assistant","content":[{"type":"text","text":"Claude 本地协议回答"}],"stop_reason":"end_turn"}"#
        default:
            status = request.url?.host == "unsupported.test" ? 400 : 200
            body = #"{"status":"completed","output":[{"content":[{"type":"output_text","text":"经过网络层的测试回答"}]}]}"#
        }
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json",
                                                       "request-id": isClaudeError ? "req-claude-401" : "req-fixture"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func bodyObject(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[..<count])
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
