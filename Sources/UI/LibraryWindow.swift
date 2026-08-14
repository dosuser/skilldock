import SwiftUI
import AppKit
import ServiceManagement

// MARK: - 창 컨트롤러

final class LibraryWindowController: NSWindowController {
    static let shared = LibraryWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SkillDock — 스킬 관리"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.minSize = NSSize(width: 820, height: 540)
        window.contentView = NSHostingView(rootView: LibraryView())
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("사용하지 않음") }

    func present() {
        SkillCatalog.shared.refresh()
        MCPCatalog.shared.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 본문

struct LibraryView: View {
    enum Selection: Hashable {
        case card(UUID)
        case settings
    }

    @ObservedObject private var store = ConfigStore.shared
    @State private var selection: Selection? = .settings
    @State private var showCatalog = false

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 250, idealWidth: 270, maxWidth: 340)
            detail.frame(minWidth: 520)
        }
        .frame(minWidth: 820, minHeight: 540)
        .sheet(isPresented: $showCatalog) {
            CatalogPickerView { newCards in
                for card in newCards { store.upsert(card) }
                if let last = newCards.last { selection = .card(last.id) }
            }
        }
        .onAppear {
            if selection == .settings, let first = store.config.cards.first {
                selection = .card(first.id)
            }
        }
    }

    // MARK: 사이드바

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("등록된 스킬").font(Theme.title(13, .bold))
                Spacer()
                Text("\(store.config.cards.count)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 8)

            List(selection: $selection) {
                ForEach(store.config.cards) { card in
                    HStack(spacing: 9) {
                        EmojiBadge(emoji: card.emoji, tint: card.tint, size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(card.title).font(.system(size: 12.5, weight: .medium))
                            Text("/\(card.command)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let hk = card.hotkey {
                            Text(hk.displayString)
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(Selection.card(card.id))
                    .contextMenu {
                        Button("복제") { duplicate(card) }
                        Button("삭제", role: .destructive) { store.remove(id: card.id) }
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    showCatalog = true
                } label: {
                    Label("스킬 추가", systemImage: "plus").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(SubtleButtonStyle())

                Spacer()

                Button {
                    selection = .settings
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("앱 설정")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    // MARK: 상세

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .card(let id):
            if let idx = store.config.cards.firstIndex(where: { $0.id == id }) {
                CardEditorView(card: Binding(
                    get: { store.config.cards[idx] },
                    set: { store.config.cards[idx] = $0 }
                ), onDelete: {
                    store.remove(id: id)
                    selection = store.config.cards.first.map { Selection.card($0.id) } ?? .settings
                })
                .id(id)
            } else {
                EmptyStateView(symbol: "questionmark.square.dashed",
                               title: "선택된 스킬이 없습니다",
                               message: "왼쪽에서 스킬을 고르거나 새로 추가하세요.")
            }
        case .settings:
            SettingsView()
        case .none:
            EmptyStateView(symbol: "square.stack.3d.up",
                           title: "스킬을 골라주세요",
                           message: "왼쪽 목록에서 스킬을 선택하면 여기에서 편집할 수 있습니다.",
                           actionTitle: "스킬 추가") { showCatalog = true }
        }
    }

    private func duplicate(_ card: SkillCard) {
        var copy = card
        copy.id = UUID()
        copy.title = card.title + " 사본"
        copy.hotkey = nil
        store.upsert(copy)
        selection = .card(copy.id)
    }
}

// MARK: - 카드 편집

struct CardEditorView: View {
    @Binding var card: SkillCard
    var onDelete: () -> Void

    @State private var aiBusy = false
    @State private var message: String?
    @State private var editingParam: ParamSpec?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBlock
                oneClickBlock
                appearanceBlock
                commandBlock
                paramBlock
                runBlock
                hotkeyBlock
                dangerBlock
            }
            .padding(24)
            .padding(.top, 14)
            .frame(maxWidth: 660, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $editingParam) { spec in
            ParamEditorSheet(spec: spec) { updated in
                if let idx = card.params.firstIndex(where: { $0.id == updated.id }) {
                    card.params[idx] = updated
                }
            }
        }
    }

    // 헤더 (미리보기)
    private var headerBlock: some View {
        HStack(spacing: 12) {
            EmojiBadge(emoji: card.emoji, tint: card.tint, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.isEmpty ? "이름 없는 스킬" : card.title).font(Theme.title(18, .bold))
                Text(card.subtitle.isEmpty ? "/\(card.command)" : card.subtitle)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // 원클릭 실행
    private var oneClickBlock: some View {
        Group {
            SectionLabel(text: "원클릭 실행")
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Image(systemName: card.isReadyToRun ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(card.isReadyToRun ? .green : .orange)
                    if card.isReadyToRun {
                        Text("준비됨 — 목록에서 누르면 그대로 실행됩니다.").font(.system(size: 12))
                    } else {
                        Text("입력 \(card.missingRequired().count)개가 비어 있어 폼이 먼저 열립니다.")
                            .font(.system(size: 12))
                    }
                    Spacer()
                    Button("빈 값 자동 채우기") { autofill() }
                        .buttonStyle(SubtleButtonStyle())
                }
                Toggle(isOn: $card.instantRun) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("목록에서 누르면 바로 실행").font(.system(size: 12))
                        Text("끄면 항상 입력 폼을 먼저 보여줍니다.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if card.usesDynamicTokens {
                    Label("날짜·폴더 토큰이 들어 있어 실행할 때마다 값이 갱신됩니다.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("지금 실행하면 이렇게 보냅니다").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(card.renderPrompt(values: card.defaultValues))
                        .font(Theme.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtleFill))
                }
            }
            .padding(14)
            .background(blockBackground)
        }
    }

    /// 비어 있는 기본값을 규칙으로 채워 즉시 실행 가능한 상태로 만든다.
    private func autofill() {
        let (updated, result) = Prefill.apply(to: card)
        card = updated
        if result.filledCount == 0 {
            message = "채울 수 있는 빈 값이 없습니다."
        } else {
            let reasons = result.evidence.values.prefix(2).joined(separator: " · ")
            message = "\(result.filledCount)개 채움\(reasons.isEmpty ? "" : " — \(reasons)")"
        }
    }

    // 표시
    private var appearanceBlock: some View {
        Group {
            SectionLabel(text: "표시")
            VStack(alignment: .leading, spacing: 11) {
                LabeledField("이름") {
                    TextField("예: 트렌드 브리핑", text: $card.title).textFieldStyle(.roundedBorder)
                }
                LabeledField("한 줄 설명") {
                    TextField("이 스킬이 무엇을 하는지", text: $card.subtitle).textFieldStyle(.roundedBorder)
                }
                LabeledField("아이콘") {
                    HStack(spacing: 5) {
                        TextField("✨", text: $card.emoji)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        ForEach(Theme.emojiChoices.prefix(12), id: \.self) { e in
                            Button { card.emoji = e } label: {
                                Text(e).font(.system(size: 15))
                                    .frame(width: 24, height: 24)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(card.emoji == e ? Theme.subtleFill.opacity(2) : Color.clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                LabeledField("색상") {
                    HStack(spacing: 6) {
                        ForEach(Theme.palette, id: \.self) { hex in
                            Button { card.tint = hex } label: {
                                Circle()
                                    .fill(Theme.gradient(hex))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(.primary.opacity(card.tint == hex ? 0.75 : 0),
                                                                   lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .background(blockBackground)
        }
    }

    // 스킬 / 프롬프트
    private var commandBlock: some View {
        Group {
            SectionLabel(text: "스킬")
            VStack(alignment: .leading, spacing: 11) {
                LabeledField("슬래시 커맨드") {
                    HStack(spacing: 5) {
                        Text("/").foregroundStyle(.secondary)
                        TextField("llmTrend", text: $card.command).textFieldStyle(.roundedBorder)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("실행 문장").font(.system(size: 11.5, weight: .semibold))
                        Spacer()
                        Text("{{항목이름}} 이 입력값으로 바뀝니다")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $card.promptTemplate)
                        .font(Theme.mono)
                        .scrollContentBackground(.hidden)
                        .frame(height: 64)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
                    HStack(spacing: 6) {
                        ForEach(card.params) { p in
                            Button("{{\(p.key)}}") {
                                card.promptTemplate += " {{\(p.key)}}"
                            }
                            .buttonStyle(SubtleButtonStyle())
                        }
                    }
                }
            }
            .padding(14)
            .background(blockBackground)
        }
    }

    // 파라미터
    private var paramBlock: some View {
        Group {
            HStack {
                SectionLabel(text: "입력 항목 (\(card.params.count))")
                Spacer()
                if aiBusy {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("스킬을 읽고 있습니다…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                } else {
                    Button("스킬에서 다시 추출") { rescan(useAI: false) }
                        .buttonStyle(SubtleButtonStyle())
                    Button("AI로 추출") { rescan(useAI: true) }
                        .buttonStyle(SubtleButtonStyle())
                }
            }
            VStack(spacing: 8) {
                ForEach(card.params) { p in
                    ParamRow(spec: p,
                             tint: card.tint,
                             onEdit: { editingParam = p },
                             onDelete: { card.params.removeAll { $0.id == p.id } })
                }
                Button {
                    var new = ParamSpec(key: uniqueKey(), label: "새 항목")
                    new.placeholder = ""
                    card.params.append(new)
                    editingParam = new
                } label: {
                    Label("항목 추가", systemImage: "plus.circle")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 9).strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary))
            }
            .padding(14)
            .background(blockBackground)
        }
    }

    // 실행 옵션
    private var runBlock: some View {
        Group {
            SectionLabel(text: "실행 설정")
            VStack(alignment: .leading, spacing: 11) {
                LabeledField("작업 폴더") {
                    HStack(spacing: 6) {
                        TextField("비우면 홈 폴더", text: $card.run.workingDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let u = panel.url {
                                card.run.workingDirectory = u.path
                            }
                        } label: { Image(systemName: "folder") }
                        .buttonStyle(SubtleButtonStyle())
                    }
                }
                LabeledField("모델") {
                    Picker("", selection: $card.run.model) {
                        Text("기본").tag("")
                        Text("Opus").tag("opus")
                        Text("Sonnet").tag("sonnet")
                        Text("Haiku").tag("haiku")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                LabeledField("최대 실행 시간") {
                    HStack(spacing: 6) {
                        Stepper(value: $card.run.timeoutSeconds, in: 60...7200, step: 60) {
                            Text("\(card.run.timeoutSeconds / 60)분")
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .frame(width: 130)
                    }
                }
                Toggle(isOn: $card.run.bypassPermissions) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("도구 권한 자동 승인").font(.system(size: 12))
                        Text("대부분의 스킬은 파일 읽기·명령 실행이 필요합니다. 끄면 권한 대기 상태로 멈출 수 있습니다.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Toggle("완료되면 알림 보내기", isOn: $card.run.notifyOnFinish).font(.system(size: 12))
                Toggle("세션 기록 남기지 않기", isOn: $card.run.ephemeral).font(.system(size: 12))
            }
            .padding(14)
            .background(blockBackground)
        }
    }

    // 단축키
    private var hotkeyBlock: some View {
        Group {
            SectionLabel(text: "단축키")
            HStack(spacing: 10) {
                HotKeyRecorder(hotkey: $card.hotkey)
                Text("이 스킬을 어디서나 바로 실행합니다.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            .background(blockBackground)
        }
    }

    private var dangerBlock: some View {
        HStack {
            Spacer()
            Button(role: .destructive) { onDelete() } label: {
                Label("이 스킬 삭제", systemImage: "trash").font(.system(size: 11.5))
            }
            .buttonStyle(SubtleButtonStyle())
        }
    }

    private var blockBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.subtleFill.opacity(0.65))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.45), lineWidth: 0.5))
    }

    private func uniqueKey() -> String {
        var i = 1
        var key = "value"
        let used = Set(card.params.map(\.key))
        while used.contains(key) { i += 1; key = "value\(i)" }
        return key
    }

    /// 원본 SKILL.md 를 다시 읽어 파라미터를 갈아끼운다.
    private func rescan(useAI: Bool) {
        let catalogSkill: CatalogSkill? = {
            if let s = SkillCatalog.shared.skill(command: card.command) { return s }
            guard let path = card.sourcePath else { return nil }
            return CatalogSkill(command: card.command, name: card.title, summary: card.subtitle,
                                tags: [], path: path, origin: .user, body: "")
        }()
        guard let skill = catalogSkill else {
            message = "원본 스킬 파일을 찾지 못했습니다."
            return
        }
        if !useAI {
            let outcome = ParamInference.infer(skill: skill)
            card.params = outcome.params
            card.promptTemplate = outcome.promptTemplate
            card.sourcePath = skill.path
            message = outcome.evidence
            return
        }
        guard let claude = ConfigStore.shared.resolveClaudePath() else {
            message = "claude 실행 파일을 찾지 못했습니다."
            return
        }
        aiBusy = true
        message = nil
        ParamInference.inferWithAI(skill: skill, claudePath: claude) { result in
            aiBusy = false
            switch result {
            case .success(let suggestion):
                card.params = suggestion.outcome.params
                card.promptTemplate = suggestion.outcome.promptTemplate
                card.sourcePath = skill.path
                if card.title.isEmpty || card.title == skill.name { card.title = suggestion.title }
                if card.subtitle.isEmpty { card.subtitle = suggestion.subtitle }
                if card.emoji == "✨" { card.emoji = suggestion.emoji }
                message = suggestion.outcome.evidence
            case .failure(let err):
                message = "추출 실패 — \(err.message.prefix(120))"
            }
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 96, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 파라미터 행 / 편집 시트

private struct ParamRow: View {
    let spec: ParamSpec
    let tint: String
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: spec.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: tint))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(spec.label).font(.system(size: 12, weight: .medium))
                    if spec.required { StatusPill(text: "필수", color: Color(hex: tint)) }
                }
                Text("{{\(spec.key)}} · \(spec.kind.label)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("편집", action: onEdit).buttonStyle(SubtleButtonStyle())
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash").font(.system(size: 10.5))
            }
            .buttonStyle(SubtleButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface.opacity(0.7)))
    }
}

struct ParamEditorSheet: View {
    /// 기본값 칸에 한 번에 꽂아 넣을 수 있는 토큰 (자주 쓰는 것만).
    static let tokenChoices: [PromptToken] = [.today, .yesterday, .weekAgo, .thisMonth, .downloads, .worklog]

    @State var spec: ParamSpec
    var onSave: (ParamSpec) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var optionsText: String = ""

    init(spec: ParamSpec, onSave: @escaping (ParamSpec) -> Void) {
        _spec = State(initialValue: spec)
        self.onSave = onSave
        _optionsText = State(initialValue: spec.options.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("입력 항목 편집").font(Theme.title(15, .bold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    Text("이름").font(.system(size: 11.5, weight: .semibold))
                    TextField("사용자에게 보이는 이름", text: $spec.label).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("변수명").font(.system(size: 11.5, weight: .semibold))
                    TextField("prompt 안에서 {{...}} 로 쓰입니다", text: $spec.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text("종류").font(.system(size: 11.5, weight: .semibold))
                    Picker("", selection: $spec.kind) {
                        ForEach(ParamKind.allCases) { k in
                            Label(k.label, systemImage: k.symbol).tag(k)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                if spec.kind == .select {
                    GridRow {
                        Text("보기 목록").font(.system(size: 11.5, weight: .semibold))
                        TextField("쉼표로 구분: dev, stage, real", text: $optionsText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("기본값").font(.system(size: 11.5, weight: .semibold))
                    TextField("채워두면 입력 없이 바로 실행됩니다", text: $spec.defaultValue)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("").frame(width: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("실행할 때 값이 바뀌는 토큰")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(ParamEditorSheet.tokenChoices, id: \.rawValue) { t in
                                Button(t.label) { spec.defaultValue = t.placeholder }
                                    .buttonStyle(SubtleButtonStyle())
                                    .help(t.placeholder)
                            }
                        }
                    }
                }
                GridRow {
                    Text("입력 예시").font(.system(size: 11.5, weight: .semibold))
                    TextField("placeholder 로 흐리게 보입니다", text: $spec.placeholder)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("설명").font(.system(size: 11.5, weight: .semibold))
                    TextField("입력칸 아래 작게 보이는 안내", text: $spec.help).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("").frame(width: 1)
                    Toggle("필수 입력", isOn: $spec.required).font(.system(size: 12))
                }
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(SubtleButtonStyle())
                Button("저장") {
                    spec.key = ParamInference.sanitizeKey(spec.key)
                    spec.options = optionsText.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onSave(spec)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 90)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

// MARK: - 카탈로그에서 스킬 담기

struct CatalogPickerView: View {
    enum Tab: String, CaseIterable {
        case skill, mcp

        var label: String {
            switch self {
            case .skill: return "스킬"
            case .mcp: return "MCP 서버"
            }
        }
    }

    @ObservedObject private var catalog = SkillCatalog.shared
    @ObservedObject private var mcp = MCPCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .skill
    @State private var query = ""
    /// 스킬은 command, MCP 는 서버 이름으로 골라 담는다.
    @State private var pickedSkills: Set<String> = []
    @State private var pickedServers: Set<String> = []
    var onAdd: ([SkillCard]) -> Void

    private var filteredSkills: [CatalogSkill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return catalog.skills }
        return catalog.skills.filter {
            $0.command.lowercased().contains(q)
                || $0.name.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
        }
    }

    private var filteredServers: [MCPServer] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return mcp.servers }
        return mcp.servers.filter {
            $0.name.lowercased().contains(q) || $0.endpoint.lowercased().contains(q)
        }
    }

    private var pickedCount: Int { pickedSkills.count + pickedServers.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            searchField
            list
            Divider()
            footer
        }
        .frame(width: 660, height: 580)
        .onAppear {
            if catalog.skills.isEmpty { catalog.refresh() }
            if mcp.servers.isEmpty { mcp.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "square.stack.3d.down.right").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("바로 실행할 것 고르기").font(Theme.title(15, .bold))
                Text("담으면 값이 미리 채워져, 누르는 순간 실행됩니다.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if catalog.isScanning || mcp.isScanning { ProgressView().controlSize(.small) }
            Button {
                catalog.refresh()
                mcp.refresh()
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(SubtleButtonStyle())
            .help("다시 검색")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var tabBar: some View {
        Picker("", selection: $tab) {
            Text("\(Tab.skill.label) \(catalog.skills.count)").tag(Tab.skill)
            Text("\(Tab.mcp.label) \(mcp.servers.count)").tag(Tab.mcp)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(tab == .skill ? "스킬 이름 · 설명으로 검색" : "서버 이름 · 주소로 검색", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.subtleFill))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                switch tab {
                case .skill:
                    ForEach(filteredSkills) { skill in
                        CatalogRow(title: "/\(skill.command)",
                                   badge: skill.origin.label,
                                   summary: skill.shortSummary,
                                   symbol: nil,
                                   selected: pickedSkills.contains(skill.command)) {
                            toggle(&pickedSkills, skill.command)
                        }
                    }
                case .mcp:
                    if mcp.servers.isEmpty {
                        Text("설정된 MCP 서버가 없습니다.\n~/.claude.json 또는 ~/.claude/settings.json 의 mcpServers 를 읽습니다.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }
                    ForEach(filteredServers) { server in
                        CatalogRow(title: server.name,
                                   badge: "\(server.transport.label) · \(server.scope.label)",
                                   summary: server.suggestedRequest,
                                   symbol: server.transport.symbol,
                                   selected: pickedServers.contains(server.name)) {
                            toggle(&pickedServers, server.name)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button(selectAllTitle) { selectAll() }
                .buttonStyle(SubtleButtonStyle())
            if pickedCount > 0 {
                Text("\(pickedCount)개 선택")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("닫기") { dismiss() }.buttonStyle(SubtleButtonStyle())
            Button(pickedCount > 1 ? "\(pickedCount)개 담기" : "담기") {
                onAdd(makeCards())
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle(disabled: pickedCount == 0))
            .disabled(pickedCount == 0)
            .frame(width: 110)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var selectAllTitle: String {
        switch tab {
        case .skill: return pickedSkills.count == filteredSkills.count ? "선택 해제" : "보이는 것 전부"
        case .mcp: return pickedServers.count == filteredServers.count ? "선택 해제" : "보이는 것 전부"
        }
    }

    private func selectAll() {
        switch tab {
        case .skill:
            let all = Set(filteredSkills.map(\.command))
            pickedSkills = pickedSkills == all ? [] : all
        case .mcp:
            let all = Set(filteredServers.map(\.name))
            pickedServers = pickedServers == all ? [] : all
        }
    }

    private func toggle(_ set: inout Set<String>, _ key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }

    /// 고른 항목을 즉시 실행 가능한 카드로 만든다.
    private func makeCards() -> [SkillCard] {
        var out: [SkillCard] = []
        for command in pickedSkills.sorted() {
            guard let skill = catalog.skill(command: command) else { continue }
            out.append(CatalogPickerView.makeCard(from: skill))
        }
        for name in pickedServers.sorted() {
            guard let server = mcp.server(name: name) else { continue }
            out.append(server.makeCard())
        }
        return out
    }

    static func makeCard(from skill: CatalogSkill) -> SkillCard {
        let outcome = ParamInference.infer(skill: skill)
        let tint = Theme.palette[abs(skill.command.hashValue) % Theme.palette.count]
        return SkillCard(title: prettyTitle(skill),
                         subtitle: skill.shortSummary,
                         emoji: Theme.emojiChoices[abs(skill.command.hashValue) % Theme.emojiChoices.count],
                         tint: tint,
                         command: skill.command,
                         promptTemplate: outcome.promptTemplate,
                         params: outcome.params,
                         sourcePath: skill.path)
    }

    private static func prettyTitle(_ skill: CatalogSkill) -> String {
        let base = skill.command.components(separatedBy: ":").last ?? skill.command
        return base.replacingOccurrences(of: "-", with: " ")
                   .replacingOccurrences(of: "_", with: " ")
    }
}

private struct CatalogRow: View {
    let title: String
    let badge: String
    let summary: String
    /// MCP 서버처럼 전송 방식을 알려줄 때 쓰는 아이콘.
    let symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(title)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        StatusPill(text: badge, color: .secondary)
                    }
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.1) : Theme.subtleFill.opacity(0.7)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 앱 설정

struct SettingsView: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var launchAtLoginMessage: String?
    @State private var launchAtLogin: Bool = SettingsView.currentLaunchAtLogin()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("설정").font(Theme.title(18, .bold))

                SectionLabel(text: "단축키")
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 10) {
                        Text("팝오버 열기").font(.system(size: 11.5, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                        HotKeyRecorder(hotkey: Binding(
                            get: { store.config.openPopoverHotkey },
                            set: { store.config.openPopoverHotkey = $0 }
                        ))
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        Text("단축키 동작").font(.system(size: 11.5, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { store.config.quickRunCardID ?? SettingsView.noQuickRun },
                            set: { store.config.quickRunCardID = ($0 == SettingsView.noQuickRun) ? nil : $0 }
                        )) {
                            Text("스킬 목록 열기").tag(SettingsView.noQuickRun)
                            ForEach(store.config.cards) { c in
                                Text("바로 실행 — \(c.title)").tag(c.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        Spacer()
                    }
                }
                .padding(14).background(blockBackground)

                SectionLabel(text: "일반")
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 10) {
                        Text("결과 저장 폴더").font(.system(size: 11.5, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                        TextField("~/SkillDock", text: Binding(
                            get: { store.config.resultDirectory },
                            set: { store.config.resultDirectory = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("열기") {
                            let dir = store.config.resolvedResultDirectory
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(dir)
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }
                    Toggle("로그인할 때 자동 실행", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    .font(.system(size: 12))
                    if let launchAtLoginMessage {
                        Text(launchAtLoginMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(14).background(blockBackground)

                SectionLabel(text: "고급")
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 10) {
                        Text("claude 경로").font(.system(size: 11.5, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                        TextField(store.resolveClaudePath() ?? "자동 탐색 실패", text: Binding(
                            get: { store.config.claudePath },
                            set: { store.config.claudePath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                    if let p = store.resolveClaudePath() {
                        Label("찾음: \(p)", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("claude 실행 파일을 찾지 못했습니다.", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5)).foregroundStyle(.orange)
                            Text("터미널에서 `npm i -g @anthropic-ai/claude-code` 로 설치하거나 경로를 직접 입력하세요. 데스크톱 앱 내부의 claude-code-vm 바이너리는 리눅스용이라 동작하지 않습니다.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("설정 파일 열기") {
                            NSWorkspace.shared.open(ConfigStore.fileURL.deletingLastPathComponent())
                        }
                        .buttonStyle(SubtleButtonStyle())
                        Button("스킬·MCP 다시 검색") {
                            SkillCatalog.shared.refresh()
                            MCPCatalog.shared.refresh()
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }
                }
                .padding(14).background(blockBackground)

                Text("설정은 \(ConfigStore.fileURL.path) 에 저장됩니다.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(24)
            .padding(.top, 14)
            .frame(maxWidth: 660, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    static let noQuickRun = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private var blockBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.subtleFill.opacity(0.65))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.45), lineWidth: 0.5))
    }

    private static func currentLaunchAtLogin() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
            launchAtLoginMessage = nil
        } catch {
            launchAtLogin = SettingsView.currentLaunchAtLogin()
            launchAtLoginMessage = "자동 실행을 바꾸지 못했습니다 — \(error.localizedDescription). 앱을 /Applications 로 옮긴 뒤 다시 시도하세요."
        }
    }
}

// MARK: - 단축키 입력 위젯

struct HotKeyRecorder: View {
    @Binding var hotkey: HotKeySpec?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "키를 누르세요…" : (hotkey?.displayString ?? "설정 없음"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 110)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(recording ? Color.accentColor.opacity(0.18) : Theme.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if hotkey != nil {
                Button {
                    hotkey = nil
                    HotKeyBinder.shared.rebind()
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain)
                .help("단축키 지우기")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = HotKeyFormatter.carbonModifiers(from: event.modifierFlags)
            // 수정자 없는 단일 키는 전역 단축키로 쓰면 위험하다.
            guard mods != 0 else { return event }
            hotkey = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: mods)
            stop()
            HotKeyBinder.shared.rebind()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
