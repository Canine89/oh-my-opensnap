import AppKit

// 1024x1024 앱 아이콘 렌더링 — 레드 스퀘어클 + 흰 캡처 프레임 + 크로스헤어
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// 스퀘어클 배경
let margin: CGFloat = 92
let rect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let corner = rect.width * 0.2237
let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

cg.saveGState()
cg.addPath(squircle); cg.clip()
let colors = [NSColor(srgbRed: 0.96, green: 0.27, blue: 0.21, alpha: 1).cgColor,
              NSColor(srgbRed: 0.82, green: 0.12, blue: 0.12, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
cg.restoreGState()

// 캡처 프레임 (네 모서리 브래킷)
let inset: CGFloat = margin + 168
let frame = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let arm: CGFloat = 132
let white = NSColor.white

func bracket(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = 52
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: CGPoint(x: p.x + dx * arm, y: p.y))
    path.line(to: p)
    path.line(to: CGPoint(x: p.x, y: p.y + dy * arm))
    white.setStroke()
    path.stroke()
}
bracket(CGPoint(x: frame.minX, y: frame.maxY), 1, -1)
bracket(CGPoint(x: frame.maxX, y: frame.maxY), -1, -1)
bracket(CGPoint(x: frame.minX, y: frame.minY), 1, 1)
bracket(CGPoint(x: frame.maxX, y: frame.minY), -1, 1)

// 중앙 크로스헤어 (가운데 살짝 비움)
let cx = size / 2, cy = size / 2
let reach: CGFloat = 150
let gap: CGFloat = 46
let cross = NSBezierPath()
cross.lineWidth = 30
cross.lineCapStyle = .round
cross.move(to: CGPoint(x: cx - reach, y: cy)); cross.line(to: CGPoint(x: cx - gap, y: cy))
cross.move(to: CGPoint(x: cx + gap, y: cy)); cross.line(to: CGPoint(x: cx + reach, y: cy))
cross.move(to: CGPoint(x: cx, y: cy - reach)); cross.line(to: CGPoint(x: cx, y: cy - gap))
cross.move(to: CGPoint(x: cx, y: cy + gap)); cross.line(to: CGPoint(x: cx, y: cy + reach))
white.withAlphaComponent(0.95).setStroke()
cross.stroke()

// 중앙 점
let dot = NSBezierPath(ovalIn: CGRect(x: cx - 17, y: cy - 17, width: 34, height: 34))
white.setFill(); dot.fill()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("written: \(CommandLine.arguments[1])")
