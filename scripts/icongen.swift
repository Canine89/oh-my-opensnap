import AppKit

// 1024x1024 앱 아이콘 렌더링 - 단일 적색 바탕 위 정밀 캡처 프레임.
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// 스퀘어클 배경. 시스템 아이콘과 나란히 놓여도 과하게 빛나지 않는 매트한 적색을 쓴다.
let margin: CGFloat = 64
let rect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let corner = rect.width * 0.2237
let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

cg.saveGState()
cg.addPath(squircle); cg.clip()
cg.setFillColor(NSColor(srgbRed: 0.88, green: 0.20, blue: 0.18, alpha: 1).cgColor)
cg.fill(rect)
cg.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
cg.setLineWidth(8)
cg.stroke(rect.insetBy(dx: 4, dy: 4))
cg.restoreGState()

// 캡처 대상. 어두운 내부면과 흰 프레임을 분리해 작은 크기에서도 선명하게 읽힌다.
let frame = CGRect(x: 216, y: 252, width: 592, height: 520)
let inner = frame.insetBy(dx: 34, dy: 34)
let innerPath = CGPath(roundedRect: inner, cornerWidth: 54, cornerHeight: 54, transform: nil)
cg.addPath(innerPath)
cg.setFillColor(NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1).cgColor)
cg.fillPath()

// 네 모서리 브래킷. 중앙을 비워 둬 실제 캡처 범위를 고르는 감각을 만든다.
let arm: CGFloat = 156
let white = NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)

func bracket(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = 46
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

// 중심의 캡처 기준점. 실제 상태를 뜻하는 적색 하나만 남겨 장식을 줄인다.
let dot = NSBezierPath(ovalIn: CGRect(x: 482, y: 482, width: 60, height: 60))
NSColor(srgbRed: 0.88, green: 0.20, blue: 0.18, alpha: 1).setFill(); dot.fill()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("written: \(CommandLine.arguments[1])")
