import Foundation

/// Parses inline markdown into styled runs.
///
/// Two properties matter for a chat app:
///
/// 1. **Linear time.** A message is at most a few KB, but this runs on every
///    paint of a streaming reply, so it must not backtrack.
/// 2. **Tolerant of half-arrived syntax.** While a reply streams, the buffer can
///    end mid-marker (`"**bo"`). An unterminated marker is emitted as literal
///    text rather than being held back or guessed at, so already-visible content
///    never reflows when the closing marker finally lands.
enum InlineMarkdownParser {

    static func parse(_ source: String) -> [MDInline] {
        guard !source.isEmpty else { return [] }
        var runs: [MDInline] = []
        var buffer = ""

        let chars = Array(source)
        var i = 0

        /// Flushes pending plain text into a run.
        func flush() {
            if !buffer.isEmpty {
                runs.append(.text(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        while i < chars.count {
            let c = chars[i]

            // Backslash escape: the next character is literal.
            if c == "\\", i + 1 < chars.count {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }

            // Inline code wins over everything else: markdown does not style
            // inside backticks, so there is nothing to resolve there.
            if c == "`" {
                if let close = indexOfUnescaped("`", in: chars, from: i + 1) {
                    let inner = String(chars[(i + 1)..<close])
                    if !inner.isEmpty {
                        flush()
                        runs.append(.code(inner))
                        i = close + 1
                        continue
                    }
                }
                // Unterminated: literal backtick.
                buffer.append(c)
                i += 1
                continue
            }

            // Links: [text](url). Requires both halves, else literal.
            if c == "[" {
                if let parsed = parseLink(chars, from: i) {
                    flush()
                    runs.append(.link(text: parsed.text, url: parsed.url))
                    i = parsed.next
                    continue
                }
                buffer.append(c)
                i += 1
                continue
            }

            // Bare autolink: http(s)://... up to whitespace.
            if c == "h", matches("http", chars, at: i) {
                if let (url, next) = parseAutolink(chars, from: i) {
                    flush()
                    runs.append(.link(text: url, url: url))
                    i = next
                    continue
                }
            }

            // Strong emphasis must be tested before single-character emphasis.
            if c == "*" || c == "_" {
                // Intraword underscores (snake_case, C identifiers) never form
                // emphasis: a `_` between alphanumerics is a word character.
                if c == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber {
                    buffer.append(c)
                    i += 1
                    continue
                }

                let marker = String(c)

                if matches(marker + marker, chars, at: i) {
                    if let close = indexOfUnescaped(marker + marker, in: chars,
                                                    from: i + 2) {
                        let inner = String(chars[(i + 2)..<close])
                        if !inner.isEmpty {
                            // Closing side of `__` must also sit on a word
                            // boundary (guards against odd identifiers).
                            let after = close + 2
                            if after >= chars.count
                                || !chars[after].isLetter && !chars[after].isNumber {
                                flush()
                                runs.append(.bold(inner))
                                i = close + 2
                                continue
                            }
                        }
                    }
                    buffer.append(contentsOf: marker + marker)
                    i += 2
                    continue
                }

                if let close = indexOfUnescaped(marker, in: chars, from: i + 1) {
                    let inner = String(chars[(i + 1)..<close])
                    // A lone marker inside (e.g. "2 * 3 * 4") is not emphasis;
                    // requiring non-space edges avoids that misread. The closing
                    // `_` must also precede a non-alphanumeric, e.g. "word_".
                    if !inner.isEmpty,
                       !inner.hasPrefix(" "), !inner.hasSuffix(" "),
                       close + 1 >= chars.count
                        || !chars[close + 1].isLetter && !chars[close + 1].isNumber {
                        flush()
                        runs.append(.italic(inner))
                        i = close + 1
                        continue
                    }
                }
                buffer.append(c)
                i += 1
                continue
            }

            // Strikethrough: ~~text~~
            if c == "~", matches("~~", chars, at: i) {
                if let close = indexOfUnescaped("~~", in: chars, from: i + 2) {
                    let inner = String(chars[(i + 2)..<close])
                    if !inner.isEmpty {
                        flush()
                        runs.append(.strike(inner))
                        i = close + 2
                        continue
                    }
                }
                buffer.append(contentsOf: "~~")
                i += 2
                continue
            }

            // Newlines inside a paragraph collapse to a space: block structure
            // already owns line breaks, so a hard wrap must not double up.
            if c == "\n" {
                if !buffer.hasSuffix(" ") && !buffer.isEmpty { buffer.append(" ") }
                i += 1
                continue
            }

            buffer.append(c)
            i += 1
        }

        flush()
        return mergeAdjacentText(runs)
    }

    // MARK: - Helpers

    /// Finds a closing marker, skipping escaped occurrences.
    private static func indexOfUnescaped(_ marker: String,
                                         in chars: [Character],
                                         from start: Int) -> Int? {
        let m = Array(marker)
        var i = start
        while i <= chars.count - m.count {
            if chars[i] == "\\" { i += 2; continue }
            if Array(chars[i..<(i + m.count)]) == m { return i }
            i += 1
        }
        return nil
    }

    private static func matches(_ needle: String, _ chars: [Character],
                                at index: Int) -> Bool {
        let n = Array(needle)
        guard index + n.count <= chars.count else { return false }
        return Array(chars[index..<(index + n.count)]) == n
    }

    private static func parseAutolink(_ chars: [Character], from start: Int)
        -> (url: String, next: Int)? {
        var i = start
        var url = ""
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\n" || c == "\t" || c == ")" || c == "]" { break }
            url.append(c)
            i += 1
        }
        guard url.count > "https://".count else { return nil }
        // Trailing sentence punctuation is not part of the URL.
        while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
        return (url, start + url.count)
    }

    private static func parseLink(_ chars: [Character], from start: Int)
        -> (text: String, url: String, next: Int)? {
        guard chars[start] == "[" else { return nil }
        guard let closeBracket = indexOfUnescaped("]", in: chars, from: start + 1)
        else { return nil }
        let nextIndex = closeBracket + 1
        guard nextIndex < chars.count, chars[nextIndex] == "(" else { return nil }
        guard let closeParen = indexOfUnescaped(")", in: chars, from: nextIndex + 1)
        else { return nil }

        let text = String(chars[(start + 1)..<closeBracket])
        var url = String(chars[(nextIndex + 1)..<closeParen])
            .trimmingCharacters(in: .whitespaces)
        // Tolerate an optional title: [x](url "title")
        if let space = url.firstIndex(of: " ") {
            url = String(url[url.startIndex..<space])
        }
        guard !text.isEmpty, !url.isEmpty else { return nil }
        return (text, url, closeParen + 1)
    }

    /// Coalesces neighbouring plain runs so the rendered string has no
    /// redundant boundaries.
    private static func mergeAdjacentText(_ runs: [MDInline]) -> [MDInline] {
        var out: [MDInline] = []
        for run in runs {
            if case .text(let s) = run, case .text(let prev) = out.last {
                out[out.count - 1] = .text(prev + s)
            } else if case .text(let s) = run, s.isEmpty {
                continue
            } else {
                out.append(run)
            }
        }
        return out
    }
}