// 실제 NSWindow + NSHostingView 를 화면 밖에 띄워 창 내용을 PNG 로 저장한다.
// 화면 캡처 권한 없이도 실물과 같은 렌더 결과를 얻는다 (ImageRenderer 는 TextField·Lazy 컨테이너를 못 그린다).
// 빌드/실행: ./tools/shots.sh  → build/shots/*.png
import AppKit
import SwiftUI

ConfigStore.persistenceEnabled = false

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "build/shots")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: 샘플 데이터

func sampleCards() -> [SkillCard] {
    var trend = SkillCard(title: "트렌드 브리핑",
                          subtitle: "GitHub·HuggingFace·업체 블로그에서 오늘 새로 뜬 것만 정리",
                          emoji: "🚀", tint: "#7C5CFF",
                          command: "llmTrend",
                          params: [ParamSpec(key: "request", label: "추가 요청",
                                             help: "비워두면 스킬 기본 동작으로 실행됩니다.",
                                             kind: .longText,
                                             placeholder: "예: 이미지 생성 모델만 골라줘")])
    trend.hotkey = HotKeySpec(keyCode: 40, modifiers: HotKeyFormatter.cmd | HotKeyFormatter.option)

    let ask = SkillCard(title: "사내 문서 검색",
                        subtitle: "사내 문서에 물어보고 출처까지 정리",
                        emoji: "🔍", tint: "#12B5CB",
                        command: "naver-ask",
                        params: [
                            ParamSpec(key: "query", label: "검색어", help: "찾고 싶은 문서를 한 줄로 적습니다.",
                                      kind: .text, placeholder: "예: 브랜드 가이드 최신본", required: true),
                            ParamSpec(key: "output", label: "저장 폴더", kind: .path, placeholder: "~/Documents"),
                        ])

    let worklog = SkillCard(title: "작업일지 요약",
                            subtitle: "지난 7일 일지를 한 장으로 요약",
                            emoji: "📝", tint: "#3DC98B",
                            command: "worklog-search",
                            promptTemplate: "/worklog-search {{since}} 이후 일지를 {{limit}}건까지 요약해줘",
                            params: [
                                ParamSpec(key: "since", label: "시작 날짜", kind: .date,
                                          defaultValue: PromptToken.weekAgo.placeholder),
                                ParamSpec(key: "limit", label: "개수", kind: .number, defaultValue: "10"),
                            ])

    let weekly = SkillCard(title: "주간 보고 초안",
                           subtitle: "Jira 이슈를 모아 주간 보고 초안 생성",
                           emoji: "📊", tint: "#FF7043",
                           command: "weekly-report",
                           params: [
                               ParamSpec(key: "week", label: "기준 주", kind: .date,
                                         defaultValue: PromptToken.today.placeholder),
                               ParamSpec(key: "scope", label: "범위", kind: .select,
                                         options: ["내 이슈", "파트", "팀 전체"], defaultValue: "파트"),
                           ])

    // MCP 서버에서 만든 카드 — 요청 문장이 미리 채워져 그대로 실행된다.
    let mcp = MCPServer(name: "metrics-mcp", transport: .http, endpoint: "metrics.example.com",
                        scope: .user, configPath: "~/.claude.json").makeCard()

    return [trend, ask, worklog, weekly, mcp]
}

/// 카드 편집 화면 촬영용 껍데기 (CardEditorView 는 Binding 을 받는다).
struct EditorShot: View {
    @State var card: SkillCard
    var body: some View { CardEditorView(card: $card, onDelete: {}) }
}

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

// MARK: 오프스크린 촬영

final class Shooter {
    private var window: NSWindow?

    /// SwiftUI 텍스트는 레이어 콘텐츠로 그려지므로 `cacheDisplay` 로는 잡히지 않는다.
    /// 레이어 트리를 직접 렌더해야 글자까지 나온다.
    static func pngFromLayer(of view: NSView, scale: CGFloat = 2) -> Data? {
        guard let layer = view.layer else { return nil }
        let w = Int(view.bounds.width * scale)
        let h = Int(view.bounds.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 창 배경을 먼저 깔아 투명 영역이 검게 나오지 않게 한다.
        if let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)?.cgColor {
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage(),
              // `layer.render(in:)` 결과는 아래에서 위로 쌓인다. PNG 는 위에서 아래로 읽으므로
              // 마지막에 한 번 뒤집어야 화면과 같은 그림이 된다.
              let upright = Shooter.flippedVertically(image) else { return nil }
        let rep = NSBitmapImageRep(cgImage: upright)
        return rep.representation(using: .png, properties: [:])
    }

    /// CGImage 의 위아래를 뒤집는다.
    static func flippedVertically(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 화면 밖에 창을 만들어 뷰를 실제로 배치한 뒤 PNG 로 저장한다.
    func shoot<V: View>(_ name: String, size: CGSize, view: V, settle: TimeInterval = 0.6,
                        then: @escaping () -> Void) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // ARC 환경에서 close() 가 추가 release 를 하면 이중 해제로 죽는다.
        w.isReleasedWhenClosed = false
        w.isOpaque = true
        w.backgroundColor = .windowBackgroundColor
        w.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        // 사용자 화면을 가리지 않도록 보이는 영역 밖에 둔다.
        w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        w.orderFrontRegardless()
        window = w

        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            guard let content = w.contentView else { then(); return }
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()

            if let png = Shooter.pngFromLayer(of: content) {
                let url = outDir.appendingPathComponent("\(name).png")
                try? png.write(to: url)
                print("PASS  \(name) → \(url.lastPathComponent) (\(png.count / 1024)KB)")
            } else {
                print("FAIL  \(name) — 렌더 실패")
            }
            w.close()
            self.window = nil
            then()
        }
    }
}

// MARK: 실행 순서

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let shooter = Shooter()
let router = PopoverRouter()
let popoverSize = CGSize(width: Theme.popoverWidth, height: Theme.popoverHeight)

func step1() {
    ConfigStore.shared.config.cards = sampleCards()
    shooter.shoot("01-home", size: popoverSize,
                  view: HomeView(router: router, onOpenLibrary: {}, onQuit: {}),
                  then: step2)
}

func step2() {
    // 값이 미리 채워진 카드를 찍는다 — 폼을 열어도 그대로 실행만 누르면 되는 상태.
    let card = ConfigStore.shared.config.cards[2]
    shooter.shoot("02-run-form", size: popoverSize,
                  view: RunView(card: card, router: router, onOpenLibrary: {}),
                  then: step3)
}

func step3() {
    shooter.shoot("03-result", size: CGSize(width: Theme.popoverWidth, height: 700),
                  view: ScrollView { MarkdownView(text: sampleResult, tint: "#7C5CFF").padding(14) },
                  then: step4)
}

func step4() {
    shooter.shoot("04-library", size: CGSize(width: 940, height: 660),
                  view: LibraryView(), settle: 1.0, then: step5)
}

func step5() {
    let spec = ConfigStore.shared.config.cards[1].params[0]
    shooter.shoot("05-param-editor", size: CGSize(width: 520, height: 430),
                  view: ParamEditorSheet(spec: spec) { _ in }, then: step6)
}

// 카탈로그 화면은 이 컴퓨터의 실제 스킬·MCP 목록을 그대로 보여준다.
// 저장소에 올릴 이미지에 사내 스킬 이름이 섞이지 않도록, 여기서는 샘플 카드 편집 화면을 찍는다.
func step6() {
    shooter.shoot("06-oneclick", size: CGSize(width: 700, height: 640),
                  view: EditorShot(card: ConfigStore.shared.config.cards[2]),
                  settle: 1.0, then: step7)
}

func step7() {
    ConfigStore.shared.config.cards = []
    let empty = PopoverRouter()
    shooter.shoot("07-empty", size: popoverSize,
                  view: HomeView(router: empty, onOpenLibrary: {}, onQuit: {}),
                  then: { print("완료 — \(outDir.path)"); exit(0) })
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { step1() }
app.run()
