// 앱 아이콘 원본 PNG(1024x1024)를 그린다.
// 사용법: swift tools/MakeIcon.swift build/icon.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 배경 — 작은 크기에서도 흐리지 않도록, 대비가 높은 한 방향 그라디언트를 쓴다.
let inset: CGFloat = size * 0.06
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.235
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.12, green: 0.18, blue: 0.42, alpha: 1),   // #1F2E6B
    NSColor(srgbRed: 0.25, green: 0.45, blue: 1.00, alpha: 1),   // #3F73FF
])!
gradient.draw(in: path, angle: -45)

// 상단 하이라이트로 입체감을 살짝 준다.
NSGraphicsContext.saveGraphicsState()
path.addClip()
NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Dock: 세 장의 작업 카드와 받침을 아주 단순한 형태로 표현한다.
// 작은 16px 아이콘에서도 '실행 지점'을 읽을 수 있게 번개보다 뒤로 물린다.
let dockWidth = size * 0.54
let dockHeight = size * 0.17
let dockRect = NSRect(x: (size - dockWidth) / 2, y: size * 0.23,
                      width: dockWidth, height: dockHeight)
NSColor(white: 1, alpha: 0.22).setFill()
NSBezierPath(roundedRect: dockRect, xRadius: dockHeight / 2, yRadius: dockHeight / 2).fill()

let cardWidth = size * 0.115
let cardHeight = size * 0.21
let cardGap = size * 0.035
let cardStart = (size - (cardWidth * 3 + cardGap * 2)) / 2
for index in 0..<3 {
    let height = cardHeight * (index == 1 ? 1.0 : 0.82)
    let x = cardStart + CGFloat(index) * (cardWidth + cardGap)
    let y = dockRect.maxY + size * 0.035
    NSColor(white: 1, alpha: index == 1 ? 0.34 : 0.20).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cardWidth, height: height),
                 xRadius: size * 0.025, yRadius: size * 0.025).fill()
}

// 실행 신호: Dock 위의 단일 번개 글리프.
let config = NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .black)
if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: bolt.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: bolt.size)
    bolt.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let target = NSRect(x: (size - bolt.size.width) / 2,
                        y: (size - bolt.size.height) / 2,
                        width: bolt.size.width,
                        height: bolt.size.height)
    tinted.draw(in: target)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("아이콘 렌더링 실패\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("아이콘 생성: \(outPath)")
