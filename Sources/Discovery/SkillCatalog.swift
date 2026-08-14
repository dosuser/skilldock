import Foundation
import Combine

/// 디스크에서 찾아낸 스킬 하나.
struct CatalogSkill: Identifiable, Hashable {
    enum Origin: Hashable {
        case user                 // ~/.claude/skills
        case agents               // ~/.agents/skills
        case plugin(String)       // ~/.claude/plugins/cache/.../skills
        case command              // ~/.claude/commands/*.md

        var label: String {
            switch self {
            case .user: return "내 스킬"
            case .agents: return "공유 스킬"
            case .plugin(let name): return name
            case .command: return "커맨드"
            }
        }

        /// 같은 이름이 여러 곳에 있을 때 우선순위 (작을수록 우선).
        var rank: Int {
            switch self {
            case .user: return 0
            case .plugin: return 1
            case .agents: return 2
            case .command: return 3
            }
        }
    }

    var command: String       // 슬래시 없이. 예 "llmTrend", "darwin:trino"
    var name: String
    var summary: String
    var tags: [String]
    var path: String          // SKILL.md 또는 커맨드 .md 경로
    var origin: Origin
    var body: String          // 파라미터 추론용 본문

    var id: String { command }

    /// description 첫 문장만 뽑아 카드 부제로 쓴다.
    var shortSummary: String {
        let cleaned = summary
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // "TRIGGER:" 뒤는 트리거 조건 나열이라 카드 설명으로 쓰지 않는다.
        let head = cleaned.components(separatedBy: "TRIGGER").first ?? cleaned
        if let dot = head.range(of: ". ") {
            return String(head[head.startIndex..<dot.lowerBound]) + "."
        }
        return head.count > 160 ? String(head.prefix(160)) + "…" : head
    }
}

/// 스킬 카탈로그 스캐너. 파일시스템만 읽으므로 비용이 없다.
final class SkillCatalog: ObservableObject {
    static let shared = SkillCatalog()

    @Published private(set) var skills: [CatalogSkill] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?

    private init() {}

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = SkillCatalog.scan()
            DispatchQueue.main.async {
                self.skills = found
                self.isScanning = false
                self.lastScan = Date()
            }
        }
    }

    func skill(command: String) -> CatalogSkill? {
        skills.first { $0.command == command }
    }

    // MARK: 스캔

    private static func scan() -> [CatalogSkill] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [String: CatalogSkill] = [:]

        func offer(_ s: CatalogSkill) {
            if let existing = found[s.command], existing.origin.rank <= s.origin.rank { return }
            found[s.command] = s
        }

        // 1) ~/.claude/skills/<name>/SKILL.md, ~/.agents/skills/<name>/SKILL.md
        let plainRoots: [(URL, CatalogSkill.Origin)] = [
            (home.appendingPathComponent(".claude/skills"), .user),
            (home.appendingPathComponent(".agents/skills"), .agents),
        ]
        for (root, origin) in plainRoots {
            for dir in childDirectories(of: root) {
                let md = dir.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: md.path) else { continue }
                if let s = parse(md, command: dir.lastPathComponent, origin: origin) { offer(s) }
            }
        }

        // 2) 플러그인 스킬 — ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/**/skills/<name>/SKILL.md
        //    호출명은 "<plugin>:<name>" 이다.
        let cache = home.appendingPathComponent(".claude/plugins/cache")
        for marketplace in childDirectories(of: cache) {
            for pluginDir in childDirectories(of: marketplace) {
                let plugin = pluginDir.lastPathComponent
                for versionDir in childDirectories(of: pluginDir) {
                    for skillsRoot in [versionDir.appendingPathComponent("skills"),
                                       versionDir.appendingPathComponent(".claude/skills")] {
                        for dir in childDirectories(of: skillsRoot) {
                            let md = dir.appendingPathComponent("SKILL.md")
                            guard fm.fileExists(atPath: md.path) else { continue }
                            let cmd = "\(plugin):\(dir.lastPathComponent)"
                            if let s = parse(md, command: cmd, origin: .plugin(plugin)) { offer(s) }
                        }
                    }
                }
            }
        }

        // 3) ~/.claude/commands/<name>.md — 슬래시 커맨드
        let commands = home.appendingPathComponent(".claude/commands")
        if let items = try? fm.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil) {
            for f in items where f.pathExtension == "md" {
                let name = f.deletingPathExtension().lastPathComponent
                if let s = parse(f, command: name, origin: .command) { offer(s) }
            }
        }

        return found.values.sorted { $0.command.localizedCaseInsensitiveCompare($1.command) == .orderedAscending }
    }

    /// 하위 디렉토리 목록. `~/.claude/skills` 대부분이 `~/.agents/skills` 로 향하는 심볼릭 링크라
    /// URL 리소스 값(.isDirectoryKey)이 아니라 링크를 따라가는 경로 기반 검사를 쓴다.
    private static func childDirectories(of url: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return child
        }
    }

    private static func parse(_ url: URL, command: String, origin: CatalogSkill.Origin) -> CatalogSkill? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fm = FrontMatter.parse(text)
        let name = fm.string("name") ?? command
        let desc = fm.string("description") ?? FrontMatter.firstParagraph(of: fm.body)
        return CatalogSkill(command: command,
                            name: name,
                            summary: desc,
                            tags: fm.list("tags"),
                            path: url.path,
                            origin: origin,
                            body: fm.body)
    }
}

// MARK: - YAML frontmatter (필요한 만큼만 해석하는 최소 파서)

struct FrontMatter {
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var body: String = ""

    func string(_ key: String) -> String? {
        guard let v = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
    func list(_ key: String) -> [String] { lists[key] ?? [] }

    static func parse(_ text: String) -> FrontMatter {
        var out = FrontMatter()
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            out.body = text
            return out
        }
        var idx = 1
        var currentKey: String?
        var blockIndent = 0
        var isBlockScalar = false
        var isList = false

        while idx < lines.count {
            let raw = lines[idx]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { idx += 1; break }

            let indent = raw.prefix(while: { $0 == " " }).count

            if isBlockScalar, let key = currentKey {
                if trimmed.isEmpty || indent >= blockIndent {
                    let piece = raw.count >= blockIndent ? String(raw.dropFirst(min(blockIndent, indent))) : trimmed
                    out.values[key, default: ""] += piece + "\n"
                    idx += 1
                    continue
                }
                isBlockScalar = false
                currentKey = nil
            }

            if isList, let key = currentKey, trimmed.hasPrefix("- ") {
                out.lists[key, default: []].append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                idx += 1
                continue
            }
            isList = false

            if let colon = trimmed.firstIndex(of: ":"), indent == 0 {
                let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value == "|" || value == ">" || value == "|-" || value == ">-" {
                    currentKey = key
                    isBlockScalar = true
                    blockIndent = 2
                    out.values[key] = ""
                } else if value.isEmpty {
                    currentKey = key
                    isList = true
                } else {
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")),
                       value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    out.values[key] = value
                }
            }
            idx += 1
        }
        out.body = lines.dropFirst(idx).joined(separator: "\n")
        return out
    }

    static func firstParagraph(of body: String) -> String {
        for block in body.components(separatedBy: "\n\n") {
            let t = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") { continue }
            return t
        }
        return ""
    }
}
