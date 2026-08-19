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
        window.title = "SkillsOnMenu — Skill Manager"
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
                Text("Saved skills").font(Theme.title(13, .bold))
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
                        Button("Duplicate") { duplicate(card) }
                        Button("Delete", role: .destructive) { store.remove(id: card.id) }
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
                    Label("Add skill", systemImage: "plus").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(SubtleButtonStyle())

                Spacer()

                Button {
                    selection = .settings
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("App settings")
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
                               title: "No skill selected",
                               message: "Choose a skill on the left or add a new one.")
            }
        case .settings:
            SettingsView()
        case .none:
            EmptyStateView(symbol: "square.stack.3d.up",
                           title: "Choose a skill",
                           message: "Select a skill from the list to edit it here.",
                           actionTitle: "Add skill") { showCatalog = true }
        }
    }

    private func duplicate(_ card: SkillCard) {
        var copy = card
        copy.id = UUID()
        copy.title = card.title + " Copy"
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
                Text(card.title.isEmpty ? "Untitled skill" : card.title).font(Theme.title(18, .bold))
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
            SectionLabel(text: "One-click run")
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Image(systemName: card.isReadyToRun ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(card.isReadyToRun ? .green : .orange)
                    if card.isReadyToRun {
                        Text("Ready — selecting it in the list runs it as is.").font(.system(size: 12))
                    } else {
                        Text("\(card.missingRequired().count) required input(s) are missing, so a form opens first.")
                            .font(.system(size: 12))
                    }
                    Spacer()
                    Button("Fill empty values") { autofill() }
                        .buttonStyle(SubtleButtonStyle())
                }
                Toggle(isOn: $card.instantRun) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Run immediately from the list").font(.system(size: 12))
                        Text("Turn it off to always show the input form first.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if card.usesDynamicTokens {
                    Label("Dates and folders resolve fresh every time the skill runs.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("This is what it sends now").font(.system(size: 10.5, weight: .semibold))
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
            SectionLabel(text: "Appearance")
            VStack(alignment: .leading, spacing: 11) {
                LabeledField("Name") {
                    TextField("예: 트렌드 브리핑", text: $card.title).textFieldStyle(.roundedBorder)
                }
                LabeledField("한 줄 설명") {
                    TextField("What this skill does", text: $card.subtitle).textFieldStyle(.roundedBorder)
                }
                LabeledField("Icon") {
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
                LabeledField("Color") {
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
            SectionLabel(text: "Skill")
            VStack(alignment: .leading, spacing: 11) {
                LabeledField("Slash command") {
                    HStack(spacing: 5) {
                        Text("/").foregroundStyle(.secondary)
                        TextField("llmTrend", text: $card.command).textFieldStyle(.roundedBorder)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Run prompt").font(.system(size: 11.5, weight: .semibold))
                        Spacer()
                        Text("{{field_name}} is replaced by its input value")
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
                SectionLabel(text: "Inputs (\(card.params.count))")
                Spacer()
                if aiBusy {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Reading skill…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Extract from skill") { rescan(useAI: false) }
                        .buttonStyle(SubtleButtonStyle())
                    Button("Extract with AI") { rescan(useAI: true) }
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
                    var new = ParamSpec(key: uniqueKey(), label: "New input")
                    new.placeholder = ""
                    card.params.append(new)
                    editingParam = new
                } label: {
                    Label("Add input", systemImage: "plus.circle")
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
            SectionLabel(text: "Run settings")
            VStack(alignment: .leading, spacing: 11) {
                LabeledField("Working folder") {
                    HStack(spacing: 6) {
                        TextField("Leave blank for home folder", text: $card.run.workingDirectory)
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
                LabeledField("Model") {
                    Picker("", selection: $card.run.model) {
                        Text("Default").tag("")
                        Text("Opus").tag("opus")
                        Text("Sonnet").tag("sonnet")
                        Text("Haiku").tag("haiku")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                LabeledField("Maximum run time") {
                    HStack(spacing: 6) {
                        Stepper(value: $card.run.timeoutSeconds, in: 60...7200, step: 60) {
                            Text("\(card.run.timeoutSeconds / 60) min")
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .frame(width: 130)
                    }
                }
                Toggle(isOn: $card.run.bypassPermissions) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Automatically approve tool permissions").font(.system(size: 12))
                        Text("Most skills need to read files or run commands. Turning this off can leave a run waiting for permission.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Toggle("Notify when finished", isOn: $card.run.notifyOnFinish).font(.system(size: 12))
                Toggle("Do not retain session history", isOn: $card.run.ephemeral).font(.system(size: 12))
            }
            .padding(14)
            .background(blockBackground)
        }
    }

    // 단축키
    private var hotkeyBlock: some View {
        Group {
            SectionLabel(text: "Keyboard shortcut")
            HStack(spacing: 10) {
                HotKeyRecorder(hotkey: $card.hotkey)
                Text("Run this skill from anywhere.")
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
                Label("Delete this skill", systemImage: "trash").font(.system(size: 11.5))
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
            Text("Edit input").font(Theme.title(15, .bold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    Text("Label").font(.system(size: 11.5, weight: .semibold))
                    TextField("Name shown to users", text: $spec.label).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Variable name").font(.system(size: 11.5, weight: .semibold))
                    TextField("Used as {{...}} in the prompt", text: $spec.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text("Type").font(.system(size: 11.5, weight: .semibold))
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
                        Text("Options").font(.system(size: 11.5, weight: .semibold))
                        TextField("Comma-separated: dev, stage, real", text: $optionsText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("Default value").font(.system(size: 11.5, weight: .semibold))
                    TextField("Prefill to run without input", text: $spec.defaultValue)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("").frame(width: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tokens resolved at runtime")
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
                    Text("Example input").font(.system(size: 11.5, weight: .semibold))
                    TextField("Shown as placeholder text", text: $spec.placeholder)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Help text").font(.system(size: 11.5, weight: .semibold))
                    TextField("Shown below the input", text: $spec.help).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("").frame(width: 1)
                    Toggle("Required", isOn: $spec.required).font(.system(size: 12))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SubtleButtonStyle())
                Button("Save") {
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
                        TextField("~/SkillsOnMenu", text: Binding(
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
