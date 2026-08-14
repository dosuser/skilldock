import Foundation

/// SKILL.md 를 읽어 폼 파라미터를 추론한다.
///
/// 두 단계로 동작한다.
///  1. `infer` — 파일시스템만 읽는 결정적 스캔 (즉시, 무료)
///  2. `inferWithAI` — claude 에게 SKILL.md 를 읽혀 파라미터 스펙을 받는다 (버튼으로 명시 호출)
enum ParamInference {

    // MARK: 1단계 — 결정적 스캔

    struct Outcome {
        var params: [ParamSpec]
        var promptTemplate: String
        /// 어디에서 뽑았는지 UI 에 표시할 근거.
        var evidence: String
    }

    /// 파라미터를 뽑고, **곧바로 실행할 수 있게 기본값까지 채운다.**
    static func infer(skill: CatalogSkill) -> Outcome {
        var outcome = inferRaw(skill: skill)
        let text = (try? String(contentsOfFile: skill.path, encoding: .utf8)) ?? skill.body
        let body = FrontMatter.parse(text).body.isEmpty ? text : FrontMatter.parse(text).body

        let filled = Prefill.fill(params: outcome.params, body: body)
        outcome.params = filled.params
        if filled.filledCount > 0 {
            outcome.evidence += " · 기본값 \(filled.filledCount)개를 미리 채웠습니다"
        }
        return outcome
    }

    /// 프리필 전의 순수 추출 결과.
    static func inferRaw(skill: CatalogSkill) -> Outcome {
        let text = (try? String(contentsOfFile: skill.path, encoding: .utf8)) ?? skill.body
        let fm = FrontMatter.parse(text)
        let body = fm.body.isEmpty ? text : fm.body

        // (1) frontmatter 의 argument-hint / arguments
        if let hint = fm.string("argument-hint") ?? fm.string("argument_hint") ?? fm.string("arguments") {
            let params = parseArgumentHint(hint)
            if !params.isEmpty {
                return Outcome(params: params,
                               promptTemplate: SkillCard.defaultTemplate(command: skill.command, params: params),
                               evidence: "frontmatter argument-hint: \(hint)")
            }
        }

        // (2) 파라미터/옵션 표
        if let fromTable = parseParamTable(body), !fromTable.isEmpty {
            return Outcome(params: fromTable,
                           promptTemplate: SkillCard.defaultTemplate(command: skill.command, params: fromTable),
                           evidence: "본문의 파라미터 표에서 \(fromTable.count)개 추출")
        }

        // (3) $ARGUMENTS / $1..$9
        //     코드 블록 안의 `$1`·`$ARGUMENTS` 는 예시 셸 스크립트의 인자일 뿐이므로
        //     본문(산문) 영역에서만 슬래시 커맨드 인자로 인정한다.
        let prose = stripCodeFences(body)
        if prose.contains("$ARGUMENTS") {
            let p = [ParamSpec(key: "arguments", label: "입력값", kind: .text,
                               placeholder: "스킬에 넘길 값", required: false)]
            return Outcome(params: p,
                           promptTemplate: "/\(skill.command) {{arguments}}",
                           evidence: "본문에서 $ARGUMENTS 발견")
        }
        let positional = (1...9).filter { prose.contains("$\($0)") }
        if !positional.isEmpty {
            let p = positional.map {
                ParamSpec(key: "arg\($0)", label: "\($0)번째 값", kind: .text, required: $0 == 1)
            }
            return Outcome(params: p,
                           promptTemplate: SkillCard.defaultTemplate(command: skill.command, params: p),
                           evidence: "본문에서 위치 인자 \(positional.map { "$\($0)" }.joined(separator: ", ")) 발견")
        }

        // (4) 코드 블록 안의 플레이스홀더 토큰
        let tokens = placeholderTokens(in: body)
        if !tokens.isEmpty {
            let p = Array(tokens.prefix(6)).map { spec(forName: $0) }
            return Outcome(params: p,
                           promptTemplate: SkillCard.defaultTemplate(command: skill.command, params: p),
                           evidence: "예시 명령의 플레이스홀더 \(tokens.prefix(6).joined(separator: ", "))")
        }

        // (5) 아무것도 못 찾음 — 자유 입력 한 칸만 둔다.
        let fallback = [ParamSpec(key: "request",
                                  label: "추가 요청",
                                  help: "비워두면 스킬 기본 동작으로 실행됩니다.",
                                  kind: .longText,
                                  placeholder: "예: 최근 3일치만 정리해줘",
                                  required: false)]
        return Outcome(params: fallback,
                       promptTemplate: "/\(skill.command) {{request}}",
                       evidence: "선언된 파라미터를 찾지 못해 자유 입력 한 칸을 만들었습니다.")
    }

    /// `<query> [--limit N]` 같은 힌트 문자열을 파라미터로 바꾼다.
    private static func parseArgumentHint(_ hint: String) -> [ParamSpec] {
        var out: [ParamSpec] = []
        let pattern = #"[<\[]([^>\]]+)[>\]]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = hint as NSString
        re.enumerateMatches(in: hint, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            let inner = ns.substring(with: m.range(at: 1))
            let isRequired = ns.substring(with: m.range).hasPrefix("<")
            let name = inner.components(separatedBy: CharacterSet(charactersIn: " =|"))
                .first?.trimmingCharacters(in: CharacterSet(charactersIn: "-")) ?? inner
            guard !name.isEmpty else { return }
            var s = spec(forName: name)
            s.required = isRequired
            // "a|b|c" 형태는 선택 목록으로 만든다.
            if inner.contains("|") {
                s.kind = .select
                s.options = inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                s.defaultValue = s.options.first ?? ""
            }
            out.append(s)
        }
        return dedupe(out)
    }

    /// `## 파라미터` / `## 옵션` / `## Usage` 아래의 마크다운 표를 읽는다.
    private static func parseParamTable(_ body: String) -> [ParamSpec]? {
        let headings = ["파라미터", "옵션", "인자", "arguments", "options", "parameters", "usage", "사용법"]
        let lines = body.components(separatedBy: .newlines)
        var out: [ParamSpec] = []
        var inSection = false

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let title = t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                inSection = headings.contains { title.contains($0) }
                continue
            }
            guard inSection, t.hasPrefix("|") else { continue }
            let cells = t.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard cells.count >= 2 else { continue }
            let head = cells[0]
            // 구분선(---)과 헤더 행은 건너뛴다.
            if head.allSatisfy({ $0 == "-" || $0 == ":" }) { continue }
            let lowered = head.lowercased()
            if ["파라미터", "옵션", "이름", "name", "option", "flag", "인자", "필드", "모드"].contains(lowered) { continue }

            // `--limit`, `` `--limit` ``, `<query>` 같은 표기에서 이름만 뽑는다.
            let name = head.trimmingCharacters(in: CharacterSet(charactersIn: "`*<>[] "))
                .components(separatedBy: " ").first ?? head
            guard name.range(of: #"^[-]{0,2}[A-Za-z_][A-Za-z0-9_\-]*$"#, options: .regularExpression) != nil
            else { continue }
            var s = spec(forName: name)
            s.help = cells.count > 1 ? cells[1] : ""
            if name.hasPrefix("--") { s.kind = .toggle; s.placeholder = name }
            out.append(s)
            if out.count >= 6 { break }
        }
        let result = dedupe(out)
        return result.isEmpty ? nil : result
    }

    /// 코드 블록만 남기고 산문을 걷어낸다.
    private static func codeFences(in body: String) -> String {
        var fences: [String] = []
        var current: String?
        for line in body.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = current { fences.append(c); current = nil } else { current = "" }
                continue
            }
            if current != nil { current! += line + "\n" }
        }
        if let c = current { fences.append(c) }
        return fences.joined(separator: "\n")
    }

    /// 코드 블록을 걷어내고 산문만 남긴다.
    private static func stripCodeFences(_ body: String) -> String {
        var out: [String] = []
        var inside = false
        for line in body.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inside.toggle()
                continue
            }
            if !inside { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// 코드 블록에서 `{{VAR}}` / `<VAR>` / `{VAR}` 형태의 대문자 토큰을 모은다.
    /// 셸 변수 확장(`${VAR}`)과 같은 블록에서 값이 대입되는 이름(`VAR=...`)은 사용자 입력이 아니므로 뺀다.
    private static func placeholderTokens(in body: String) -> [String] {
        let haystack = codeFences(in: body)

        var assigned = Set<String>()
        if let re = try? NSRegularExpression(pattern: #"(?m)^\s*(?:export\s+)?([A-Z][A-Z0-9_]{2,})="#) {
            let ns = haystack as NSString
            re.enumerateMatches(in: haystack, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges > 1 else { return }
                assigned.insert(ns.substring(with: m.range(at: 1)))
            }
        }

        let noise: Set<String> = ["EOF", "TODO", "FIXME", "OK", "URL_HERE", "YOUR_TOKEN", "BR", "PRE", "CODE"]
        var seen: [String] = []
        for pattern in [#"\{\{([A-Z][A-Z0-9_]{2,})\}\}"#,
                        #"<([A-Z][A-Z0-9_]{2,})>"#,
                        #"(?<!\$)\{([A-Z][A-Z0-9_]{2,})\}"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = haystack as NSString
            re.enumerateMatches(in: haystack, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges > 1 else { return }
                let name = ns.substring(with: m.range(at: 1))
                if noise.contains(name) || assigned.contains(name) || seen.contains(name) { return }
                seen.append(name)
            }
        }
        return seen
    }

    private static func dedupe(_ specs: [ParamSpec]) -> [ParamSpec] {
        var keys = Set<String>()
        return specs.filter { keys.insert($0.key).inserted }
    }

    /// 이름만 보고 라벨·위젯 종류를 추측한다.
    static func spec(forName rawName: String) -> ParamSpec {
        let bare = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "-`<>[]{} "))
        let key = sanitizeKey(bare)
        let lower = bare.lowercased()

        var kind: ParamKind = .text
        var label = bare
        var placeholder = ""

        let map: [(match: [String], label: String, kind: ParamKind, ph: String)] = [
            (["date", "day", "날짜", "일자", "start", "end", "from", "until", "since"], "날짜", .date, "2026-08-13"),
            (["count", "limit", "num", "n", "top", "size", "개수", "건수", "days"], "개수", .number, "10"),
            (["path", "file", "dir", "folder", "경로", "파일", "output", "out"], "경로", .path, "~/Downloads"),
            (["url", "link", "주소"], "URL", .text, "https://"),
            (["query", "keyword", "search", "q", "질문", "키워드", "검색어"], "검색어", .text, ""),
            (["ticket", "issue", "jira", "key"], "이슈 키", .text, "GFA_SERVING-123"),
            (["env", "environment", "stage", "환경"], "환경", .select, ""),
            (["sql", "prompt", "text", "body", "content", "내용", "요청", "message"], "내용", .longText, ""),
        ]
        for entry in map where entry.match.contains(where: { lower == $0 || lower.contains($0) }) {
            label = entry.label
            kind = entry.kind
            placeholder = entry.ph
            break
        }
        if rawName.hasPrefix("--") {
            kind = .toggle
            placeholder = rawName
        }
        var s = ParamSpec(key: key, label: label, kind: kind, placeholder: placeholder)
        if kind == .select, lower.contains("env") || lower.contains("환경") {
            s.options = ["dev", "stage", "real"]
            s.defaultValue = "dev"
        }
        // 라벨이 원래 이름과 같으면 사람이 읽기 좋게 다듬는다.
        if s.label == bare {
            s.label = bare.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    static func sanitizeKey(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let filtered = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        var out = filtered.lowercased()
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "value" : out
    }

    // MARK: 2단계 — AI 추출

    struct AIResult: Decodable {
        var params: [AIParam]
        var promptTemplate: String?
        var title: String?
        var subtitle: String?
        var emoji: String?
    }

    struct AIParam: Decodable {
        var key: String
        var label: String
        var help: String?
        var kind: String?
        var options: [String]?
        var defaultValue: String?
        var placeholder: String?
        var required: Bool?

        var spec: ParamSpec {
            ParamSpec(key: ParamInference.sanitizeKey(key),
                      label: label.isEmpty ? key : label,
                      help: help ?? "",
                      kind: ParamKind(rawValue: kind ?? "text") ?? .text,
                      options: options ?? [],
                      defaultValue: defaultValue ?? "",
                      placeholder: placeholder ?? "",
                      required: required ?? false)
        }
    }

    private static let schema = """
    {"type":"object","additionalProperties":false,\
    "properties":{\
    "title":{"type":"string"},"subtitle":{"type":"string"},"emoji":{"type":"string"},\
    "promptTemplate":{"type":"string"},\
    "params":{"type":"array","items":{"type":"object","additionalProperties":false,\
    "properties":{"key":{"type":"string"},"label":{"type":"string"},"help":{"type":"string"},\
    "kind":{"type":"string","enum":["text","longText","number","toggle","select","date","path"]},\
    "options":{"type":"array","items":{"type":"string"}},\
    "defaultValue":{"type":"string"},"placeholder":{"type":"string"},"required":{"type":"boolean"}},\
    "required":["key","label","kind"]}}},\
    "required":["title","subtitle","emoji","promptTemplate","params"]}
    """

    struct InferError: Error {
        let message: String
    }

    /// AI 가 제안한 폼 + 카드 겉모습.
    struct AISuggestion {
        var outcome: Outcome
        var title: String
        var subtitle: String
        var emoji: String
    }

    /// claude 에게 SKILL.md 를 읽혀 폼 스펙을 받는다. 백그라운드 큐에서 호출한다.
    static func inferWithAI(skill: CatalogSkill,
                            claudePath: String,
                            completion: @escaping (Result<AISuggestion, InferError>) -> Void) {
        let prompt = """
        아래 Claude Code 스킬을 데스크톱 앱의 실행 폼으로 만들려고 한다.

        스킬 호출명: /\(skill.command)
        스킬 정의 파일: \(skill.path)

        Read 도구로 그 파일을 읽고, 이 스킬을 실행할 때 사용자에게 물어봐야 하는 입력값을 정하라.

        가장 중요한 목표: **사용자가 아무것도 입력하지 않고 버튼만 눌러도 실행되는 상태**를 만든다.
        규칙:
        - 사용자에게 실제로 필요한 값만 남긴다. 최대 5개. 물어볼 게 없으면 params 를 빈 배열로 둔다.
        - 모든 항목의 defaultValue 를 **그대로 실행해도 되는 값**으로 채운다. 비워 두지 않는다.
          정말 사람만 알 수 있는 값(개인 이름, 특정 티켓 번호)이라면 그 항목만 required 로 두고
          defaultValue 는 비운다.
        - 날짜·폴더는 굳은 값 대신 토큰을 쓴다: {{today}} {{yesterday}} {{weekAgo}} {{thisMonth}}
          {{home}} {{downloads}} {{documents}} {{worklog}} — 실행 시점에 실제 값으로 바뀐다.
        - label, help, placeholder 는 모두 한국어로 쓴다. 디자이너가 보는 화면이므로 전문 용어를 피한다.
        - key 는 영문 소문자·숫자·밑줄만 쓴다.
        - promptTemplate 은 "/\(skill.command) ..." 로 시작하고, 각 파라미터를 {{key}} 로 넣은
          자연스러운 한국어 한 문장으로 쓴다.
        - title 은 8자 이내 한국어 이름, subtitle 은 40자 이내 한 줄 설명, emoji 는 이모지 1개.
        JSON 만 출력하라.
        """
        var args = ["-p", prompt,
                    "--output-format", "json",
                    "--json-schema", schema,
                    "--permission-mode", "bypassPermissions",
                    "--allowedTools", "Read,Glob,Grep",
                    "--no-session-persistence"]
        args += ["--model", "sonnet"]

        DispatchQueue.global(qos: .userInitiated).async {
            let r = ProcessRunner.run(executable: claudePath,
                                      arguments: args,
                                      workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                                      timeout: 180)
            guard r.exitCode == 0 else {
                let msg = r.stderr.isEmpty ? "claude 실행이 실패했습니다 (코드 \(r.exitCode))" : r.stderr
                DispatchQueue.main.async {
                    completion(.failure(InferError(message: msg.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
                return
            }
            guard let inner = extractResultText(r.stdout),
                  let json = extractJSONObject(inner),
                  let parsed = try? JSONDecoder().decode(AIResult.self, from: Data(json.utf8)) else {
                DispatchQueue.main.async {
                    completion(.failure(InferError(message: "응답을 해석할 수 없습니다.")))
                }
                return
            }
            let specs = parsed.params.map { $0.spec }
            let template = parsed.promptTemplate?.isEmpty == false
                ? parsed.promptTemplate!
                : SkillCard.defaultTemplate(command: skill.command, params: specs)
            // AI 가 비워 둔 기본값은 결정적 규칙으로 메꿔 즉시 실행 상태를 보장한다.
            let body = (try? String(contentsOfFile: skill.path, encoding: .utf8)) ?? skill.body
            let filled = Prefill.fill(params: specs, body: body)
            var note = "claude 가 SKILL.md 를 읽고 \(specs.count)개 항목을 제안했습니다."
            if filled.filledCount > 0 {
                note += " 기본값 \(filled.filledCount)개가 채워져 바로 실행됩니다."
            }
            let outcome = Outcome(params: filled.params,
                                  promptTemplate: template,
                                  evidence: note)
            DispatchQueue.main.async {
                completion(.success(AISuggestion(outcome: outcome,
                                                 title: parsed.title ?? skill.name,
                                                 subtitle: parsed.subtitle ?? skill.shortSummary,
                                                 emoji: parsed.emoji ?? "✨")))
            }
        }
    }

    /// `--output-format json` 응답에서 result 문자열만 꺼낸다.
    private static func extractResultText(_ stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return stdout
        }
        if let s = obj["result"] as? String { return s }
        if let s = obj["structured_result"] {
            if let d = try? JSONSerialization.data(withJSONObject: s) { return String(data: d, encoding: .utf8) }
        }
        return nil
    }

    /// 코드 펜스나 잡담이 섞여 있어도 첫 JSON 객체를 찾아낸다.
    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if escaped { escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...idx]) }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}
