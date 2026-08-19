import AppKit
import Carbon.HIToolbox

// MARK: - Carbon 전역 단축키

/// Carbon `RegisterEventHotKey` 기반 전역 단축키.
/// NSEvent 전역 모니터와 달리 손쉬운 사용(Accessibility) 권한이 필요하지 않다.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534F4D55) /* 'SOMU' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("SkillsOnMenu: hotkey registration failed (status \(status))")
            return nil
        }
        refs[id] = ref
        actions[id] = action
        return id
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return err }
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id: hkID.id) }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

// MARK: - 표시 문자열

enum HotKeyFormatter {
    static let cmd: UInt32 = UInt32(cmdKey)
    static let shift: UInt32 = UInt32(shiftKey)
    static let option: UInt32 = UInt32(optionKey)
    static let control: UInt32 = UInt32(controlKey)

    static func string(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & control != 0 { s += "⌃" }
        if modifiers & option != 0 { s += "⌥" }
        if modifiers & shift != 0 { s += "⇧" }
        if modifiers & cmd != 0 { s += "⌘" }
        s += keyName(keyCode)
        return s
    }

    static func keyName(_ code: UInt32) -> String {
        if let n = names[Int(code)] { return n }
        return "키(\(code))"
    }

    /// NSEvent 수정자 → Carbon 마스크
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= cmd }
        if flags.contains(.option) { m |= option }
        if flags.contains(.shift) { m |= shift }
        if flags.contains(.control) { m |= control }
        return m
    }

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Minus: "-",
        kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
}
