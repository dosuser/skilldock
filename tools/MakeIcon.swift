// 앱 아이콘 원본 PNG(1024x1024)를 그린다.
// 사용법: swift tools/MakeIcon.swift build/icon.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 배경 — 보라 → 청록 대각선 그라디언트를 squircle 에 채운다.
let inset: CGFloat = size * 0.06
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.235
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.486, green: 0.361, blue: 1.0, alpha: 1),   // #7C5CFF
    NSColor(srgbRed: 0.071, green: 0.710, blue: 0.796, alpha: 1), // #12B5CB
])!
gradient.draw(in: path, angle: -45)

// 상단 하이라이트로 입체감을 살짝 준다.
NSGraphicsContext.saveGraphicsState()
path.addClip()
NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 번개 글리프
let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .bold)
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
