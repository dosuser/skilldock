import SwiftUI
import AppKit

// MARK: - 화면 이동 / 실행기 보관

final class PopoverRouter: ObservableObject {
    enum Route: Equatable {
        case home
        case run(UUID)
    }
    @Published var route: Route = .home
    @Published var search: String = ""

    func open(card: SkillCard) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { route = .run(card.id) }
    }
    func home() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { route = .home; search = "" }
    }
}

/// 카드별 실행기를 보관한다. 팝오버를 닫아도 실행은 계속되고 결과가 남는다.
final class RunnerRegistry: ObservableObject {
    static let shared = RunnerRegistry()
    private var runners: [UUID: SkillRunner] = [:]

    func runner(for id: UUID) -> SkillRunner {
        if let r = runners[id] { return r }
        let r = SkillRunner()
        runners[id] = r
        return r
    }

    var busyCardIDs: Set<UUID> {
        Set(runners.filter { $0.value.state.isRunning }.map(\.key))
    }

    /// 폼을 거치지 않고 카드를 실행한다.
    ///
    /// 값은 `마지막 입력값 → 카드 기본값` 순으로 채운다. 필수 항목이 비어 있으면 실행하지 않고
    /// false 를 돌려준다 (호출한 쪽이 폼을 열어야 한다).
    @discardableResult
    func launch(card: SkillCard) -> Bool {
        var values = LastValues.load(card.id)
        for p in card.params where (values[p.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            values[p.key] = p.defaultValue
        }
        guard card.missingRequired(values: values).isEmpty else { return false }

        let r = runner(for: card.id)
        if r.state.isRunning { return true }
        r.reset()
        r.start(card: card, values: values)
        ConfigStore.shared.markRun(id: card.id)
        return true
    }
}

/// 마지막으로 입력한 값을 카드별로 기억한다.
enum LastValues {
    static func load(_ cardID: UUID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "values.\(cardID.uuidString)") as? [String: String] ?? [:]
    }
    static func save(_ cardID: UUID, _ values: [String: String]) {
        UserDefaults.standard.set(values, forKey: "values.\(cardID.uuidString)")
    }
}

// MARK: - 루트

struct PopoverRootView: View {
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var router: PopoverRouter
    var onOpenLibrary: () -> Void
    var onQuit: () -> Void

    var body: some View {
        ZStack {
            switch router.route {
            case .home:
                HomeView(router: router, onOpenLibrary: onOpenLibrary, onQuit: onQuit)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            case .run(let id):
                if let card = store.card(id: id) {
                    RunView(card: card, router: router, onOpenLibrary: onOpenLibrary)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    EmptyStateView(symbol: "questionmark.folder",
                                   title: "Skill not found",
                                   message: "This skill has been removed.",
                                   actionTitle: "Back to list") { router.home() }
                }
            }
        }
        .frame(width: Theme.popoverWidth, height: Theme.popoverHeight)
    }
}

// MARK: - 홈: 등록된 스킬 목록

struct HomeView: View {
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var registry = RunnerRegistry.shared
    @ObservedObject var router: PopoverRouter
    var onOpenLibrary: () -> Void
    var onQuit: () -> Void

    private var filtered: [SkillCard] {
        let q = router.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.config.cards }
        return store.config.cards.filter {
            $0.title.lowercased().contains(q)
                || $0.subtitle.lowercased().contains(q)
                || $0.command.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.config.cards.isEmpty {
                EmptyStateView(symbol: "square.stack.3d.up.slash",
                               title: "No saved skills",
                               message: "Add a skill to run it here.\nSkillsOnMenu finds available skills automatically.",
                               actionTitle: "Add a skill") { onOpenLibrary() }
            } else {
                searchField
                list
            }
            footer
        }
        .background(Color.clear)
    }

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#7C5CFF"), Color(hex: "#12B5CB")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "bolt.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 0) {
                Text("SkillsOnMenu").font(Theme.title(14, .bold))
                Text("Run any skill in one click")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onOpenLibrary) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Manage skills and settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search skills", text: $router.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !router.search.isEmpty {
                Button {
                    router.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.subtleFill))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            // 등록 카드는 보통 수십 개 이하라 즉시 배치한다 (지연 배치는 스크롤 위치 튐만 만든다).
            VStack(spacing: 6) {
                ForEach(filtered) { card in
                    SkillRow(card: card,
                             isRunning: registry.runner(for: card.id).state.isRunning,
                             onPrimary: { run(card) },
                             onOpenForm: { router.open(card: card) })
                }
                if filtered.isEmpty {
                    Text("No results")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    /// 카드를 눌렀을 때. 준비된 카드는 바로 실행하고, 입력이 필요한 카드는 폼을 연다.
    private func run(_ card: SkillCard) {
        guard card.runsOnSingleClick, registry.launch(card: card) else {
            router.open(card: card)
            return
        }
        router.open(card: card)   // 진행 상황을 볼 수 있게 실행 화면으로 넘긴다
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onOpenLibrary()
            } label: {
                Label("Add skill", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(SubtleButtonStyle())

            Spacer()

            if let hk = store.config.openPopoverHotkey {
                Text(hk.displayString)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.subtleFill))
            }
            Button {
                onQuit()
            } label: {
                Image(systemName: "power").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Quit SkillsOnMenu")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.25))
    }
}

private struct SkillRow: View {
    let card: SkillCard
    let isRunning: Bool
    /// 카드 본체를 눌렀을 때 — 준비된 카드는 즉시 실행.
    let onPrimary: () -> Void
    /// 입력값을 손보고 싶을 때 여는 폼.
    let onOpenForm: () -> Void
    @State private var hovering = false

    private var oneClick: Bool { card.runsOnSingleClick }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onPrimary) {
                HStack(spacing: 10) {
                    EmojiBadge(emoji: card.emoji, tint: card.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(card.title).font(Theme.title(13, .semibold))
                            if isRunning { PulsingDots(tint: card.tint) }
                        }
                        Text(subtitleText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let hk = card.hotkey {
                        Text(hk.displayString)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    // 원클릭 카드는 ▶, 입력이 필요한 카드는 › 로 구분한다.
                    Image(systemName: oneClick ? "play.circle.fill" : "chevron.right")
                        .font(.system(size: oneClick ? 15 : 10, weight: .semibold))
                        .foregroundStyle(oneClick ? Color(hex: card.tint) : Color.secondary.opacity(0.55))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(oneClick ? "Run immediately" : "Fill in inputs before running")

            // 원클릭 카드에서도 값을 바꿔 실행할 수 있는 통로를 남긴다.
            if oneClick, hovering {
                Button(action: onOpenForm) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
                .buttonStyle(.plain)
                .help("Review and edit inputs")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(hovering ? Color(hex: card.tint).opacity(0.11) : Theme.subtleFill.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color(hex: card.tint).opacity(hovering ? 0.35 : 0.0), lineWidth: 1)
        )
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var subtitleText: String {
        let missing = card.missingRequired().count
        if missing > 0 { return "\(missing) input\(missing == 1 ? "" : "s") needed · \(card.subtitle.isEmpty ? "/\(card.command)" : card.subtitle)" }
        return card.subtitle.isEmpty ? "/\(card.command)" : card.subtitle
    }
}

// MARK: - 실행 화면

struct RunView: View {
    let card: SkillCard
    @ObservedObject var router: PopoverRouter
    var onOpenLibrary: () -> Void

    @ObservedObject private var runner: SkillRunner
    @State private var values: [String: String]
    @State private var showLog = false
    @State private var copied = false

    init(card: SkillCard, router: PopoverRouter, onOpenLibrary: @escaping () -> Void) {
        self.card = card
        self.router = router
        self.onOpenLibrary = onOpenLibrary
        self.runner = RunnerRegistry.shared.runner(for: card.id)
        var seed = LastValues.load(card.id)
        for p in card.params where seed[p.key] == nil {
            seed[p.key] = p.defaultValue
        }
        _values = State(initialValue: seed)
    }

    private var missingRequired: [ParamSpec] {
        card.params.filter { $0.required && (values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            actionBar
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button { router.home() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)

            EmojiBadge(emoji: card.emoji, tint: card.tint, size: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(card.title).font(Theme.title(13.5, .bold))
                Text("/\(card.command)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch runner.state {
        case .idle: EmptyView()
        case .running: StatusPill(text: String(format: "%.0f초", runner.elapsed), color: Color(hex: card.tint))
        case .success: StatusPill(text: "완료", color: .green)
        case .failed: StatusPill(text: "실패", color: .red)
        case .cancelled: StatusPill(text: "중단", color: .orange)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch runner.state {
        case .idle:
            formPane
        case .running:
            runningPane
        case .success:
            resultPane
        case .failed(let message):
            failurePane(message)
        case .cancelled:
            VStack(spacing: 12) {
                EmptyStateView(symbol: "stop.circle",
                               title: "Stopped",
                               message: "Run again or change the inputs.")
            }
        }
    }

    // 입력 폼
    private var formPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                if !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if card.params.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles").foregroundStyle(Color(hex: card.tint))
                        Text("Ready to run with no additional input.").font(.system(size: 12))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.subtleFill))
                } else {
                    if card.isReadyToRun {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: card.tint))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Values are prefilled — run as is.")
                                    .font(.system(size: 11.5))
                                if card.usesDynamicTokens {
                                    Text("Dates and folders resolve when the skill runs.")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: card.tint).opacity(0.1)))
                    }
                    ForEach(card.params) { p in
                        ParamField(spec: p, tint: card.tint, value: binding(for: p))
                    }
                }

                DisclosureGroup {
                    Text(card.renderPrompt(values: values))
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtleFill))
                } label: {
                    SectionLabel(text: "Command preview")
                }
                .font(.system(size: 11))
            }
            .padding(13)
        }
    }

    // 실행 중
    private var runningPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(runner.currentStep.isEmpty ? "Running" : runner.currentStep)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Color(hex: card.tint).opacity(0.09))

            activityList
        }
    }

    private var activityList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(runner.activity) { line in
                        ActivityRow(line: line, tint: card.tint)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: runner.activity.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // 결과
    private var resultPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(String(format: "%.1f초 · $%.4f", runner.elapsed, runner.costUSD))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(showLog ? "View result" : "Activity log") {
                        withAnimation { showLog.toggle() }
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                if showLog {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(runner.activity) { ActivityRow(line: $0, tint: card.tint) }
                    }
                } else {
                    MarkdownView(text: runner.resultMarkdown, tint: card.tint)
                }
            }
            .padding(13)
        }
    }

    private func failurePane(_ message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))

                SectionLabel(text: "Activity log")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(runner.activity) { ActivityRow(line: $0, tint: card.tint) }
                }
            }
            .padding(13)
        }
    }

    // 아래 버튼 줄
    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 8) {
            switch runner.state {
            case .idle:
                Button {
                    LastValues.save(card.id, values)
                    runner.start(card: card, values: values)
                } label: {
                    Label(missingRequired.isEmpty ? "Run" : "Fill in required inputs",
                          systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: card.tint, disabled: !missingRequired.isEmpty))
                .disabled(!missingRequired.isEmpty)

            case .running:
                Button {
                    runner.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(SubtleButtonStyle())
                Spacer()
                Text("It keeps running when you close this popover")
                    .font(.system(size: 10)).foregroundStyle(.secondary)

            case .success, .failed, .cancelled:
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.resultMarkdown, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(runner.resultMarkdown.isEmpty)

                if let url = runner.savedResultURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open file", systemImage: "doc.text")
                    }
                    .buttonStyle(SubtleButtonStyle())
                }

                Spacer()

                Button {
                    runner.reset()
                } label: {
                    Label("Run again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.25))
    }

    private func binding(for spec: ParamSpec) -> Binding<String> {
        Binding(
            get: { values[spec.key] ?? spec.defaultValue },
            set: { values[spec.key] = $0 }
        )
    }
}

// MARK: - 진행 로그 한 줄

private struct ActivityRow: View {
    let line: ActivityLine
    let tint: String

    private var color: Color {
        switch line.kind {
        case .info: return .secondary
        case .thinking: return Color(hex: tint)
        case .tool: return Color(hex: tint)
        case .text: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: line.symbol)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 13)
                .padding(.top, 1.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .font(.system(size: 11.5, weight: line.kind == .tool ? .semibold : .regular))
                    .foregroundStyle(line.kind == .info ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !line.detail.isEmpty, line.detail != line.title {
                    Text(line.detail)
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 파라미터 입력 위젯

struct ParamField: View {
    let spec: ParamSpec
    let tint: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(spec.label).font(.system(size: 11.5, weight: .semibold))
                if spec.required {
                    Text("REQUIRED").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: tint))
                }
                Spacer()
            }
            control
            // 토큰은 값을 그대로 두고(다음 실행에도 갱신되도록) 지금 무엇이 될지만 알려준다.
            if PromptToken.containsToken(value) {
                Text("At runtime → \(PromptToken.expandAll(in: value))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(hex: tint))
            }
            if !spec.help.isEmpty {
                Text(spec.help).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch spec.kind {
        case .text, .number:
            TextField(spec.placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(fieldBackground)

        case .longText:
            TextEditor(text: $value)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 62, maxHeight: 92)
                .padding(.horizontal, 5).padding(.vertical, 4)
                .background(fieldBackground)
                .overlay(alignment: .topLeading) {
                    if value.isEmpty, !spec.placeholder.isEmpty {
                        Text(spec.placeholder)
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }

        case .toggle:
            Toggle(isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" })) {
                Text(spec.placeholder.isEmpty ? "Enter a value" : spec.placeholder).font(.system(size: 11.5))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

        case .select:
            Picker("", selection: $value) {
                ForEach(spec.options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

        case .date:
            HStack(spacing: 6) {
                TextField("2026-08-13", text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(fieldBackground)
                Button("Today") {
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                    value = f.string(from: Date())
                }
                .buttonStyle(SubtleButtonStyle())
            }

        case .path:
            HStack(spacing: 6) {
                TextField(spec.placeholder.isEmpty ? "경로" : spec.placeholder, text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(fieldBackground)
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { value = url.path }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.controlRadius - 1, style: .continuous)
            .fill(Theme.subtleFill)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius - 1, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.5), lineWidth: 0.5)
            )
    }
}
