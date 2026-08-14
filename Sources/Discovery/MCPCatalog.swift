import Foundation
import Combine

/// 이 컴퓨터에 설정된 MCP 서버 하나.
///
/// 보안 주의: `headers` · `env` 에는 API 키가 들어 있다. 이 구조체는 **그 값을 읽지 않는다.**
/// 이름 · 전송 방식 · 접속 지점(호스트나 명령 이름)만 가져온다.
struct MCPServer: Identifiable, Hashable {
    enum Transport: String {
        case http, sse, stdio

        var label: String {
            switch self {
            case .http: return "HTTP"
            case .sse: return "SSE"
            case .stdio: return "로컬 실행"
            }
        }

        var symbol: String {
            switch self {
            case .http, .sse: return "globe"
            case .stdio: return "terminal"
            }
        }
    }

    enum Scope: Hashable {
        case user                    // ~/.claude.json 의 mcpServers
        case settings                // ~/.claude/settings.json
        case project(String)         // ~/.claude.json 의 projects.<경로>.mcpServers

        var label: String {
            switch self {
            case .user: return "전역"
            case .settings: return "설정"
            case .project(let path): return (path as NSString).lastPathComponent
            }
        }

        var rank: Int {
            switch self {
            case .user: return 0
            case .settings: return 1
            case .project: return 2
            }
        }
    }

    var name: String
    var transport: Transport
    /// http/sse 면 호스트, stdio 면 실행 명령 이름. 비밀값은 담지 않는다.
    var endpoint: String
    var scope: Scope
    /// 어느 설정 파일에서 왔는지 (UI 안내용).
    var configPath: String

    var id: String { name }

    /// Claude Code 가 이 서버의 도구에 붙이는 접두어.
    var toolPrefix: String { "mcp__\(name)__" }

    var summary: String {
        "\(transport.label) · \(endpoint)"
    }
}

/// MCP 설정 스캐너. 설정 파일만 읽으므로 서버에 접속하지 않는다.
final class MCPCatalog: ObservableObject {
    static let shared = MCPCatalog()

    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?

    private init() {}

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = MCPCatalog.scan()
            DispatchQueue.main.async {
                self.servers = found
                self.isScanning = false
                self.lastScan = Date()
            }
        }
    }

    func server(name: String) -> MCPServer? { servers.first { $0.name == name } }

    /// 런루프를 기다리지 않고 바로 스캔한다 (점검 도구용).
    static func scanSynchronously() -> [MCPServer] { scan() }

    // MARK: 스캔

    private static func scan() -> [MCPServer] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [String: MCPServer] = [:]

        func offer(_ s: MCPServer) {
            if let existing = found[s.name], existing.scope.rank <= s.scope.rank { return }
            found[s.name] = s
        }

        // 1) ~/.claude.json — 전역 mcpServers + 프로젝트별 mcpServers
        let claudeJSON = home.appendingPathComponent(".claude.json")
        if let root = object(at: claudeJSON) {
            for s in servers(in: root["mcpServers"], scope: .user, path: claudeJSON.path) { offer(s) }
            if let projects = root["projects"] as? [String: Any] {
                for (projectPath, raw) in projects {
                    guard let dict = raw as? [String: Any] else { continue }
                    for s in servers(in: dict["mcpServers"],
                                     scope: .project(projectPath),
                                     path: claudeJSON.path) { offer(s) }
                }
            }
        }

        // 2) 설정 파일들
        for name in ["settings.json", "settings.local.json", "mcp.json"] {
            let url = home.appendingPathComponent(".claude/\(name)")
            guard let root = object(at: url) else { continue }
            for s in servers(in: root["mcpServers"], scope: .settings, path: url.path) { offer(s) }
        }

        // 3) 홈의 프로젝트 스코프 설정
        let mcpJSON = home.appendingPathComponent(".mcp.json")
        if let root = object(at: mcpJSON) {
            for s in servers(in: root["mcpServers"], scope: .settings, path: mcpJSON.path) { offer(s) }
        }

        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func servers(in raw: Any?, scope: MCPServer.Scope, path: String) -> [MCPServer] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.compactMap { name, value -> MCPServer? in
            guard let entry = value as? [String: Any] else { return nil }
            let declared = (entry["type"] as? String)?.lowercased() ?? ""

            if let url = entry["url"] as? String {
                let transport: MCPServer.Transport = declared == "sse" ? .sse : .http
                return MCPServer(name: name,
                                 transport: transport,
                                 endpoint: URL(string: url)?.host ?? url,
                                 scope: scope,
                                 configPath: path)
            }
            if let command = entry["command"] as? String {
                return MCPServer(name: name,
                                 transport: .stdio,
                                 endpoint: (command as NSString).lastPathComponent,
                                 scope: scope,
                                 configPath: path)
            }
            return nil
        }
    }
}

// MARK: - MCP 서버 → 즉시 실행 카드

extension MCPServer {
    /// 서버 이름에서 "바로 눌러도 쓸모 있는" 첫 요청을 고른다.
    ///
    /// 도구 목록은 서버에 접속해야 알 수 있으므로, 이름의 성격만 보고 안전한 조회형 요청을 채운다.
    /// 전부 읽기 전용 요청이라 눌러도 무언가를 망가뜨리지 않는다.
    var suggestedRequest: String {
        let n = name.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { n.contains($0) } }

        if has(["jira"]) { return "내게 할당된 열린 이슈를 최근 수정순으로 10건 정리해줘." }
        if has(["confluence", "wiki", "atlassian"]) { return "내가 최근에 수정한 문서 10건을 정리해줘." }
        if has(["trino", "sql", "presto", "query", "db", "mongo", "hbase", "redash"]) {
            return "접근 가능한 카탈로그·스키마 목록을 정리해줘."
        }
        if has(["metric", "prometheus", "victoria", "npot", "grafana", "tsdb"]) {
            return "최근 1시간 주요 지표에 이상이 있는지 확인해서 요약해줘."
        }
        if has(["mail", "calendar", "works", "schedule"]) {
            return "오늘 일정과 안 읽은 메일을 요약해줘."
        }
        if has(["log", "iolog", "trace"]) { return "최근 오류 로그를 10건 요약해줘." }
        if has(["memory", "note"]) { return "저장된 항목 중 최근 것 10건을 정리해줘." }
        if has(["code", "repo", "git", "flow"]) { return "사용 가능한 도구와 대표 조회 결과를 요약해줘." }
        return "이 서버에서 쓸 수 있는 도구를 확인하고, 대표 조회를 한 번 실행해 결과를 요약해줘."
    }

    /// 눌렀을 때 그대로 실행되는 카드를 만든다.
    func makeCard() -> SkillCard {
        let pretty = name
            .replacingOccurrences(of: "-mcp", with: "")
            .replacingOccurrences(of: "mcp-", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let tint = Theme.palette[abs(name.hashValue) % Theme.palette.count]

        let request = ParamSpec(key: "request",
                                label: "요청",
                                help: "이 서버의 도구로 무엇을 할지. 비우면 도구 목록만 확인합니다.",
                                kind: .longText,
                                defaultValue: suggestedRequest,
                                placeholder: suggestedRequest)

        var card = SkillCard(title: pretty,
                             subtitle: "\(name) MCP · \(transport.label)",
                             emoji: transport == .stdio ? "🧩" : "🔌",
                             tint: tint,
                             command: name,
                             promptTemplate: "\(toolPrefix) 로 시작하는 MCP 도구를 사용해서 {{request}} 결과는 표로 정리해줘.",
                             params: [request])
        card.source = .mcp
        card.mcpServer = name
        return card
    }
}
