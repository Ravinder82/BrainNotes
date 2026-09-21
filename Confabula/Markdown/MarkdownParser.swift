import Foundation

/// Parses a message body into block-level elements.
///
/// Line-oriented and single-pass: each line is classified once and appended to
/// the block under construction. There is no backtracking and no nested block
/// recursion beyond one level of list items and quotes, which bounds the cost
/// for the streaming path where this runs on every paint.
enum MarkdownParser {

    /// Cheap test used to skip parsing entirely for ordinary prose.
    ///
    /// The overwhelming majority of chat messages contain no markup. Detecting
    /// that up front lets the renderer fall back to a single plain `Text`, which
    /// keeps the common case at zero parsing cost. Single pass; the only
    /// lookahead is bounded and happens solely when a marker character is found
    /// at the start of a line.
    ///
    /// Deliberately conservative in one direction: a false positive only costs
    /// the parser we would have run anyway (and `MessageContent.analyse` still
    /// falls back to `.plain` if the parse is a single text run), whereas a false
    /// negative would show raw markup. So `*` anywhere is suspicious even though
    /// it may parse back to prose.
    static func containsMarkup(_ text: String) -> Bool {
        var index = text.startIndex
        var atLineStart = true
        var previous: Character?

        while index < text.endIndex {
            let c = text[index]

            // Inline markers, meaningful anywhere in the line.
            switch c {
            case "*", "`", "~", "[":
                return true
            case "_":
                // Intraword underscore (snake_case, C identifiers) is a word
                // character, never an emphasis delimiter.
                if !(previous?.isLetter == true || previous?.isNumber == true) {
                    return true
                }
            default:
                break
            }

            // Block markers, only at the start of a line (after indentation).
            if atLineStart {
                switch c {
                case " ", "\t":
                    break                   // stay at line start
                case "-", "+", ">":
                    return true
                case "#":
                    // Heading only if a space follows the run of "#".
                    var look = text.index(after: index)
                    while look < text.endIndex, text[look] == "#" {
                        look = text.index(after: look)
                    }
                    if look < text.endIndex, text[look] == " " { return true }
                case "0"..."9":
                    // Possible ordered-list marker "1. " / "2) ".
                    var look = text.index(after: index)
                    while look < text.endIndex, text[look].isNumber {
                        look = text.index(after: look)
                    }
                    if look < text.endIndex,
                       (text[look] == "." || text[look] == ")"),
                       text.index(after: look) < text.endIndex,
                       text[text.index(after: look)] == " " {
                        return true
                    }
                default:
                    break
                }
            }

            atLineStart = (c == "\n")
            previous = c
            index = text.index(after: index)
        }
        return false
    }

    /// Parses into blocks. Expects well-formed-or-partial markdown; never throws.
    static func parse(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0

        // Pending paragraph lines, flushed on a blank line or a new block.
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
            let runs = InlineMarkdownParser.parse(joined)
            if !runs.isEmpty {
                blocks.append(.paragraph(runs))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Blank line ends the current paragraph.
            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Fenced code block: ``` or ~~~, optionally with a language.
            if let fence = fenceMarker(line) {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) { i += 1; break }
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: fenceLanguage(line),
                                         code: code.joined(separator: "\n")))
                continue
            }

            // Horizontal rule: ---, ***, ___ (3+ of the same character).
            if isRule(line) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Heading: # through ######
            if let (level, content) = heading(line) {
                flushParagraph()
                blocks.append(.heading(level: level,
                                       runs: InlineMarkdownParser.parse(content)))
                i += 1
                continue
            }

            // Blockquote: > ... (collected, then parsed recursively)
            if line.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    var body = String(q.dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    quoted.append(body)
                    i += 1
                }
                blocks.append(.quote(parse(quoted.joined(separator: "\n"))))
                continue
            }

            // Bullet list: -, *, + followed by a space
            if bulletContent(line) != nil {
                flushParagraph()
                var items: [MDListItem] = []
                while i < lines.count {
                    let current = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let body = bulletContent(current) else { break }
                    items.append(MDListItem(blocks: parse(body)))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list: 1. / 1)
            if let (number, _) = orderedContent(line) {
                flushParagraph()
                var items: [MDListItem] = []
                let start = number
                var isFirst = true
                while i < lines.count {
                    let current = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let (_, body) = orderedContent(current) else { break }
                    items.append(MDListItem(blocks: parse(body)))
                    isFirst = false
                    i += 1
                }
                if !items.isEmpty {
                    blocks.append(.numberedList(start: start, items: items))
                }
                _ = isFirst
                continue
            }

            paragraph.append(line)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: - Line classification

    private static func fenceMarker(_ line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func fenceLanguage(_ line: String) -> String? {
        let stripped = line.drop(while: { $0 == "`" || $0 == "~" })
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? nil : stripped
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func heading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var i = line.startIndex
        while i < line.endIndex, line[i] == "#", level < 6 {
            level += 1
            i = line.index(after: i)
        }
        guard level > 0, i < line.endIndex, line[i] == " " else { return nil }
        let content = String(line[i...]).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (level, content)
    }

    private static func bulletContent(_ line: String) -> String? {
        for marker in ["-", "*", "+"] {
            if line.hasPrefix(marker + " ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func orderedContent(_ line: String) -> (Int, String)? {
        var i = line.startIndex
        var digits = ""
        while i < line.endIndex, line[i].isNumber, digits.count < 9 {
            digits.append(line[i])
            i = line.index(after: i)
        }
        guard !digits.isEmpty, i < line.endIndex else { return nil }
        guard line[i] == "." || line[i] == ")" else { return nil }
        let after = line.index(after: i)
        guard after < line.endIndex, line[after] == " " else { return nil }
        let body = String(line[after...]).trimmingCharacters(in: .whitespaces)
        guard let number = Int(digits) else { return nil }
        return (number, body)
    }
}