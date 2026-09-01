import AppKit

// 단일 고해상도 원본을 macOS AppIcon.appiconset의 실제 픽셀 크기로 내보낸다.
// 이미지 생성 원본의 검은 바깥 모서리는 표준 macOS 아이콘 곡률의 투명 영역으로 처리한다.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("사용법: make-app-icon-set.swift <원본 PNG> <AppIcon.appiconset 경로>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let destinationURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("원본 이미지를 열 수 없습니다: \(sourceURL.path)\n", stderr)
    exit(1)
}

let icons: [(name: String, pixels: Int)] = [
    ("icon_16.png", 16),
    ("icon_32.png", 32),
    ("icon_64.png", 64),
    ("icon_128.png", 128),
    ("icon_256.png", 256),
    ("icon_512.png", 512),
    ("icon_1024.png", 1024),
]

for icon in icons {
    let side = CGFloat(icon.pixels)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: icon.pixels,
        pixelsHigh: icon.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setFillColor(NSColor.clear.cgColor)
    context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side))

    // 생성 이미지의 유리 타일 윤곽과 macOS의 둥근 앱 아이콘 비율을 맞춘다.
    let iconBounds = CGRect(x: 0, y: 0, width: side, height: side)
    let path = NSBezierPath(roundedRect: iconBounds, xRadius: side * 0.222, yRadius: side * 0.222)
    path.addClip()
    source.draw(in: iconBounds, from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
        fputs("PNG를 만들 수 없습니다: \(icon.name)\n", stderr)
        exit(1)
    }
    try data.write(to: destinationURL.appendingPathComponent(icon.name), options: Data.WritingOptions.atomic)
}

print("AppIcon.appiconset 생성 완료: \(destinationURL.path)")
