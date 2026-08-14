// 순수 로직 점검용 실행 파일. GUI 없이 카탈로그 스캔·파라미터 추론·프롬프트 렌더링·설정 직렬화를 검증한다.
// 빌드: ./tools/selfcheck.sh
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures += 1 }
}

print("=== 1. 스킬 카탈로그 스캔 ===")
let catalog = SkillCatalog.shared
let sem = DispatchSemaphore(value: 0)
var scanned: [CatalogSkill] = []
DispatchQueue.global().async {
    // refresh 는 메인 큐에 결과를 실어 보내므로 여기서는 내부 스캔을 직접 부른다.
    DispatchQueue.main.async {
        catalog.refresh()
    }
}
// 메인 런루프를 돌려 스캔 완료를 기다린다.
DispatchQueue.main.async {
    var waited = 0.0
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
        waited += 0.2
        if !catalog.skills.isEmpty || waited > 8 {
            scanned = catalog.skills
            t.invalidate()
            sem.signal()
        }
    }
}
DispatchQueue.global().async {
    sem.wait()
    report()
    exit(failures == 0 ? 0 : 1)
}

func report() {
    check("스킬을 찾았다", scanned.count > 10, "\(scanned.count)개")

    let names = Set(scanned.map(\.command))
    check("사용자 스킬 인식 (llmTrend)", names.contains("llmTrend"))
    check("플러그인 스킬 인식 (darwin: 접두사)", names.contains { $0.hasPrefix("darwin:") },
          scanned.filter { $0.command.hasPrefix("darwin:") }.count.description + "개")

    if let trino = scanned.first(where: { $0.command == "trino" }) {
        check("frontmatter description 파싱", !trino.summary.isEmpty,
              "\"\(trino.shortSummary.prefix(60))\"")
        check("TRIGGER 뒤를 카드 설명에서 잘라낸다", !trino.shortSummary.contains("TRIGGER"))
    } else {
        check("trino 스킬 발견", false)
    }

    print("\n=== 2. 파라미터 추론 ===")
    for cmd in ["llmTrend", "worklog-search", "trino", "naver-ask", "hbase-client"] {
        guard let s = scanned.first(where: { $0.command == cmd }) else {
            check("\(cmd) 추론", false, "스킬 없음")
            continue
        }
        let o = ParamInference.infer(skill: s)
        let keys = o.params.map(\.key).joined(separator: ", ")
        check("\(cmd) 추론", !o.promptTemplate.isEmpty,
              "params=[\(keys)] template=\"\(o.promptTemplate)\" 근거: \(o.evidence.prefix(70))")
        check("\(cmd) 템플릿이 커맨드로 시작", o.promptTemplate.hasPrefix("/\(cmd)"))
    }

    print("\n=== 3. 프롬프트 렌더링 ===")
    var card = SkillCard(title: "테스트",
                         command: "worklog-search",
                         params: [
                            ParamSpec(key: "keyword", label: "검색어"),
                            ParamSpec(key: "recent", label: "최근만", kind: .toggle, placeholder: "최근 것만"),
                            ParamSpec(key: "days", label: "일수", kind: .number),
                         ])
    card.promptTemplate = "/worklog-search {{keyword}} {{recent}} 최근 {{days}}일"
    let filled = card.renderPrompt(values: ["keyword": "crawler", "recent": "true", "days": "7"])
    check("값 치환", filled == "/worklog-search crawler 최근 것만 최근 7일", "\"\(filled)\"")

    let partial = card.renderPrompt(values: ["keyword": "crawler", "recent": "false"])
    check("꺼진 토글·빈 값은 자리를 남기지 않는다",
          !partial.contains("{{") && !partial.contains("  "), "\"\(partial)\"")

    print("\n=== 4. 설정 직렬화 ===")
    var cfg = AppConfig()
    cfg.cards = [card]
    cfg.openPopoverHotkey = HotKeySpec(keyCode: 40, modifiers: HotKeyFormatter.cmd | HotKeyFormatter.option)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    do {
        let data = try enc.encode(cfg)
        let back = try dec.decode(AppConfig.self, from: data)
        check("왕복 후 카드 수 유지", back.cards.count == 1)
        check("왕복 후 파라미터 유지", back.cards.first?.params.count == 3)
        check("단축키 표시", back.openPopoverHotkey?.displayString == "⌥⌘K",
              back.openPopoverHotkey?.displayString ?? "nil")
    } catch {
        check("설정 직렬화", false, "\(error)")
    }

    print("\n=== 5. 마크다운 파서 ===")
    let md = """
    # 제목
    본문 **강조** 문장.

    - 항목 1
    - 항목 2

    | 열A | 열B |
    |---|---|
    | 1 | 2 |

    ```bash
    echo hi
    ```
    """
    let blocks = MarkdownParser.parse(md)
    check("블록 개수", blocks.count == 5, "\(blocks.count)개")
    var sawTable = false, sawCode = false, sawList = false
    for b in blocks {
        if case .table = b { sawTable = true }
        if case .code = b { sawCode = true }
        if case .list = b { sawList = true }
    }
    check("표 인식", sawTable)
    check("코드 블록 인식", sawCode)
    check("목록 인식", sawList)

    print("\n=== 6. claude 실행 파일 탐색 ===")
    // CLI 설치는 환경 조건이라 없다고 코드가 틀린 건 아니다. 실패로 세지 않고 알려만 준다.
    if let path = ConfigStore.shared.resolveClaudePath() {
        check("claude 경로 확인", true, path)
    } else {
        print("NOTE  claude 를 찾지 못했다 — `npm i -g @anthropic-ai/claude-code` 로 설치하거나 설정에 경로를 넣어야 실행된다")
    }
    // 데스크톱 앱의 VM 바이너리(ELF)를 실행 후보로 잡으면 exec format error 가 난다.
    let vmBinary = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-vm/2.1.197/claude").path
    if FileManager.default.isExecutableFile(atPath: vmBinary) {
        check("리눅스(ELF) 바이너리를 걸러낸다", !ConfigStore.isRunnable(vmBinary))
    }

    print("\n=== 7. 동적 토큰 ===")
    let todayString = { () -> String in
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }()
    let expanded = PromptToken.expandAll(in: "{{today}} 부터 {{weekAgo}} 까지 {{downloads}} 에")
    check("오늘 토큰 전개", expanded.contains(todayString), expanded)
    check("모르는 토큰은 남긴다", PromptToken.expandAll(in: "{{nope}}") == "{{nope}}")

    var tokenCard = SkillCard(title: "토큰",
                              command: "llmTrend",
                              params: [ParamSpec(key: "date", label: "날짜", kind: .date,
                                                 defaultValue: PromptToken.today.placeholder)])
    tokenCard.promptTemplate = "/llmTrend {{date}} 기준"
    let rendered = tokenCard.renderPrompt(values: [:])
    check("기본값 토큰이 실행 시점 값으로 바뀐다", rendered == "/llmTrend \(todayString) 기준", rendered)

    print("\n=== 8. 프리필 · 원클릭 판정 ===")
    let body = """
    ## 옵션
    | 옵션 | 설명 |
    |---|---|
    | --limit | 가져올 개수 (기본값: `20`) |

    ```bash
    tool --env dev --date 2026-01-01
    ```
    """
    let specs = [ParamSpec(key: "limit", label: "개수", kind: .number),
                 ParamSpec(key: "env", label: "환경", kind: .select, options: ["dev", "stage", "real"]),
                 ParamSpec(key: "date", label: "날짜", kind: .date),
                 ParamSpec(key: "query", label: "검색어", kind: .text, required: true)]
    let pf = Prefill.fill(params: specs, body: body)
    func value(_ key: String) -> String { pf.params.first { $0.key == key }?.defaultValue ?? "" }
    check("본문 기본값 표기를 읽는다", value("limit") == "20", "limit=\(value("limit"))")
    check("예시 명령의 플래그 값을 읽는다", value("env") == "dev", "env=\(value("env"))")
    check("본문의 굳은 날짜는 오늘 토큰으로 바꾼다",
          value("date") == PromptToken.today.placeholder, "date=\(value("date"))")
    check("사람만 아는 값은 비워 둔다", value("query").isEmpty)
    check("기본값이 채워진 항목은 필수에서 내려간다",
          pf.params.first { $0.key == "limit" }?.required == false)

    var ready = SkillCard(title: "준비됨", command: "llmTrend", params: pf.params)
    check("필수 항목이 남아 폼이 열린다", !ready.isReadyToRun,
          "미충족 \(ready.missingRequired().map(\.key).joined(separator: ","))")
    ready.params.removeAll { $0.key == "query" }
    check("전부 채우면 원클릭 대상", ready.runsOnSingleClick && ready.isReadyToRun)
    ready.instantRun = false
    check("원클릭을 끄면 폼으로 간다", !ready.runsOnSingleClick)

    print("\n=== 9. MCP 서버 스캔 ===")
    let servers = MCPCatalog.scanSynchronously()
    check("MCP 서버를 찾았다", !servers.isEmpty, "\(servers.count)개")
    check("전송 방식을 판별한다", servers.contains { $0.transport == .http || $0.transport == .stdio },
          servers.prefix(3).map { "\($0.name)(\($0.transport.label))" }.joined(separator: ", "))
    if let first = servers.first {
        let mcpCard = first.makeCard()
        check("MCP 카드는 즉시 실행 가능", mcpCard.runsOnSingleClick,
              "\"\(mcpCard.renderPrompt(values: mcpCard.defaultValues).prefix(80))\"")
        check("도구 접두어가 프롬프트에 들어간다",
              mcpCard.promptTemplate.contains("mcp__\(first.name)__"))
    }
    // 비밀값이 카드나 서버 정보로 새지 않는지 확인한다.
    let leaked = servers.contains { $0.endpoint.lowercased().contains("key") || $0.endpoint.contains("AQ.") }
    check("엔드포인트에 비밀값이 섞이지 않는다", !leaked)

    print("\n결과: \(failures == 0 ? "전부 통과" : "\(failures)건 실패")")
}

RunLoop.main.run()
