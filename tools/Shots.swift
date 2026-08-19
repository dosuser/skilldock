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
    var trend = SkillCard(title: "Trend Briefing",
                          subtitle: "Today's new items from GitHub, Hugging Face, and company blogs",
                          emoji: "🚀", tint: "#7C5CFF",
                          command: "llmTrend",
                          params: [ParamSpec(key: "request", label: "Additional request",
                                             help: "Leave blank to run the skill's default behavior.",
                                             kind: .longText,
                                             placeholder: "Example: focus on image generation models")])
    trend.hotkey = HotKeySpec(keyCode: 17, modifiers: HotKeyFormatter.cmd | HotKeyFormatter.option) // ⌥⌘T

    var ask = SkillCard(title: "Document Search",
                        subtitle: "Search internal docs and collect sources",
                        emoji: "🔍", tint: "#12B5CB",
                        command: "naver-ask",
                        params: [
                            ParamSpec(key: "query", label: "Search query", help: "Describe the document you need in one line.",
                                      kind: .text, placeholder: "Example: latest brand guide", required: true),
                            ParamSpec(key: "output", label: "Save folder", kind: .path, placeholder: "~/Documents"),
                        ])
    ask.hotkey = HotKeySpec(keyCode: 2, modifiers: HotKeyFormatter.cmd | HotKeyFormatter.option) // ⌥⌘D

    var worklog = SkillCard(title: "Worklog Summary",
                            subtitle: "Summarize the last seven days in one page",
                            emoji: "📝", tint: "#3DC98B",
                            command: "worklog-search",
                            promptTemplate: "/worklog-search summarize up to {{limit}} worklogs since {{since}}",
                            params: [
                                ParamSpec(key: "since", label: "Start date", kind: .date,
                                          defaultValue: PromptToken.weekAgo.placeholder),
                                ParamSpec(key: "limit", label: "Limit", kind: .number, defaultValue: "10"),
                            ])
    worklog.hotkey = HotKeySpec(keyCode: 13, modifiers: HotKeyFormatter.cmd | HotKeyFormatter.option) // ⌥⌘W

    var weekly = SkillCard(title: "Weekly Report Draft",
                           subtitle: "Create a weekly-report draft from Jira issues",
                           emoji: "📊", tint: "#FF7043",
                           command: "weekly-report",
                           params: [
                               ParamSpec(key: "week", label: "Week", kind: .date,
                                         defaultValue: PromptToken.today.placeholder),
                               ParamSpec(key: "scope", label: "Scope", kind: .select,
                                         options: ["My issues", "Group", "Whole team"], defaultValue: "Group"),
                           ])
    weekly.hotkey = HotKeySpec(keyCode: 15, modifiers: HotKeyFormatter.cmd | HotKeyFormatter.option) // ⌥⌘R

    // MCP 서버에서 만든 카드 — 요청 문장이 미리 채워져 그대로 실행된다.
    var mcp = MCPServer(name: "metrics-mcp", transport: .http, endpoint: "metrics.example.com",
                        scope: .user, configPath: "~/.claude.json").makeCard()
    mcp.hotkey = HotKeySpec(keyCode: 46, modifiers: HotKeyFormatter.cmd | HotKeyFormatter.option) // ⌥⌘M

    return [trend, ask, worklog, weekly, mcp]
}

/// 카드 편집 화면 촬영용 껍데기 (CardEditorView 는 Binding 을 받는다).
struct EditorShot: View {
    @State var card: SkillCard
    var body: some View { CardEditorView(card: $card, onDelete: {}) }
}

let sampleResult = """
# LLM Trends — 2026-08-13

**Seven new items published today**, excluding items in yesterday's report.

## GitHub Rising

| Project | Stars | Summary |
|---|---|---|
| acme/fastvlm | +2,140 | On-device vision-language model |
| oss/agent-mesh | +880 | Agent-to-agent message routing |

## Company announcements

- **Anthropic** — Tool-call cache reduces repeat-call cost by 40%
- **Google DeepMind** — Long-context summarization benchmark update

> 58% new items compared with yesterday (7 of 12)

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
            print("FAIL  \(name) — render failed")
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
                  then: { print("Done — \(outDir.path)"); exit(0) })
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { step1() }
app.run()
