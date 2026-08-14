import Foundation
import Combine

// MARK: - 진행 로그 한 줄

struct ActivityLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case info, thinking, tool, text, warning, error, success
    }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String = ""
    var at: Date = Date()

    var symbol: String {
        switch kind {
        case .info: return "circle.dotted"
        case .thinking: return "sparkle"
        case .tool: return "wrench.and.screwdriver"
        case .text: return "text.bubble"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .success: return "checkmark.circle"
        }
    }
}

// MARK: - 실행 상태

enum RunState: Equatable {
    case idle
    case running
    case success
    case failed(String)
    case cancelled

    var isRunning: Bool { self == .running }
}

/// 카드 하나의 실행을 담당한다. claude 를 `--output-format stream-json` 으로 띄우고
/// 이벤트를 UI 가 바로 쓸 수 있는 형태로 바꿔 발행한다.
final class SkillRunner: ObservableObject {
    @Published private(set) var state: RunState = .idle
    @Published private(set) var activity: [ActivityLine] = []
    @Published private(set) var resultMarkdown: String = ""
    @Published private(set) var costUSD: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentStep: String = ""
    @Published private(set) var savedResultURL: URL?

    private(set) var card: SkillCard?
    private(set) var renderedPrompt: String = ""

    private var process: Process?
    private var buffer = Data()
    private var startedAt: Date?
    private var ticker: Timer?
    private var timeoutTimer: Timer?

    // MARK: 실행

    func start(card: SkillCard, values: [String: String]) {
        guard !state.isRunning else { return }
        guard let claude = ConfigStore.shared.resolveClaudePath() else {
            state = .failed("claude 명령을 찾지 못했습니다. Claude Code CLI 를 설치하거나 설정에서 경로를 지정해 주세요.")
            append(.init(kind: .error, title: "claude 를 찾을 수 없습니다",
                         detail: "터미널에서 `npm i -g @anthropic-ai/claude-code` 로 설치하거나, 설정 › 고급에 경로를 직접 입력하세요. (데스크톱 앱 안의 claude-code-vm 바이너리는 리눅스용이라 쓸 수 없습니다.)"))
            return
        }

        self.card = card
        renderedPrompt = card.renderPrompt(values: values)
        activity = []
        resultMarkdown = ""
        costUSD = 0
        elapsed = 0
        savedResultURL = nil
        currentStep = "세션 준비 중"
        state = .running
        startedAt = Date()
        buffer = Data()

        var args = ["-p", renderedPrompt,
                    "--output-format", "stream-json",
                    "--verbose"]
        if card.run.bypassPermissions {
            args += ["--permission-mode", "bypassPermissions"]
        }
        if !card.run.model.isEmpty {
            args += ["--model", card.run.model]
        }
        if card.run.ephemeral {
            args += ["--no-session-persistence"]
        }

        append(.init(kind: .info, title: "실행", detail: renderedPrompt))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = args
        proc.environment = ProcessRunner.enrichedEnvironment()
        proc.currentDirectoryURL = URL(fileURLWithPath: card.run.resolvedWorkingDirectory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }

        var errText = ""
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            errText += s
        }

        proc.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.finish(exitCode: p.terminationStatus, stderr: errText)
            }
        }

        do {
            try proc.run()
        } catch {
            state = .failed(error.localizedDescription)
            append(.init(kind: .error, title: "실행 실패", detail: error.localizedDescription))
            return
        }
        process = proc

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let s = self.startedAt else { return }
            self.elapsed = Date().timeIntervalSince(s)
        }
        let limit = TimeInterval(max(30, card.run.timeoutSeconds))
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self] _ in
            guard let self, self.state.isRunning else { return }
            self.append(.init(kind: .warning, title: "시간 초과", detail: "\(Int(limit))초를 넘겨 중단합니다."))
            self.cancel(reason: .timeout)
        }
    }

    enum CancelReason { case user, timeout }

    func cancel(reason: CancelReason = .user) {
        guard state.isRunning else { return }
        process?.terminate()
        stopTimers()
        state = reason == .timeout ? .failed("시간이 초과되어 중단했습니다.") : .cancelled
        currentStep = ""
        append(.init(kind: .warning, title: reason == .timeout ? "중단됨 (시간 초과)" : "사용자가 중단했습니다"))
    }

    func reset() {
        guard !state.isRunning else { return }
        state = .idle
        activity = []
        resultMarkdown = ""
        costUSD = 0
        elapsed = 0
        currentStep = ""
        savedResultURL = nil
    }

    private func stopTimers() {
        ticker?.invalidate(); ticker = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
    }

    // MARK: stream-json 파싱

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "system":
            let subtype = obj["subtype"] as? String ?? ""
            if subtype == "init" {
                let model = obj["model"] as? String ?? "기본 모델"
                push(.init(kind: .info, title: "세션 시작", detail: model))
                setStep("스킬 읽는 중")
            } else if subtype == "informational", let content = obj["content"] as? String {
                push(.init(kind: .info, title: content))
            }

        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content {
                let bt = block["type"] as? String ?? ""
                if bt == "text", let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !t.isEmpty {
                    push(.init(kind: .text, title: firstLine(t), detail: t))
                    setStep(firstLine(t))
                } else if bt == "tool_use" {
                    let name = block["name"] as? String ?? "도구"
                    let input = block["input"] as? [String: Any] ?? [:]
                    push(.init(kind: .tool, title: name, detail: summarize(tool: name, input: input)))
                    setStep("\(name) 실행 중")
                } else if bt == "thinking" {
                    setStep("생각하는 중")
                }
            }

        case "result":
            if let r = obj["result"] as? String { resultMarkdown = r }
            if let c = obj["total_cost_usd"] as? Double { costUSD = c }
            let isError = (obj["is_error"] as? Bool) ?? false
            if isError {
                let sub = obj["subtype"] as? String ?? "오류"
                push(.init(kind: .error, title: "실패", detail: sub))
            }

        default:
            break
        }
    }

    private func push(_ line: ActivityLine) {
        DispatchQueue.main.async { self.append(line) }
    }

    private func append(_ line: ActivityLine) {
        activity.append(line)
        // 로그가 무한히 자라지 않게 앞쪽을 버린다.
        if activity.count > 400 { activity.removeFirst(activity.count - 400) }
    }

    private func setStep(_ s: String) {
        DispatchQueue.main.async {
            self.currentStep = s.count > 70 ? String(s.prefix(70)) + "…" : s
        }
    }

    private func firstLine(_ s: String) -> String {
        let l = s.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? s
        return l.count > 120 ? String(l.prefix(120)) + "…" : l
    }

    private func summarize(tool: String, input: [String: Any]) -> String {
        for key in ["command", "pattern", "file_path", "url", "query", "prompt", "description", "skill"] {
            if let v = input[key] as? String, !v.isEmpty {
                return v.count > 160 ? String(v.prefix(160)) + "…" : v
            }
        }
        return ""
    }

    // MARK: 종료 처리

    private func finish(exitCode: Int32, stderr: String) {
        stopTimers()
        if let s = startedAt { elapsed = Date().timeIntervalSince(s) }
        currentStep = ""

        // 사용자가 이미 중단했으면 상태를 덮어쓰지 않는다.
        if case .cancelled = state { return }
        if case .failed = state { return }

        if exitCode == 0 {
            if resultMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resultMarkdown = "_결과 텍스트가 비어 있습니다. 아래 진행 로그를 확인해 주세요._"
            }
            state = .success
            append(.init(kind: .success, title: "완료", detail: String(format: "%.1f초 · $%.4f", elapsed, costUSD)))
            saveResultFile()
        } else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty ? "claude 가 코드 \(exitCode) 로 종료했습니다." : detail
            state = .failed(message)
            append(.init(kind: .error, title: "실패", detail: message))
        }

        if let card, card.run.notifyOnFinish {
            Notifier.shared.notify(state: state, card: card, elapsed: elapsed, resultURL: savedResultURL)
        }
        if let card { ConfigStore.shared.markRun(id: card.id) }
    }

    /// 결과를 마크다운 파일로 남긴다. 팝오버를 닫아도 결과가 사라지지 않게.
    private func saveResultFile() {
        guard let card else { return }
        let dir = ConfigStore.shared.config.resolvedResultDirectory
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: startedAt ?? Date())
        let safeTitle = card.title.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(stamp)_\(safeTitle).md")
        let header = """
        # \(card.title)

        - 실행: `\(renderedPrompt)`
        - 시각: \(DateFormatter.localizedString(from: startedAt ?? Date(), dateStyle: .medium, timeStyle: .medium))
        - 소요: \(String(format: "%.1f", elapsed))초 · 비용 $\(String(format: "%.4f", costUSD))

        ---

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (header + resultMarkdown).write(to: url, atomically: true, encoding: .utf8)
            savedResultURL = url
        } catch {
            append(.init(kind: .warning, title: "결과 파일 저장 실패", detail: error.localizedDescription))
        }
    }
}
