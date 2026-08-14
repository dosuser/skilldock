import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarController.shared.install()
        HotKeyBinder.shared.rebind()

        Notifier.shared.onOpenResult = { url in
            MenuBarController.shared.revealResult(url)
        }
        Notifier.shared.requestAuthorization()

        SkillCatalog.shared.refresh()

        // 카드의 단축키가 바뀌면 Carbon 등록을 다시 맞춘다.
        ConfigStore.shared.$config
            .map { cfg in
                (cfg.openPopoverHotkey, cfg.cards.map { $0.hotkey })
            }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { _ in HotKeyBinder.shared.rebind() }
            .store(in: &cancellables)

        // 등록된 스킬이 없으면 관리 창을 띄워 첫 등록을 안내한다.
        if ConfigStore.shared.config.cards.isEmpty {
            LibraryWindowController.shared.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConfigStore.shared.flush()
        HotKeyCenter.shared.unregisterAll()
    }

    /// 메뉴바 전용 앱이므로 창을 모두 닫아도 종료하지 않는다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
