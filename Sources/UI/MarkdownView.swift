import SwiftUI

// MARK: - 블록 파서

enum MDBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [(indent: Int, text: String)])
    case code(language: String, body: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    case divider

    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l)-\(t.hashValue)"
        case .paragraph(let t): return "p-\(t.hashValue)"
        case .list(let o, let items): return "l\(o)-\(items.map(\.text).joined().hashValue)"
        case .code(let lang, let body): return "c\(lang)-\(body.hashValue)"
        case .table(let h, let r): return "t-\(h.joined().hashValue)-\(r.count)"
        case .quote(let t): return "q-\(t.hashValue)"
        case .divider: return "hr-\(UUID().uuidString)"
        }
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 코드 펜스
            if line.hasPrefix("```") {
                flushParagraph()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(language: lang, body: body.joined(separator: "\n")))
                continue
            }

            // 표
            if line.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).contains("---") {
                flushParagraph()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 구분선
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }

            // 제목
            if line.hasPrefix("#") {
                flushParagraph()
                let hashes = line.prefix(while: { $0 == "#" }).count
                let body = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes, 4), text: body))
                i += 1
                continue
            }

            // 인용
            if line.hasPrefix("> ") {
                flushParagraph()
                var parts: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    parts.append(lines[i].trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "> ")))
                    i += 1
                }
                blocks.append(.quote(parts.joined(separator: " ")))
                continue
            }

            // 목록
            if isBullet(line) || isOrdered(line) {
                flushParagraph()
                let ordered = isOrdered(line)
                var items: [(Int, String)] = []
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    guard (ordered && isOrdered(t)) || (!ordered && isBullet(t)) else { break }
                    let indent = l.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
                    let content = ordered
                        ? t.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
                        : String(t.dropFirst(2))
                    items.append((indent, content))
                    i += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            if line.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("• ")
    }
    private static func isOrdered(_ s: String) -> Bool {
        s.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }
    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func inline(_ s: String) -> AttributedString {
        if let a = try? AttributedString(markdown: s,
                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return a
        }
        return AttributedString(s)
    }
}

// MARK: - 렌더러

struct MarkdownView: View {
    let text: String
    var tint: String = "#6E7BFF"

    private var blocks: [MDBlock] { MarkdownParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(MarkdownParser.inline(t))
                .font(Theme.title(level == 1 ? 17 : level == 2 ? 15 : 13.5, .bold))
                .padding(.top, level <= 2 ? 6 : 3)

        case .paragraph(let t):
            Text(MarkdownParser.inline(t))
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(idx + 1)." : "•")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: tint))
                            .frame(minWidth: ordered ? 16 : 8, alignment: .trailing)
                        Text(MarkdownParser.inline(item.text))
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 12)
                }
            }

        case .code(let language, let body):
            VStack(alignment: .leading, spacing: 4) {
                if !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body)
                        .font(Theme.mono)
                        .padding(9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.subtleFill)
            )

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(header, bold: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        Divider().opacity(0.4)
                        tableRow(row, bold: false, zebra: idx % 2 == 1)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.subtleFill.opacity(0.7))
                )
            }

        case .quote(let t):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: tint).opacity(0.6)).frame(width: 3)
                Text(MarkdownParser.inline(t))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .divider:
            Divider().padding(.vertical, 2)
        }
    }

    private func tableRow(_ cells: [String], bold: Bool, zebra: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(MarkdownParser.inline(cell))
                    .font(.system(size: 11.5, weight: bold ? .semibold : .regular))
                    .frame(minWidth: 70, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
        }
        .background(zebra ? Theme.subtleFill.opacity(0.5) : Color.clear)
    }
}
