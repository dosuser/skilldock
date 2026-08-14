import Foundation

// MARK: - 동적 토큰

/// 기본값·프롬프트 안에 넣어두면 **실행 시점에** 실제 값으로 바뀌는 토큰.
///
/// 날짜를 `2026-08-13` 처럼 굳혀 두면 하루 뒤에는 틀린 값이 된다.
/// 그래서 프리필은 값 대신 `{{today}}` 같은 토큰을 채워 넣고, 실행할 때 펼친다.
enum PromptToken: String, CaseIterable {
    case today, yesterday, tomorrow
    case thisMonth, lastMonth
    case weekAgo, monthAgo
    case now, year
    case home, desktop, downloads, documents
    case worklog

    var label: String {
        switch self {
        case .today: return "오늘 날짜"
        case .yesterday: return "어제 날짜"
        case .tomorrow: return "내일 날짜"
        case .thisMonth: return "이번 달 (yyyy-MM)"
        case .lastMonth: return "지난 달 (yyyy-MM)"
        case .weekAgo: return "7일 전 날짜"
        case .monthAgo: return "30일 전 날짜"
        case .now: return "지금 시각 (HH:mm)"
        case .year: return "올해 (yyyy)"
        case .home: return "홈 폴더"
        case .desktop: return "바탕화면 폴더"
        case .downloads: return "다운로드 폴더"
        case .documents: return "서류 폴더"
        case .worklog: return "작업일지 폴더 (~/worklog)"
        }
    }

    /// 토큰 표기. 프롬프트·기본값에 이 문자열을 그대로 쓴다.
    var placeholder: String { "{{\(rawValue)}}" }

    func expand(at reference: Date) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .today: return PromptToken.day(reference, offset: 0)
        case .yesterday: return PromptToken.day(reference, offset: -1)
        case .tomorrow: return PromptToken.day(reference, offset: 1)
        case .weekAgo: return PromptToken.day(reference, offset: -7)
        case .monthAgo: return PromptToken.day(reference, offset: -30)
        case .thisMonth: return PromptToken.month(reference, offset: 0)
        case .lastMonth: return PromptToken.month(reference, offset: -1)
        case .now: return PromptToken.formatted(reference, "HH:mm")
        case .year: return PromptToken.formatted(reference, "yyyy")
        case .home: return home
        case .desktop: return home + "/Desktop"
        case .downloads: return home + "/Downloads"
        case .documents: return home + "/Documents"
        case .worklog: return home + "/worklog"
        }
    }

    private static func day(_ base: Date, offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: base) ?? base
        return formatted(d, "yyyy-MM-dd")
    }

    private static func month(_ base: Date, offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .month, value: offset, to: base) ?? base
        return formatted(d, "yyyy-MM")
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = format
        return f.string(from: date)
    }

    /// 문자열 안의 모든 토큰을 실제 값으로 바꾼다. 모르는 토큰은 그대로 남긴다.
    static func expandAll(in text: String, at reference: Date = Date()) -> String {
        guard text.contains("{{") else { return text }
        var out = text
        for token in PromptToken.allCases {
            guard out.contains(token.placeholder) else { continue }
            out = out.replacingOccurrences(of: token.placeholder, with: token.expand(at: reference))
        }
        return out
    }

    /// 문자열이 토큰을 품고 있는지 (UI 에서 "실행할 때 바뀝니다" 안내를 띄우는 데 쓴다).
    static func containsToken(_ text: String) -> Bool {
        allCases.contains { text.contains($0.placeholder) }
    }
}

// MARK: - 프리필

/// 입력 항목의 **기본값을 미리 채워** 폼을 거치지 않고 바로 실행할 수 있게 만든다.
///
/// 근거는 세 곳에서 가져온다 (앞이 우선).
///  1. `SKILL.md` 본문의 실제 예시값 — `--limit 10`, `기본값: dev`, 예시 명령의 인자
///  2. 항목 이름 패턴 — `date` → `{{today}}`, `count` → `10`, `env` → `dev`
///  3. placeholder 가 이미 값 형태면 그것 (`"2026-08-13"` → `{{today}}` 로 승격)
enum Prefill {

    /// 프리필 결과. UI 에 근거를 보여주기 위해 어디서 왔는지 남긴다.
    struct Result {
        var params: [ParamSpec]
        /// key → 근거 문구.
        var evidence: [String: String]

        var filledCount: Int { params.filter { !$0.defaultValue.isEmpty }.count }
    }

    /// 비어 있는 기본값만 채운다. 사용자가 직접 넣은 값은 건드리지 않는다.
    static func fill(params: [ParamSpec], body: String) -> Result {
        var evidence: [String: String] = [:]
        let filled = params.map { spec -> ParamSpec in
            guard spec.defaultValue.trimmingCharacters(in: .whitespaces).isEmpty else { return spec }
            var s = spec
            if let found = valueFromBody(spec: spec, body: body) {
                s.defaultValue = found.value
                evidence[s.key] = found.reason
            } else if let guess = valueFromName(spec: spec) {
                s.defaultValue = guess.value
                evidence[s.key] = guess.reason
            } else if let fromPlaceholder = valueFromPlaceholder(spec: spec) {
                s.defaultValue = fromPlaceholder.value
                evidence[s.key] = fromPlaceholder.reason
            }
            // 기본값이 채워졌으면 필수 표시를 내린다 — 그래야 한 번 눌러 실행된다.
            if !s.defaultValue.isEmpty { s.required = false }
            return s
        }
        return Result(params: filled, evidence: evidence)
    }

    /// 카드 전체를 즉시 실행 가능한 상태로 만든다.
    static func apply(to card: SkillCard, body: String) -> (card: SkillCard, result: Result) {
        var out = card
        let r = fill(params: card.params, body: body)
        out.params = r.params
        return (out, r)
    }

    /// 카드 원본 스킬 파일을 읽어 프리필한다 (본문을 따로 들고 있지 않을 때).
    static func apply(to card: SkillCard) -> (card: SkillCard, result: Result) {
        var body = ""
        if let path = card.sourcePath, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            body = FrontMatter.parse(text).body
        } else if let skill = SkillCatalog.shared.skill(command: card.command) {
            body = skill.body
        }
        return apply(to: card, body: body)
    }

    private struct Found {
        var value: String
        var reason: String
    }

    // MARK: 1) 본문 예시값

    /// 본문에서 이 항목에 해당하는 실제 예시값을 찾는다.
    private static func valueFromBody(spec: ParamSpec, body: String) -> Found? {
        guard !body.isEmpty else { return nil }
        let key = spec.key
        let aliases = [key, key.replacingOccurrences(of: "_", with: "-")]

        // (a) `기본값: X` / `default: X` — 항목 이름과 같은 줄이나 표 행에 있을 때
        for line in body.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            guard aliases.contains(where: { lower.contains($0.lowercased()) }) else { continue }
            guard lower.contains("기본") || lower.contains("default") else { continue }
            if let v = firstQuotedOrBacktickedValue(in: line) {
                return Found(value: normalize(v, spec: spec), reason: "본문 기본값 표기 — \(trim(line))")
            }
        }

        // (b) 예시 명령의 플래그 값 — `--limit 10`, `--env dev`, `--date 2026-08-13`
        for alias in aliases {
            let pattern = "--\(NSRegularExpression.escapedPattern(for: alias))[= ]+([^\\s`\"']+)"
            if let v = firstMatch(pattern, in: body, group: 1) {
                return Found(value: normalize(v, spec: spec), reason: "예시 명령의 `--\(alias) \(v)`")
            }
        }

        // (c) `key: value` / `key = value` 형태 (yaml·설정 예시)
        for alias in aliases {
            let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: alias))\\s*[:=]\\s*([^\\s#]+)\\s*$"
            if let v = firstMatch(pattern, in: body, group: 1), v.count <= 40 {
                return Found(value: normalize(v, spec: spec),
                             reason: "본문 예시 `\(alias): \(v)`")
            }
        }

        // (d) 선택 목록이 이미 있으면 첫 보기를 쓴다.
        if spec.kind == .select, let first = spec.options.first {
            return Found(value: first, reason: "선택 목록의 첫 보기")
        }
        return nil
    }

    // MARK: 2) 이름 패턴

    /// 항목 이름만 보고 안전한 기본값을 고른다. 값 대신 토큰을 쓸 수 있으면 토큰을 쓴다.
    private static func valueFromName(spec: ParamSpec) -> Found? {
        let lower = (spec.key + " " + spec.label).lowercased()

        func has(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }

        switch spec.kind {
        case .date:
            if has(["until", "end", "종료", "to"]) {
                return Found(value: PromptToken.today.placeholder, reason: "종료 날짜 → 오늘")
            }
            if has(["since", "start", "from", "시작"]) {
                return Found(value: PromptToken.weekAgo.placeholder, reason: "시작 날짜 → 7일 전")
            }
            return Found(value: PromptToken.today.placeholder, reason: "날짜 항목 → 오늘")

        case .number:
            if has(["day", "일수", "기간"]) { return Found(value: "7", reason: "기간 항목 → 7") }
            return Found(value: "10", reason: "개수 항목 → 10")

        case .toggle:
            return Found(value: "false", reason: "켜기/끄기 → 꺼짐")

        case .select:
            if let first = spec.options.first {
                return Found(value: first, reason: "선택 목록의 첫 보기")
            }
            return nil

        case .path:
            if has(["output", "out", "저장", "결과"]) {
                return Found(value: PromptToken.downloads.placeholder, reason: "저장 경로 → 다운로드 폴더")
            }
            if has(["worklog", "작업일지"]) {
                return Found(value: PromptToken.worklog.placeholder, reason: "작업일지 폴더")
            }
            return Found(value: PromptToken.home.placeholder, reason: "경로 항목 → 홈 폴더")

        case .text, .longText:
            // 자유 입력은 비워 두는 게 맞다 — 스킬 기본 동작으로 실행된다.
            // 단 "추가 요청"류는 비어 있어도 실행되므로 필수만 내려준다.
            return nil
        }
    }

    // MARK: 3) placeholder 승격

    /// placeholder 에 이미 실제 값 예시가 들어 있으면 기본값으로 승격한다.
    private static func valueFromPlaceholder(spec: ParamSpec) -> Found? {
        let ph = spec.placeholder.trimmingCharacters(in: .whitespaces)
        guard !ph.isEmpty, !ph.hasPrefix("예"), !ph.contains("입력"), ph.count <= 40 else { return nil }
        // 날짜 예시는 토큰으로 바꿔 넣는다 (굳은 날짜를 남기지 않는다).
        if ph.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return Found(value: PromptToken.today.placeholder, reason: "예시 날짜 → 오늘 토큰")
        }
        if spec.kind == .number, Int(ph) != nil {
            return Found(value: ph, reason: "예시 숫자 \(ph)")
        }
        if spec.kind == .path, ph.hasPrefix("~") || ph.hasPrefix("/") {
            return Found(value: ph, reason: "예시 경로 \(ph)")
        }
        return nil
    }

    // MARK: 도우미

    private static func normalize(_ raw: String, spec: ParamSpec) -> String {
        var v = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' ,."))
        if spec.kind == .date, v.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            // 문서에 적힌 날짜는 이미 지난 날짜다. 오늘로 바꿔 둔다.
            v = PromptToken.today.placeholder
        }
        if spec.kind == .toggle {
            v = ["true", "on", "yes", "1"].contains(v.lowercased()) ? "true" : "false"
        }
        return v
    }

    private static func firstQuotedOrBacktickedValue(in line: String) -> String? {
        for pattern in [#"`([^`]{1,40})`"#, #"[:=]\s*([^\s|]{1,40})"#] {
            if let v = firstMatch(pattern, in: line, group: 1) { return v }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group,
              m.range(at: group).location != NSNotFound else { return nil }
        let v = ns.substring(with: m.range(at: group)).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "|# ").union(.whitespaces))
        return t.count > 70 ? String(t.prefix(70)) + "…" : t
    }
}
