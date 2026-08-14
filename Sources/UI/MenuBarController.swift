import AppKit
import SwiftUI

/// 메뉴바 아이콘 + 팝오버.
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    let router = PopoverRouter()
    private var statusTimer: Timer?

    private override init() { super.init() }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MenuBarController.icon(running: false)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "SkillDock — 스킬 바로 실행"
        }

        let root = PopoverRootView(
            router: router,
            onOpenLibrary: { [weak self] in
                self?.closePopover()
                LibraryWindowController.shared.present()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: root)
        popover.contentSize = NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // 실행 중이면 아이콘을 바꿔 진행 상황을 알린다.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let busy = !RunnerRegistry.shared.busyCardIDs.isEmpty
            self.statusItem.button?.image = MenuBarController.icon(running: busy)
        }
    }

    private static func icon(running: Bool) -> NSImage? {
        let name = running ? "bolt.horizontal.circle.fill" : "bolt.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "SkillDock")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    // MARK: 클릭 처리

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let cards = ConfigStore.shared.config.cards
        if cards.isEmpty {
            let item = NSMenuItem(title: "등록된 스킬이 없습니다", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for card in cards {
                let item = NSMenuItem(title: "\(card.emoji)  \(card.title)",
                                      action: #selector(menuRunCard(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = card.id
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "스킬 관리 · 설정…", action: #selector(menuOpenLibrary), keyEquivalent: ",")
        manage.target = self
        menu.addItem(manage)
        let quit = NSMenuItem(title: "SkillDock 종료", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRunCard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        quickRun(cardID: id)
    }

    @objc private func menuOpenLibrary() { LibraryWindowController.shared.present() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: 팝오버

    func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 팝오버 안의 입력칸이 바로 타이핑을 받게 앱을 활성화한다.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() { popover.performClose(nil) }

    /// 단축키/메뉴에서 카드를 바로 실행한다.
    /// 필수 입력이 비어 있으면 실행하지 않고 폼을 열어준다.
    func quickRun(cardID: UUID) {
        guard let card = ConfigStore.shared.card(id: cardID) else {
            showPopover()
            return
        }
        router.route = .run(card.id)
        // 필수 입력이 비어 있으면 launch 가 false 를 주고, 폼이 그대로 열린다.
        RunnerRegistry.shared.launch(card: card)
        showPopover()
    }

    /// 단축키가 눌렸을 때의 기본 동작 (설정에 따라 목록 열기 또는 바로 실행).
    func handleGlobalHotkey() {
        if let quickID = ConfigStore.shared.config.quickRunCardID,
           ConfigStore.shared.card(id: quickID) != nil {
            quickRun(cardID: quickID)
        } else {
            router.home()
            togglePopover()
        }
    }

    /// 알림을 눌렀을 때: 결과 파일을 열거나 팝오버를 띄운다.
    func revealResult(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) } else { showPopover() }
    }
}

// MARK: - 단축키 바인딩

/// 설정에 등록된 모든 단축키를 Carbon 에 다시 등록한다.
final class HotKeyBinder {
    static let shared = HotKeyBinder()
    private init() {}

    func rebind() {
        HotKeyCenter.shared.unregisterAll()
        let cfg = ConfigStore.shared.config

        if let hk = cfg.openPopoverHotkey {
            HotKeyCenter.shared.register(keyCode: hk.keyCode, modifiers: hk.modifiers) {
                MenuBarController.shared.handleGlobalHotkey()
            }
        }
        for card in cfg.cards {
            guard let hk = card.hotkey else { continue }
            let id = card.id
            HotKeyCenter.shared.register(keyCode: hk.keyCode, modifiers: hk.modifiers) {
                MenuBarController.shared.quickRun(cardID: id)
            }
        }
    }
}
