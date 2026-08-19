import Foundation
import AppKit
import UserNotifications

/// 실행 완료 알림. 번들 알림 권한을 못 받으면 osascript 로 폴백한다.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var authorized = false
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// 알림을 눌렀을 때 실행할 동작 (AppDelegate 가 주입).
    var onOpenResult: ((URL?) -> Void)?

    func requestAuthorization() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.authorized = granted
            if let error { NSLog("SkillsOnMenu: notification authorization failed — \(error.localizedDescription)") }
        }
    }

    func notify(state: RunState, card: SkillCard, elapsed: TimeInterval, resultURL: URL?) {
        let title: String
        let body: String
        switch state {
        case .success:
            title = "\(card.emoji) \(card.title) 완료"
            body = String(format: "%.0f초 만에 끝났습니다. 결과를 확인하세요.", elapsed)
        case .failed(let msg):
            title = "\(card.emoji) \(card.title) 실패"
            body = msg.components(separatedBy: .newlines).first ?? "오류가 발생했습니다."
        case .cancelled:
            title = "\(card.emoji) \(card.title) 중단"
            body = "실행을 중단했습니다."
        default:
            return
        }
        post(title: title, body: body, resultURL: resultURL)
    }

    private func post(title: String, body: String, resultURL: URL?) {
        guard available, authorized else {
            fallback(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let resultURL { content.userInfo = ["resultPath": resultURL.path] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if error != nil { self.fallback(title: title, body: body) }
        }
    }

    /// 알림 권한이 없을 때: AppleScript 로 시스템 알림을 띄운다.
    private func fallback(title: String, body: String) {
        guard let osa = ProcessRunner.which("osascript") else { return }
        let escape: (String) -> String = {
            $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        DispatchQueue.global(qos: .utility).async {
            _ = ProcessRunner.run(executable: osa, arguments: ["-e", script], timeout: 15)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["resultPath"] as? String
        DispatchQueue.main.async {
            self.onOpenResult?(path.map { URL(fileURLWithPath: $0) })
        }
        completionHandler()
    }
}
