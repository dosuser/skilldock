// 화면을 PNG 로 렌더해서 눈으로 확인한다. 화면 캡처 권한 없이 UI 를 검증하는 경로.
// 빌드/실행: ./tools/preview.sh   → build/preview/*.png
import AppKit
import SwiftUI

ConfigStore.persistenceEnabled = false   // 실제 설정 파일을 건드리지 않는다

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "build/preview")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: 샘플 데이터

let samples: [SkillCard] = [
    {
        var c = SkillCard(title: "Trend Briefing",
                          subtitle: "Today's new items from GitHub, Hugging Face, and company blogs",
                          emoji: "🚀", tint: "#7C5CFF",
                          command: "llmTrend",
                          params: [ParamSpec(key: "request", label: "Additional request",
                                             help: "Leave blank to run the skill's default behavior.",
                                             kind: .longText,
                                             placeholder: "Example: focus on image generation models")])
        c.hotkey = HotKeySpec(keyCode: 40, modifiers: HotKeyFormatter.cmd | HotKeyFormatter.option)
        return c
    }(),
    // 필수 입력이 남아 있어 폼이 먼저 열리는 카드 (원클릭 카드와 대비된다).
    SkillCard(title: "Document Search",
              subtitle: "Search internal docs and collect sources",
              emoji: "🔍", tint: "#12B5CB",
              command: "naver-ask",
              params: [
                ParamSpec(key: "query", label: "Search query", kind: .text,
                          placeholder: "Example: latest brand guide", required: true),
                ParamSpec(key: "output", label: "Save folder", kind: .path,
                          defaultValue: PromptToken.documents.placeholder),
              ]),
    SkillCard(title: "Worklog Search",
              subtitle: "Summarize recent worklogs in one page",
              emoji: "📝", tint: "#3DC98B",
              command: "worklog-search",
              promptTemplate: "/worklog-search summarize up to {{limit}} worklogs since {{since}}",
              params: [
                ParamSpec(key: "since", label: "Start date", kind: .date,
                          defaultValue: PromptToken.weekAgo.placeholder),
                ParamSpec(key: "limit", label: "Limit", kind: .number, defaultValue: "10"),
              ]),
    SkillCard(title: "Weekly Report Draft",
              subtitle: "Create a weekly-report draft from Jira issues",
              emoji: "📊", tint: "#FF7043",
              command: "weekly-report",
              params: [
                ParamSpec(key: "week", label: "Week", kind: .date,
                          defaultValue: PromptToken.today.placeholder),
                ParamSpec(key: "env", label: "Scope", kind: .select,
                          options: ["My issues", "Group", "Whole team"], defaultValue: "Group"),
              ]),
    // MCP 서버에서 만든 카드 — 요청 문장이 미리 채워져 그대로 실행된다.
    MCPServer(name: "metrics-mcp", transport: .http, endpoint: "metrics.example.com",
              scope: .user, configPath: "~/.claude.json").makeCard(),
]

/// 카드 편집 화면을 렌더하기 위한 얇은 껍데기 (CardEditorView 는 Binding 을 받는다).
struct EditorPreview: View {
    @State var card: SkillCard
    var body: some View { CardEditorView(card: $card, onDelete: {}) }
}

ConfigStore.shared.config.cards = samples

let sampleResult = """
# LLM 트렌드 — 2026-08-13

**오늘 새로 올라온 항목 7건**을 정리했다. 어제 리포트에 있던 항목은 제외했다.

## GitHub 급상승

| 프로젝트 | 스타 | 한 줄 |
|---|---|---|
| acme/fastvlm | +2,140 | 온디바이스 비전-언어 모델 |
| oss/agent-mesh | +880 | 에이전트 간 메시지 라우팅 |

## 업체 발표

- **Anthropic** — 툴 실행 캐시 공개, 반복 호출 비용 40% 절감
- **Google DeepMind** — 장문 요약 벤치마크 갱신

> 어제 대비 신규 비율 58% (7건 / 12건)

```bash
open ~/llmTrend/2026-08-13.md
```
"""

// MARK: 렌더링

@MainActor
func snapshot<V: View>(_ name: String, size: CGSize, @ViewBuilder _ content: () -> V) {
    let view = content()
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    // nsImage → tiffRepresentation 경로는 상하가 뒤집힌 PNG 를 만든다. cgImage 를 직접 쓴다.
    guard let cg = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        print("FAIL  \(name) 렌더 실패")
        return
    }
    let url = outDir.appendingPathComponent("\(name).png")
    try? png.write(to: url)
    print("PASS  \(name) → \(url.path) (\(png.count / 1024)KB)")
}

let router = PopoverRouter()

MainActor.assumeIsolated {
    // 1. 메뉴바 팝오버 — 등록된 스킬 목록
    snapshot("01-home", size: CGSize(width: Theme.popoverWidth, height: Theme.popoverHeight)) {
        HomeView(router: router, onOpenLibrary: {}, onQuit: {})
    }

    // 2. 실행 폼 (입력 항목이 폼으로 뜬 상태)
    snapshot("02-run-form", size: CGSize(width: Theme.popoverWidth, height: Theme.popoverHeight)) {
        RunView(card: samples[1], router: router, onOpenLibrary: {})
    }

    // 3. 결과 마크다운 렌더링
    snapshot("03-result", size: CGSize(width: Theme.popoverWidth, height: 640)) {
        ScrollView {
            MarkdownView(text: sampleResult, tint: samples[0].tint).padding(13)
        }
    }

    // 4. 스킬 관리 창 — 카드 편집
    snapshot("04-library", size: CGSize(width: 940, height: 660)) {
        LibraryView()
    }

    // 4-1. 원클릭 설정 블록 (준비 상태 · 자동 채우기 · 실행 문장 미리보기)
    snapshot("04-oneclick", size: CGSize(width: 700, height: 620)) {
        EditorPreview(card: samples[2])
    }

    // 5. 입력 항목 편집 시트
    snapshot("05-param-editor", size: CGSize(width: 520, height: 420)) {
        ParamEditorSheet(spec: samples[1].params[0]) { _ in }
    }

    // 6. 빈 상태 (첫 실행)
    snapshot("06-empty", size: CGSize(width: Theme.popoverWidth, height: Theme.popoverHeight)) {
        let empty = PopoverRouter()
        ConfigStore.shared.config.cards = []
        return HomeView(router: empty, onOpenLibrary: {}, onQuit: {})
    }
}

print("완료 — \(outDir.path)")
