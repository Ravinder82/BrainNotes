import Foundation

/// A block-level element of a rendered message.
///
/// SwiftUI's `Text` expresses inline styling well but cannot lay out block
/// structure — hanging-indented lists, tinted code surfaces, quote bars, rules.
/// So a message is parsed into blocks here and each block becomes its own view,
/// which gives exact control over spacing and removes the old "empty line"
/// paragraph gap.
enum MDBlock: Equatable {
    case heading(level: Int, runs: [MDInline])
    case paragraph([MDInline])
    case bulletList([MDListItem])
    case numberedList(start: Int, items: [MDListItem])
    case codeBlock(language: String?, code: String)
    case quote([MDBlock])
    case rule
}

/// One list entry. Kept as blocks so a list item can hold a nested list.
struct MDListItem: Equatable {
    let blocks: [MDBlock]

    /// Flattened text, used for accessibility and plain-text export.
    var plainText: String {
        blocks.compactMap { block -> String? in
            switch block {
            case .paragraph(let runs): return MDInline.plainText(runs)
            case .codeBlock(_, let code): return code
            case .heading(_, let runs): return MDInline.plainText(runs)
            default: return nil
            }
        }.joined(separator: " ")
    }
}

/// An inline run — a span of text sharing one style.
///
/// `code` and `link` are terminal: markdown does not style inside them, which
/// keeps the resolver simple and matches how every renderer behaves.
enum MDInline: Equatable {
    case text(String)
    case bold(String)
    case italic(String)
    case boldItalic(String)
    case code(String)
    case strike(String)
    case link(text: String, url: String)

    /// The characters this run contributes to the rendered string.
    var plainText: String {
        switch self {
        case .text(let s), .bold(let s), .italic(let s),
             .boldItalic(let s), .code(let s), .strike(let s):
            return s
        case .link(let text, _):
            return text
        }
    }

    static func plainText(_ runs: [MDInline]) -> String {
        runs.map(\.plainText).joined()
    }
}

extension Array where Element == MDBlock {
    /// All text in the document, for previews and accessibility.
    var plainText: String {
        map { block -> String in
            switch block {
            case .heading(_, let runs):      return MDInline.plainText(runs)
            case .paragraph(let runs):       return MDInline.plainText(runs)
            case .bulletList(let items):     return items.map(\.plainText).joined(separator: "\n")
            case .numberedList(_, let items): return items.map(\.plainText).joined(separator: "\n")
            case .codeBlock(_, let code):    return code
            case .quote(let inner):          return inner.plainText
            case .rule:                      return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}