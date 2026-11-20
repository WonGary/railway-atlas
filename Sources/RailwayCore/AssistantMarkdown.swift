import Foundation

/// Native block rendering for assistant replies; code and HTML remain text.
/// Inline styles also tolerate CJK punctuation next to an emphasis boundary.
public enum AssistantMarkdown {
    public static func inline(_ text: String) -> AttributedString {
        // Protect explicitly escaped delimiters before the fallback. Leave code spans verbatim.
        let tokenPrefix = "\u{E000}" + UUID().uuidString + ":"
        var protected = "", literals: [(String, AttributedString)] = []
        let linkPattern = try? NSRegularExpression(pattern: #"\[((?:\\.|[^\]\\\n])*)\]\(([^)\n]*)\)"#)
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            if text[cursor] == "\\", next < text.endIndex {
                let end = text.index(after: next)
                if text[next] == "*" || text[next] == "_" {
                    let token = tokenPrefix + String(literals.count) + "\u{E001}"
                    literals.append((token, AttributedString(String(text[next])))); protected += token
                } else { protected += text[cursor..<end] }
                cursor = end; continue
            }
            if text[cursor] == "`" {
                var end = next
                while end < text.endIndex, text[end] == "`" { end = text.index(after: end) }
                let delimiter = String(text[cursor..<end])
                var search = end
                var closing: Range<String.Index>?
                while search < text.endIndex, let candidate = text.range(of: delimiter, range: search..<text.endIndex) {
                    if (candidate.lowerBound == end || text[text.index(before: candidate.lowerBound)] != "`")
                        && (candidate.upperBound == text.endIndex || text[candidate.upperBound] != "`") {
                        closing = candidate; break
                    }
                    search = candidate.upperBound
                }
                if let closing {
                    protected += text[cursor..<closing.upperBound]; cursor = closing.upperBound; continue
                }
                protected += delimiter; cursor = end; continue
            }
            // Foundation preserves the link but drops inline styles inside its label.
            // Parse that label separately while leaving URL validation to its Markdown parser.
            if text[cursor] == "[",
               let match = linkPattern?.firstMatch(in: text, range: NSRange(cursor..., in: text)),
               let whole = Range(match.range, in: text), whole.lowerBound == cursor,
               let label = Range(match.range(at: 1), in: text),
               let parsedLink = try? AttributedString(markdown: String(text[whole]),
                   options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
               let url = parsedLink.runs.compactMap(\.link).first {
                var content = inline(String(text[label]))
                content.link = url
                let token = tokenPrefix + String(literals.count) + "\u{E001}"
                literals.append((token, content)); protected += token
                cursor = whole.upperBound; continue
            }
            protected.append(text[cursor]); cursor = next
        }
        let parsed = (try? AttributedString(markdown: protected,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let string = String(parsed.characters)
        // CommonMark leaves **中文（含括号）**后续 literal. Only recover paired,
        // non-whitespace delimiters that survived the standard parser, never inline code.
        let pattern = #"(?<!\*)\*\*(?!\*)(\S(?:[^\n]*?\S)?)\*\*(?!\*)"#
        let matches = (try? NSRegularExpression(pattern: pattern))?
            .matches(in: string, range: NSRange(string.startIndex..., in: string)) ?? []
        var result = AttributedString(), start = parsed.startIndex
        for match in matches {
            guard let full = Range(match.range, in: string), let body = Range(match.range(at: 1), in: string),
                  let lower = AttributedString.Index(full.lowerBound, within: parsed),
                  let upper = AttributedString.Index(full.upperBound, within: parsed),
                  let contentLower = AttributedString.Index(body.lowerBound, within: parsed),
                  let contentUpper = AttributedString.Index(body.upperBound, within: parsed),
                  !parsed[lower..<upper].runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true })
            else { continue }
            result.append(AttributedString(parsed[start..<lower]))
            var content = AttributedString(parsed[contentLower..<contentUpper])
            for run in content.runs {
                content[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            }
            result.append(content); start = upper
        }
        result.append(AttributedString(parsed[start...]))
        for (token, literal) in literals {
            while let range = result.range(of: token), let attrs = result[range].runs.first?.attributes {
                var replacement = literal
                replacement.mergeAttributes(attrs, mergePolicy: .keepCurrent)
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    public static func plainText(_ text: String) -> String {
        func plain(_ value: String) -> String {
            let parsed = inline(value)
            var result = "", label = "", link: URL?
            func flush() {
                result += label
                if let link, link.absoluteString != label { result += "（" + link.absoluteString + "）" }
                label = ""
            }
            for run in parsed.runs {
                if run.link != link { flush(); link = run.link }
                label += String(parsed.characters[run.range])
            }
            flush()
            return result
        }
        return parse(text).map { block in
            switch block {
            case let .heading(_, value), let .paragraph(value): plain(value)
            case let .item(marker, value, depth): String(repeating: "  ", count: depth) + marker + " " + plain(value)
            case let .quote(value): plain(value)
            case let .code(_, value): value
            case let .table(headers, rows): ([headers] + rows).map { $0.map(plain).joined(separator: "\t") }.joined(separator: "\n")
            case .rule: "────────"
            }
        }.joined(separator: "\n\n")
    }

    public enum Block: Equatable, Sendable {
        case heading(Int, String)
        case paragraph(String)
        case item(marker: String, text: String, depth: Int)
        case quote(String)
        case code(language: String, text: String)
        case table(headers: [String], rows: [[String]])
        case rule
    }
    public static func parse(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = [], paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let raw = lines[index], line = raw.trimmingCharacters(in: .whitespaces)
            if let fence = fence(line) {
                flush()
                let language = String(line.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= fence.count && candidate.allSatisfy({ $0 == fence.character }) { break }
                    code.append(lines[index]); index += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
            } else if line.isEmpty {
                flush()
            } else if index + 1 < lines.count, let headers = cells(line), let separators = cells(lines[index + 1]),
                      headers.count == separators.count, separators.allSatisfy(isSeparator) {
                flush()
                var rows: [[String]] = []
                index += 2
                while index < lines.count, let row = cells(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(row); index += 1
                }
                let columns = max(headers.count, rows.map(\.count).max() ?? 0)
                func pad(_ row: [String]) -> [String] { row + Array(repeating: "", count: columns - row.count) }
                blocks.append(.table(headers: pad(headers), rows: rows.map(pad)))
                continue
            } else if let heading = heading(line) {
                flush(); blocks.append(.heading(heading.0, heading.1))
            } else if line.count >= 3, ["-", "*", "_"].contains(String(line.first!)),
                      line.filter({ !$0.isWhitespace }).allSatisfy({ $0 == line.first }) {
                flush(); blocks.append(.rule)
            } else if line.hasPrefix(">") {
                flush(); var quote: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix(">") else { break }
                    quote.append(String(value.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n"))); continue
            } else if let item = item(raw) {
                flush(); blocks.append(.item(marker: item.0, text: item.1, depth: item.2))
            } else {
                paragraph.append(raw)
            }
            index += 1
        }
        flush()
        return blocks
    }
    private static func fence(_ line: String) -> (character: Character, count: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix(while: { $0 == first }).count
        return count >= 3 ? (first, count) : nil
    }
    private static func heading(_ line: String) -> (Int, String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first?.isWhitespace == true else { return nil }
        return (count, String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces))
    }
    private static func item(_ raw: String) -> (String, String, Int)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let depth = min(6, raw.prefix(while: \.isWhitespace).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2)
        if let first = line.first, "-*+".contains(first), line.dropFirst().first?.isWhitespace == true {
            return ("•", String(line.dropFirst()).trimmingCharacters(in: .whitespaces), depth)
        }
        let number = line.prefix(while: \.isNumber)
        let tail = line.dropFirst(number.count)
        if !number.isEmpty, number.count <= 6, let first = tail.first, ".)".contains(first),
           tail.dropFirst().first?.isWhitespace == true {
            return (String(number) + ".", String(tail.dropFirst()).trimmingCharacters(in: .whitespaces), depth)
        }
        return nil
    }
    private static func isSeparator(_ value: String) -> Bool {
        let content = value.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return content.count >= 3 && content.allSatisfy { $0 == "-" }
    }
    private static func cells(_ line: String) -> [String]? {
        var cells: [String] = [], current = "", escaped = false, code = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { cells.append(current); current = "" }
            else { current.append(character) }
        }
        guard !cells.isEmpty else { return nil }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.isEmpty ? nil : cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
