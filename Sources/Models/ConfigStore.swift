import Foundation
import Combine

/// `~/.config/skilldock/config.json` 을 단일 진실 원천으로 쓰는 설정 저장소.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet { scheduleSave() }
    }

    private var saveWorkItem: DispatchWorkItem?

    /// 미리보기·테스트에서 실제 설정 파일을 건드리지 않도록 끄는 스위치.
    static var persistenceEnabled = true

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/skilldock", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    private init() {
        config = ConfigStore.load() ?? AppConfig()
    }

    // MARK: 읽기/쓰기

    private static func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AppConfig.self, from: data)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = config
        let item = DispatchWorkItem { ConfigStore.write(snapshot) }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// 즉시 디스크에 반영한다 (앱 종료 직전 등).
    func flush() {
        saveWorkItem?.cancel()
        ConfigStore.write(config)
    }

    private static func write(_ cfg: AppConfig) {
        guard persistenceEnabled else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(cfg)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("SkillDock: 설정 저장 실패 — \(error.localizedDescription)")
        }
    }

    // MARK: 카드 조작

    func card(id: UUID) -> SkillCard? { config.cards.first { $0.id == id } }

    func upsert(_ card: SkillCard) {
        if let idx = config.cards.firstIndex(where: { $0.id == card.id }) {
            config.cards[idx] = card
        } else {
            config.cards.append(card)
        }
    }

    func remove(id: UUID) {
        config.cards.removeAll { $0.id == id }
        if config.quickRunCardID == id { config.quickRunCardID = nil }
    }

    func move(from source: IndexSet, to destination: Int) {
        config.cards.move(fromOffsets: source, toOffset: destination)
    }

    func markRun(id: UUID) {
        guard let idx = config.cards.firstIndex(where: { $0.id == id }) else { return }
        config.cards[idx].lastRunAt = Date()
    }

    // MARK: claude 실행 파일 탐색

    /// 설정값 → 후보 경로 → PATH 순으로 claude 바이너리를 찾는다.
    func resolveClaudePath() -> String? {
        let fm = FileManager.default
        let configured = config.claudePath.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) { return expanded }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.bun/bin/claude",
            "/usr/bin/claude",
        ]
        for c in candidates where ConfigStore.isRunnable(c) { return c }
        if let onPath = ProcessRunner.which("claude"), ConfigStore.isRunnable(onPath) { return onPath }
        return nil
    }

    /// 이 맥에서 **실제로 실행되는** 파일인지 확인한다.
    ///
    /// 실행 권한만 보면 부족하다. Claude 데스크톱 앱은 샌드박스 VM 용 Linux(ELF) 바이너리를
    /// `~/Library/Application Support/Claude/claude-code-vm/<버전>/claude` 에 두는데,
    /// 이걸 실행하면 "exec format error" 로 죽는다. Mach-O 나 스크립트만 통과시킨다.
    static func isRunnable(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path) else { return false }
        guard let handle = FileHandle(forReadingAtPath: path),
              let head = try? handle.read(upToCount: 4) else { return false }
        try? handle.close()
        guard head.count == 4 else { return false }
        // 스크립트 (#!/usr/bin/env node 등)
        if head[0] == 0x23, head[1] == 0x21 { return true }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        // Mach-O 64bit(리틀엔디언) / universal fat binary
        return magic == 0xFEED_FACF || magic == 0xCFFA_EDFE
            || magic == 0xCAFE_BABE || magic == 0xBEBA_FECA
    }
}
