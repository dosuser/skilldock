import SwiftUI
import AppKit

// MARK: - 색

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = .accentColor
            return
        }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}

// MARK: - 디자인 토큰

enum Theme {
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 9
    static let popoverWidth: CGFloat = 420
    static let popoverHeight: CGFloat = 560

    /// 카드 색상 팔레트 — 채도를 맞춰 나열해도 서로 부딪히지 않게 골랐다.
    static let palette: [String] = [
        "#6E7BFF", "#7C5CFF", "#B45CFF", "#FF5C93", "#FF7043",
        "#FFB300", "#3DC98B", "#12B5CB", "#4C8DFF", "#8D9AA8",
    ]

    static let emojiChoices: [String] = [
        "✨", "🚀", "📊", "📝", "🔍", "🗂️", "📅", "💬", "🎨", "🧭",
        "🛠️", "🔔", "📦", "🧪", "☁️", "🌙", "⚡️", "🎯", "🧠", "📮",
    ]

    static func gradient(_ hex: String) -> LinearGradient {
        let base = Color(hex: hex)
        return LinearGradient(colors: [base, base.opacity(0.72)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func title(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)

    static var separator: Color { Color(nsColor: .separatorColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var subtleFill: Color { Color.primary.opacity(0.055) }
}

// MARK: - 재사용 뷰

/// 카드·목록 앞에 붙는 이모지 배지.
struct EmojiBadge: View {
    let emoji: String
    let tint: String
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Theme.gradient(tint))
            .frame(width: size, height: size)
            .overlay(Text(emoji).font(.system(size: size * 0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: Color(hex: tint).opacity(0.28), radius: 5, x: 0, y: 2)
    }
}

/// 강조 버튼 (실행 등).
struct PrimaryButtonStyle: ButtonStyle {
    var tint: String = "#6E7BFF"
    var disabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.title(13, .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Theme.gradient(tint))
                    .opacity(disabled ? 0.4 : (configuration.isPressed ? 0.82 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// 보조 버튼 (취소·복사 등).
struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius - 2, style: .continuous)
                    .fill(Theme.subtleFill.opacity(configuration.isPressed ? 1.6 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// 상태 배지 (성공/실패/실행 중).
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// 잔잔하게 움직이는 진행 표시. "지금 뭔가 돌고 있다"만 전달한다.
struct PulsingDots: View {
    let tint: String
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(hex: tint))
                    .frame(width: 5, height: 5)
                    .opacity(phase == i ? 1 : 0.28)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { t in
                guard Thread.isMainThread else { return }
                withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 }
                if !t.isValid { t.invalidate() }
            }
        }
    }
}

/// 섹션 제목.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.none)
            .tracking(0.3)
    }
}

/// 값이 비었을 때 보여주는 자리 표시자.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(Theme.title(14))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SubtleButtonStyle())
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
