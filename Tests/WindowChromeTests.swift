import XCTest
import ApplicationServices
import CoreGraphics

final class WindowChromeTests: XCTestCase {
    private typealias Node = WindowChromeDetector.TestNode

    // MARK: - Helpers

    /// 지정된 사각형 목록을 순서대로 칠해 테스트용 디스플레이 정지 화면(BGRA 8-bit)을 만든다.
    /// 좌표는 디스플레이 좌상단 기준 픽셀 좌표다.
    private func makeImage(widthPx: Int,
                           heightPx: Int,
                           background: (r: UInt8, g: UInt8, b: UInt8),
                           fills: [(rect: CGRect, color: (r: UInt8, g: UInt8, b: UInt8))]) -> CGImage {
        let stride = widthPx * 4
        var data = [UInt8](repeating: 255, count: stride * heightPx)
        for y in 0..<heightPx {
            for x in 0..<widthPx {
                let offset = y * stride + x * 4
                data[offset] = background.b
                data[offset + 1] = background.g
                data[offset + 2] = background.r
                data[offset + 3] = 255
            }
        }
        for item in fills {
            let r = item.rect.integral.intersection(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
            guard !r.isEmpty else { continue }
            for y in Int(r.minY)..<Int(r.maxY) {
                for x in Int(r.minX)..<Int(r.maxX) {
                    let offset = y * stride + x * 4
                    data[offset] = item.color.b
                    data[offset + 1] = item.color.g
                    data[offset + 2] = item.color.r
                    data[offset + 3] = 255
                }
            }
        }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: widthPx,
                       height: heightPx,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    // MARK: - WindowChromeDetector (AX 트리 측정)

    func testRexBetaSinglePaneMeasuresTerminalContentStart() {
        let winRect = CGRect(x: 64, y: 30, width: 2495, height: 1410)
        let tree = Node(frame: winRect, role: kAXWindowRole, subrole: kAXStandardWindowSubrole, children: [
            Node(frame: winRect, role: kAXGroupRole, subrole: "AXHostingView", children: [
                Node(frame: CGRect(x: 64, y: 30, width: 2495, height: 46), role: kAXGroupRole),
                Node(frame: CGRect(x: 64, y: 76, width: 2495, height: 1364), role: kAXGroupRole, children: [
                    Node(frame: CGRect(x: 72, y: 76, width: 2479, height: 1356), role: kAXSplitGroupRole, children: [
                        Node(frame: CGRect(x: 72, y: 76, width: 2479, height: 1356), role: kAXGroupRole, children: [
                            Node(frame: CGRect(x: 78, y: 76, width: 2340, height: 36), role: kAXGroupRole),
                            Node(frame: CGRect(x: 2426, y: 76, width: 118, height: 36), role: kAXGroupRole),
                            Node(frame: CGRect(x: 72, y: 112, width: 2479, height: 1320), role: kAXTextAreaRole)
                        ])
                    ])
                ])
            ]),
            Node(frame: CGRect(x: 79, y: 45, width: 16, height: 16), role: kAXButtonRole, subrole: kAXCloseButtonSubrole)
        ])

        let measured = WindowChromeDetector.measure(testWindow: tree, fullRect: winRect)
        XCTAssertEqual(measured, WindowChromeDetector.Measurement(inset: 82, isAuthoritative: true))
    }

    func testRexBetaSplitPanesWithSidebarStillMeasuresPaneBodyStart() {
        // 좌우 2분할 터미널(각각 창 폭의 ~42%)과 왼쪽 좁은 사이드바(15%, y=76 시작)가 함께 있을 때:
        // 개별 터미널 폭이 55% 미만이어도 같은 y=112에서 합산 폭이 84%이므로 82pt가 선택되어야 한다.
        let winRect = CGRect(x: 64, y: 30, width: 2495, height: 1410)
        let tree = Node(frame: winRect, role: kAXWindowRole, children: [
            Node(frame: winRect, role: kAXGroupRole, children: [
                Node(frame: CGRect(x: 64, y: 30, width: 2495, height: 46), role: kAXGroupRole),
                Node(frame: CGRect(x: 64, y: 76, width: 2495, height: 1364), role: kAXSplitGroupRole, children: [
                    // 좁은 사이드바(폭 360 / 2495 = 14.4%, y=76 -> top 46pt)
                    Node(frame: CGRect(x: 64, y: 76, width: 360, height: 1356), role: kAXOutlineRole),
                    // 왼쪽 터미널 패널 (폭 1055 / 2495 = 42.3%, y=112 -> top 82pt)
                    Node(frame: CGRect(x: 432, y: 76, width: 1055, height: 1356), role: kAXGroupRole, children: [
                        Node(frame: CGRect(x: 432, y: 76, width: 1055, height: 36), role: kAXGroupRole),
                        Node(frame: CGRect(x: 432, y: 112, width: 1055, height: 1320), role: kAXTextAreaRole)
                    ]),
                    // 오른쪽 터미널 패널 (폭 1056 / 2495 = 42.3%, y=112 -> top 82pt)
                    Node(frame: CGRect(x: 1495, y: 76, width: 1056, height: 1356), role: kAXGroupRole, children: [
                        Node(frame: CGRect(x: 1495, y: 76, width: 1056, height: 36), role: kAXGroupRole),
                        Node(frame: CGRect(x: 1495, y: 112, width: 1056, height: 1320), role: kAXTextAreaRole)
                    ])
                ])
            ])
        ])

        let measured = WindowChromeDetector.measure(testWindow: tree, fullRect: winRect)
        XCTAssertEqual(measured, WindowChromeDetector.Measurement(inset: 82, isAuthoritative: true))
    }

    func testTrafficLightSymmetricHeightAndDeepWrapperSplitNeverCutThroughTitlebar() {
        // 신호등이 y=48(창 상단 30에서 +18pt, 높이 16pt)에 있는 Electron/Chromium 창:
        // 대칭 높이는 18 + 16 + 18 = 52pt여야 하며, 버튼 하단(34pt)이나 기본값(32pt)으로 잘리면 안 된다.
        let winRect = CGRect(x: 65, y: 30, width: 2495, height: 1410)
        var wrapped = Node(frame: winRect, role: kAXGroupRole, children: [])
        for _ in 0..<6 {
            wrapped = Node(frame: winRect, role: kAXGroupRole, children: [wrapped])
        }
        let tree = Node(frame: winRect, role: kAXWindowRole, children: [
            wrapped,
            Node(frame: CGRect(x: 80, y: 48, width: 16, height: 16), role: kAXButtonRole, subrole: kAXCloseButtonSubrole)
        ])

        let measured = WindowChromeDetector.measure(testWindow: tree, fullRect: winRect)
        XCTAssertEqual(measured, WindowChromeDetector.Measurement(inset: 52, isAuthoritative: false))
    }

    func testDeeplyNestedFigmaStyleSplitFinds38ptBar() {
        let winRect = CGRect(x: 65, y: 30, width: 2495, height: 1410)
        let splitNode = Node(frame: winRect, role: kAXGroupRole, children: [
            Node(frame: CGRect(x: 65, y: 30, width: 2495, height: 38), role: kAXGroupRole),
            Node(frame: CGRect(x: 65, y: 68, width: 2495, height: 1372), role: kAXGroupRole)
        ])
        var root = splitNode
        for _ in 0..<6 {
            root = Node(frame: winRect, role: kAXGroupRole, children: [root])
        }
        let window = Node(frame: winRect, role: kAXWindowRole, children: [
            root,
            Node(frame: CGRect(x: 76, y: 41, width: 16, height: 16), role: kAXButtonRole, subrole: kAXCloseButtonSubrole)
        ])

        let measured = WindowChromeDetector.measure(testWindow: window, fullRect: winRect)
        XCTAssertEqual(measured, WindowChromeDetector.Measurement(inset: 38, isAuthoritative: false))
    }

    // MARK: - HeaderEdgeRefiner & WindowHeaderResolver (픽셀 경계 + 결합)

    func testRexBetaWithoutAXResolvesTo82ptEvenWithSeamlessDarkPaneHeader() {
        // 접근성 권한이 없고, 다크 테마에서 탭바(46pt)만 색이 다르며 패널 헤더(46~82pt)와
        // 터미널 본문(82pt~)이 완전히 같은 배경색인 경우에도 46pt에 걸치지 않고 82pt로 잡혀야 한다.
        let scale: CGFloat = 2
        let winRect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let image = makeImage(
            widthPx: 1600,
            heightPx: 1200,
            background: (13, 13, 15),
            fills: [
                // 상단 탭바 0..46pt (0..92px)만 구분되고 46..82pt 패널 헤더는 본문과 같은 색
                (CGRect(x: 0, y: 0, width: 1600, height: 92), (26, 26, 30))
            ]
        )

        let resolved = WindowHeaderResolver.resolve(windowRect: winRect,
                                                    bundleID: "com.superlogical.rex",
                                                    appName: "Rex Beta",
                                                    axMeasurement: nil,
                                                    snapshot: image,
                                                    snapshotScale: scale)
        XCTAssertEqual(resolved.inset, 82, accuracy: 1.0)
    }

    func testRexBetaWithoutAXSnapsToSubtleDarkDividerAtPaneHeaderBottom() {
        // 다크 테마에서 탭바(46pt)와 패널 헤더 하단(82pt)에 미세한 1pt(2px) 구분선만 있는 경우
        // 구분선 픽셀을 헤더 쪽으로 넘기고 정확히 82pt(구분선 바로 아래)를 찾는다.
        let scale: CGFloat = 2
        let winRect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let image = makeImage(
            widthPx: 1600,
            heightPx: 1200,
            background: (18, 18, 21),
            fills: [
                (CGRect(x: 0, y: 0, width: 1600, height: 92), (28, 28, 33)),
                // 81..82pt (162..164px)에 RGB 합 차 21짜리 미세 다크모드 헤어라인
                (CGRect(x: 16, y: 162, width: 1568, height: 2), (25, 25, 28))
            ]
        )

        let resolved = WindowHeaderResolver.resolve(windowRect: winRect,
                                                    bundleID: "com.superlogical.rex",
                                                    appName: "Rex Beta",
                                                    axMeasurement: nil,
                                                    snapshot: image,
                                                    snapshotScale: scale)
        XCTAssertEqual(resolved.inset, 82, accuracy: 0.5)
        XCTAssertTrue(resolved.isPrecise)
    }

    func testMultiBandBrowserStepsAcrossTabAndAddressBarIgnoringOmniboxAndWebsiteNavbar() {
        // 브라우저: 탭바(0..44pt) + 주소창 바(44..88pt, 내부에 중앙 플로팅 URL 입력창 52..78pt 포함)
        // + 웹페이지 자체 상단 내비게이션 바(88..150pt, 높이 62pt).
        // 결과는 주소창 하단(88pt)이어야 하며, 중앙 URL 입력창(78pt)에 멈추거나 웹 내비게이션(150pt)을 잘라내면 안 된다.
        let scale: CGFloat = 2
        let winRect = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let image = makeImage(
            widthPx: 2000,
            heightPx: 1400,
            background: (255, 255, 255),
            fills: [
                // 탭바 0..44pt
                (CGRect(x: 0, y: 0, width: 2000, height: 88), (32, 33, 36)),
                // 주소창 툴바 44..88pt
                (CGRect(x: 0, y: 88, width: 2000, height: 88), (53, 54, 58)),
                // 주소창 안쪽 중앙 플로팅 URL 알약(좌우 여백 240px씩 떨어져 있음 -> 양 끝 비접촉)
                (CGRect(x: 240, y: 104, width: 1520, height: 52), (32, 33, 36)),
                // 웹페이지 자체 헤더 88..150pt (높이 62pt)
                (CGRect(x: 0, y: 176, width: 2000, height: 124), (242, 244, 247))
            ]
        )

        let axMin = WindowChromeDetector.Measurement(inset: 44, isAuthoritative: false)
        let resolved = WindowHeaderResolver.resolve(windowRect: winRect,
                                                    bundleID: "com.citrolabs.ego.lite",
                                                    appName: "ego lite",
                                                    axMeasurement: axMin,
                                                    snapshot: image,
                                                    snapshotScale: scale)
        XCTAssertEqual(resolved.inset, 88, accuracy: 1.0)
        XCTAssertTrue(resolved.isPrecise)
    }

    func testFinderListViewDoesNotStepIntoRightPaneColumnHeader() {
        // 통합 툴바(52pt, 창 전체 폭) 아래에 왼쪽 사이드바(25% 폭)와 오른쪽 목록 컬럼 헤더(52..79pt, 75% 폭)가 있을 때:
        // 이미 52pt 전체 폭 툴바가 끝났으므로 79pt 목록 컬럼 헤더로 내려가지 않고 52pt에서 멈춰야 한다.
        let scale: CGFloat = 2
        let winRect = CGRect(x: 0, y: 0, width: 920, height: 500)
        let image = makeImage(
            widthPx: 1840,
            heightPx: 1000,
            background: (30, 30, 32),
            fills: [
                // 상단 전체 폭 툴바 0..52pt (0..104px)
                (CGRect(x: 0, y: 0, width: 1840, height: 104), (48, 48, 52)),
                // 왼쪽 사이드바 52..500pt (x = 0..460px)
                (CGRect(x: 0, y: 104, width: 460, height: 896), (38, 38, 42)),
                // 오른쪽 목록 컬럼 헤더 구분선 79pt (158..160px, x = 460..1840px -> 75% 폭)
                (CGRect(x: 460, y: 158, width: 1380, height: 2), (65, 65, 70))
            ]
        )

        let resolved = WindowHeaderResolver.resolve(windowRect: winRect,
                                                    bundleID: "com.apple.finder",
                                                    appName: "Finder",
                                                    axMeasurement: nil,
                                                    snapshot: image,
                                                    snapshotScale: scale)
        XCTAssertEqual(resolved.inset, 52, accuracy: 1.0)
    }

    func testWindowPartiallyAboveDisplayPreservesTrueWindowOffset() {
        // 창 상단 20pt가 화면 위로 나가 있을 때(minY = -20), 실제 헤더가 80pt라면
        // 화면 안 y=60pt(120px) 위치의 경계를 창 상단 기준 80pt로 정확히 환산해야 한다.
        let scale: CGFloat = 2
        let winRect = CGRect(x: 100, y: -20, width: 600, height: 500)
        let image = makeImage(
            widthPx: 1600,
            heightPx: 1200,
            background: (250, 250, 250),
            fills: [
                // 화면 기준 0..60pt (0..120px)가 헤더 = 창 상단(-20pt) 기준 80pt 헤더
                (CGRect(x: 200, y: 0, width: 1200, height: 120), (45, 45, 50))
            ]
        )

        let detected = HeaderEdgeRefiner.detectHeaderInset(in: image,
                                                           windowRect: winRect,
                                                           searchRange: 40...110,
                                                           preferredInset: 80,
                                                           minimumInset: 40,
                                                           scale: scale)
        XCTAssertNotNil(detected)
        XCTAssertEqual(detected ?? 0, 80, accuracy: 1.0)
    }
}
