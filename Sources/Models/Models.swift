import Foundation

// MARK: - 파라미터

/// 폼에서 렌더링할 입력 위젯 종류.
enum ParamKind: String, Codable, CaseIterable, Identifiable {
    case text          // 한 줄 입력
    case longText      // 여러 줄 입력
    case number        // 숫자
    case toggle        // on/off
    case select        // 미리 정의된 보기 중 선택
    case date          // 날짜 (yyyy-MM-dd)
    case path          // 파일/폴더 선택

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "한 줄 텍스트"
        case .longText: return "여러 줄 텍스트"
        case .number: return "숫자"
        case .toggle: return "켜기/끄기"
        case .select: return "선택 목록"
        case .date: return "날짜"
        case .path: return "파일 경로"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "textformat"
        case .longText: return "text.alignleft"
        case .number: return "number"
        case .toggle: return "switch.2"
        case .select: return "list.bullet"
        case .date: return "calendar"
        case .path: return "folder"
        }
    }
}

/// 스킬 실행 시 사용자에게 물어볼 값 하나.
struct ParamSpec: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// 프롬프트 템플릿에서 `{{key}}` 로 치환되는 이름.
    var key: String
    var label: String
    var help: String = ""
    var kind: ParamKind = .text
    var options: [String] = []
    var defaultValue: String = ""
    var placeholder: String = ""
    var required: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, key, label, help, kind, options, defaultValue, placeholder, required
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        help = try c.decodeIfPresent(String.self, forKey: .help) ?? ""
        kind = try c.decodeIfPresent(ParamKind.self, forKey: .kind) ?? .text
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
    }

    init(key: String,
         label: String,
         help: String = "",
         kind: ParamKind = .text,
         options: [String] = [],
         defaultValue: String = "",
         placeholder: String = "",
         required: Bool = false) {
        self.key = key
        self.label = label
        self.help = help
        self.kind = kind
        self.options = options
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.required = required
    }
}

// MARK: - 실행 옵션

struct RunOptions: Codable, Hashable {
    /// 스킬을 실행할 작업 디렉토리. 비어 있으면 홈.
    var workingDirectory: String = ""
    /// "" = Claude Code 기본 모델. 그 외 "opus" / "sonnet" / "haiku" / 전체 모델명.
    var model: String = ""
    /// 헤드리스 실행에서 도구 권한을 자동 승인할지. 대부분의 스킬은 Bash 를 쓰므로 기본 on.
    var bypassPermissions: Bool = true
    var timeoutSeconds: Int = 1800
    /// 완료 시 macOS 알림 표시.
    var notifyOnFinish: Bool = true
    /// 세션 저장 없이 실행 (일회성 실행에 적합).
    var ephemeral: Bool = false

    var resolvedWorkingDirectory: String {
        let t = workingDirectory.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return FileManager.default.homeDirectoryForCurrentUser.path }
        return (t as NSString).expandingTildeInPath
    }
}

// MARK: - 단축키

struct HotKeySpec: Codable, Hashable {
    /// Carbon virtual key code.
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey / optionKey / controlKey / shiftKey).
    var modifiers: UInt32

    var displayString: String { HotKeyFormatter.string(keyCode: keyCode, modifiers: modifiers) }
}

// MARK: - 등록된 스킬 카드

/// 카드가 무엇을 부르는지. 표시용 구분이며 실행 방식은 같다 (`claude -p`).
enum CardSource: String, Codable {
    case skill      // 슬래시 커맨드 / SKILL.md
    case mcp        // MCP 서버 도구
    case custom     // 사용자가 직접 쓴 프롬프트

    var label: String {
        switch self {
        case .skill: return "스킬"
        case .mcp: return "MCP"
        case .custom: return "직접 작성"
        }
    }
}

struct SkillCard: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var subtitle: String = ""
    var emoji: String = "✨"
    /// 카드 색상 (hex, 예 "#6E7BFF").
    var tint: String = "#6E7BFF"
    /// 슬래시 커맨드 이름 (앞의 `/` 없이). 예 "llmTrend", "darwin:trino".
    var command: String
    /// 실제로 claude 에 넘길 프롬프트. `{{key}}` 가 파라미터 값으로 치환된다.
    var promptTemplate: String
    var params: [ParamSpec] = []
    var run: RunOptions = RunOptions()
    var hotkey: HotKeySpec? = nil
    /// 파라미터 재추출을 위해 원본 SKILL.md 경로를 기억한다.
    var sourcePath: String? = nil
    /// 최근 실행 시각 (정렬용).
    var lastRunAt: Date? = nil
    /// 스킬 / MCP / 직접 작성.
    var source: CardSource = .skill
    /// `source == .mcp` 일 때 대상 서버 이름.
    var mcpServer: String = ""
    /// 목록에서 카드를 누르면 폼을 건너뛰고 바로 실행한다.
    var instantRun: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, emoji, tint, command, promptTemplate, params, run, hotkey, sourcePath, lastRunAt
        case source, mcpServer, instantRun
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "이름 없는 스킬"
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "✨"
        tint = try c.decodeIfPresent(String.self, forKey: .tint) ?? "#6E7BFF"
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        promptTemplate = try c.decodeIfPresent(String.self, forKey: .promptTemplate) ?? "/\(command)"
        params = try c.decodeIfPresent([ParamSpec].self, forKey: .params) ?? []
        run = try c.decodeIfPresent(RunOptions.self, forKey: .run) ?? RunOptions()
        hotkey = try c.decodeIfPresent(HotKeySpec.self, forKey: .hotkey)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        source = try c.decodeIfPresent(CardSource.self, forKey: .source) ?? .skill
        mcpServer = try c.decodeIfPresent(String.self, forKey: .mcpServer) ?? ""
        // 예전 설정 파일에는 이 값이 없다. 원클릭이 기본 동작이므로 켜진 상태로 읽는다.
        instantRun = try c.decodeIfPresent(Bool.self, forKey: .instantRun) ?? true
    }

    init(title: String,
         subtitle: String = "",
         emoji: String = "✨",
         tint: String = "#6E7BFF",
         command: String,
         promptTemplate: String? = nil,
         params: [ParamSpec] = [],
         run: RunOptions = RunOptions(),
         hotkey: HotKeySpec? = nil,
         sourcePath: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.emoji = emoji
        self.tint = tint
        self.command = command
        self.promptTemplate = promptTemplate ?? SkillCard.defaultTemplate(command: command, params: params)
        self.params = params
        self.run = run
        self.hotkey = hotkey
        self.sourcePath = sourcePath
    }

    /// `/command {{a}} {{b}}` 형태의 기본 템플릿.
    static func defaultTemplate(command: String, params: [ParamSpec]) -> String {
        let slots = params.map { "{{\($0.key)}}" }.joined(separator: " ")
        return slots.isEmpty ? "/\(command)" : "/\(command) \(slots)"
    }

    // MARK: 원클릭 판정

    /// 아직 값이 없는 필수 항목. 비어 있으면 폼 없이 바로 실행할 수 있다.
    func missingRequired(values: [String: String] = [:]) -> [ParamSpec] {
        params.filter { p in
            guard p.required else { return false }
            let v = values[p.key] ?? p.defaultValue
            return v.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// 저장된 기본값만으로 실행 가능한 상태인지.
    var isReadyToRun: Bool { missingRequired().isEmpty }

    /// 목록에서 눌렀을 때 곧바로 실행할 카드인지.
    var runsOnSingleClick: Bool { instantRun && isReadyToRun }

    /// 기본값에 동적 토큰(오늘 날짜 등)이 들어 있는지.
    var usesDynamicTokens: Bool {
        PromptToken.containsToken(promptTemplate) || params.contains { PromptToken.containsToken($0.defaultValue) }
    }

    /// 폼을 거치지 않을 때 쓰는 값 묶음 — 전부 기본값.
    var defaultValues: [String: String] {
        Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) })
    }

    /// 파라미터 값으로 템플릿을 채운 최종 프롬프트.
    func renderPrompt(values: [String: String]) -> String {
        var out = promptTemplate
        for p in params {
            let raw = values[p.key] ?? p.defaultValue
            let value: String
            switch p.kind {
            case .toggle:
                // 꺼져 있으면 자리만 비운다 — 플래그성 파라미터를 자연스럽게 표현한다.
                value = (raw == "true") ? (p.placeholder.isEmpty ? p.label : p.placeholder) : ""
            default:
                value = raw
            }
            out = out.replacingOccurrences(of: "{{\(p.key)}}", with: value)
        }
        // 날짜·폴더 토큰은 실행하는 지금 시점으로 펼친다 (기본값에 굳은 날짜를 남기지 않으려고 토큰을 쓴다).
        out = PromptToken.expandAll(in: out)
        // 값이 비어 남은 자리는 지운다.
        out = out.replacingOccurrences(of: #"\{\{[A-Za-z0-9_\-]+\}\}"#,
                                       with: "",
                                       options: .regularExpression)
        return out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                  .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 앱 전체 설정

struct AppConfig: Codable {
    var version: Int = 1
    /// claude 실행 파일 경로. 비어 있으면 자동 탐색.
    var claudePath: String = ""
    var cards: [SkillCard] = []
    /// 팝오버를 여는 전역 단축키.
    var openPopoverHotkey: HotKeySpec? = HotKeySpec(keyCode: 40 /* K */, modifiers: 0x0900 /* cmd+opt */)
    /// 단축키를 눌렀을 때 팝오버 대신 곧바로 실행할 카드.
    var quickRunCardID: UUID? = nil
    /// 결과를 저장할 폴더.
    var resultDirectory: String = "~/SkillsOnMenu"

    enum CodingKeys: String, CodingKey {
        case version, claudePath, cards, openPopoverHotkey, quickRunCardID, resultDirectory
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? ""
        cards = try c.decodeIfPresent([SkillCard].self, forKey: .cards) ?? []
        openPopoverHotkey = try c.decodeIfPresent(HotKeySpec.self, forKey: .openPopoverHotkey)
        quickRunCardID = try c.decodeIfPresent(UUID.self, forKey: .quickRunCardID)
        resultDirectory = try c.decodeIfPresent(String.self, forKey: .resultDirectory) ?? "~/SkillsOnMenu"
    }

    var resolvedResultDirectory: URL {
        URL(fileURLWithPath: (resultDirectory as NSString).expandingTildeInPath)
    }
}
