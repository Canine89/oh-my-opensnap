import CoreGraphics
import CoreVideo
import Foundation

/// 앱 종류별 기본 헤더 높이 추정치와 픽셀 경계 탐색 범위.
/// 접근성 권한이 없거나 앱이 내부 구조를 숨길 때 초기값·탐색 가이드로 사용한다.
struct WindowChromeProfile: Equatable {
    let defaultInset: CGFloat
    let searchRange: ClosedRange<CGFloat>

    static func forApp(bundleID: String?, appName: String?, windowHeight: CGFloat) -> WindowChromeProfile {
        guard windowHeight >= 120 else {
            return WindowChromeProfile(defaultInset: 0, searchRange: 0...0)
        }
        let bundle = (bundleID ?? "").lowercased()
        let name = (appName ?? "").lowercased()

        let rawDefault: CGFloat
        let rawLower: CGFloat
        let rawUpper: CGFloat

        if isRex(bundleID: bundle, appName: name) {
            // 상단 탭바(46pt) + 분할 패널 헤더(36pt) = 82pt.
            // 패널 헤더와 터미널 배경색이 같아 경계선이 없는 테마에서도 패널 헤더를 본문에 남기지 않는다.
            rawDefault = 82
            rawLower = 70
            rawUpper = 112
        } else if bundle.contains("com.apple.safari") {
            rawDefault = 84
            rawLower = 46
            rawUpper = 132
        } else if isBrowser(bundleID: bundle, appName: name) {
            rawDefault = 88
            rawLower = 42
            rawUpper = 132
        } else if bundle.contains("com.apple.finder") {
            rawDefault = 56
            rawLower = 44
            rawUpper = 92
        } else if bundle.contains("com.apple.dt.xcode") {
            rawDefault = 80
            rawLower = 46
            rawUpper = 116
        } else if isCodeEditor(bundleID: bundle, appName: name) {
            // 커스텀 타이틀바(~35pt) + 에디터 탭바(~35pt).
            rawDefault = 70
            rawLower = 34
            rawUpper = 108
        } else if bundle.contains("com.kakao.kakaotalk") || bundle.contains("com.kakao.talk") {
            // 메인 목록 창(~55pt)과 대화방 헤더(~88pt) 모두 탐색 범위에 포함한다.
            rawDefault = 64
            rawLower = 48
            rawUpper = 104
        } else if bundle.contains("com.figma.desktop") {
            // UI3 상단 탭바(38pt)와 클래식 상단 툴바(~84pt) 양쪽을 포괄한다.
            rawDefault = 48
            rawLower = 34
            rawUpper = 104
        } else if isTerminal(bundleID: bundle, appName: name) {
            rawDefault = 36
            rawLower = 24
            rawUpper = 96
        } else if bundle.contains("com.apple.preview") {
            rawDefault = 52
            rawLower = 32
            rawUpper = 88
        } else {
            rawDefault = 38
            rawLower = 24
            rawUpper = 108
        }

        let cap = max(24, windowHeight * 0.38)
        let clampedDefault = min(rawDefault, cap)
        let lower = min(rawLower, cap)
        let upper = max(lower, min(rawUpper, cap))
        return WindowChromeProfile(defaultInset: clampedDefault, searchRange: lower...upper)
    }

    private static func isRex(bundleID: String, appName: String) -> Bool {
        bundleID.contains("com.superlogical.rex")
            || appName == "rex"
            || appName == "rex beta"
    }

    private static func isBrowser(bundleID: String, appName: String) -> Bool {
        bundleID.contains("com.google.chrome")
            || bundleID.contains("org.chromium")
            || bundleID.contains("com.citrolabs.ego")
            || bundleID.contains("com.microsoft.edgemac")
            || bundleID.contains("org.mozilla.firefox")
            || bundleID.contains("com.brave.browser")
            || bundleID.contains("com.operasoftware.opera")
            || bundleID.contains("company.thebrowser.browser")
            || bundleID.contains("company.thebrowser.dia")
            || bundleID.contains("com.vivaldi.vivaldi")
            || bundleID.contains("com.kagi.kagimacos")
            || bundleID.contains("app.zen-browser.zen")
            || bundleID.contains("com.naver.whale")
            || appName == "ego lite"
            || appName == "arc"
    }

    private static func isCodeEditor(bundleID: String, appName: String) -> Bool {
        bundleID.contains("com.microsoft.vscode")
            || bundleID.contains("com.todesktop")
            || bundleID.contains("vscodium")
            || bundleID.contains("cursor")
            || bundleID.contains("windsurf")
            || bundleID.contains("antigravity")
            || bundleID.contains("dev.zed.zed")
            || bundleID.contains("com.jetbrains.")
            || appName == "code"
            || appName == "cursor"
            || appName == "zed"
    }

    private static func isTerminal(bundleID: String, appName: String) -> Bool {
        bundleID.contains("com.apple.terminal")
            || bundleID.contains("com.googlecode.iterm2")
            || bundleID.contains("dev.warp.warp")
            || bundleID.contains("com.mitchellh.ghostty")
            || bundleID.contains("net.kovidgoyal.kitty")
            || bundleID.contains("org.alacritty")
            || bundleID.contains("com.github.wez.wezterm")
            || appName == "ghostty"
            || appName == "warp"
    }
}

/// 접근성 측정치·픽셀 경계·앱 프로필을 결합해 최종 상단 헤더 인셋을 결정한다.
enum WindowHeaderResolver {
    struct Resolution: Equatable {
        let inset: CGFloat
        let isPrecise: Bool
    }

    static func resolve(windowRect: CGRect,
                        bundleID: String?,
                        appName: String?,
                        axMeasurement: WindowChromeDetector.Measurement?,
                        snapshot: CGImage?,
                        snapshotScale: CGFloat,
                        liveBuffer: CVPixelBuffer? = nil,
                        liveScale: CGFloat = 1) -> Resolution {
        let profile = WindowChromeProfile.forApp(bundleID: bundleID,
                                                 appName: appName,
                                                 windowHeight: windowRect.height)
        guard windowRect.height >= 120 else {
            return Resolution(inset: 0, isPrecise: false)
        }

        // 1) 접근성이 실제 본문 컨테이너의 시작점을 찾았으면 그 값을 신뢰하되,
        // 경계선 1~2px가 본문 첫 줄에 걸치지 않도록 주변 미세 구분선만 정리한다.
        if let ax = axMeasurement, ax.isAuthoritative {
            let snapped = snapHairline(windowRect: windowRect,
                                       around: ax.inset,
                                       snapshot: snapshot,
                                       snapshotScale: snapshotScale,
                                       liveBuffer: liveBuffer,
                                       liveScale: liveScale)
            return Resolution(inset: snapped ?? ax.inset, isPrecise: true)
        }

        // 2) 접근성이 최소 보장선(신호등 대칭 높이·래퍼 분할 등)만 줬다면 그 아래에 있는
        // 추가 툴바·주소창·패널 바를 픽셀 경계로 이어서 찾는다.
        if let ax = axMeasurement {
            let minBound = ax.inset
            let lower = max(20, minBound - 3)
            let upper = min(max(minBound + 54, profile.searchRange.upperBound),
                            max(lower, windowRect.height * 0.42))
            let preferred = max(minBound, profile.defaultInset)
            if let detected = detectEdge(windowRect: windowRect,
                                         searchRange: lower...upper,
                                         preferredInset: preferred,
                                         minimumInset: minBound,
                                         snapshot: snapshot,
                                         snapshotScale: snapshotScale,
                                         liveBuffer: liveBuffer,
                                         liveScale: liveScale) {
                return Resolution(inset: max(minBound, detected), isPrecise: true)
            }
            return Resolution(inset: minBound, isPrecise: true)
        }

        // 3) 접근성 정보가 없을 때는 앱별 탐색 구간 안에서 다단 헤더 경계를 찾는다.
        if profile.searchRange.upperBound > 0,
           let detected = detectEdge(windowRect: windowRect,
                                     searchRange: profile.searchRange,
                                     preferredInset: profile.defaultInset,
                                     minimumInset: profile.searchRange.lowerBound,
                                     snapshot: snapshot,
                                     snapshotScale: snapshotScale,
                                     liveBuffer: liveBuffer,
                                     liveScale: liveScale) {
            return Resolution(inset: detected, isPrecise: true)
        }

        return Resolution(inset: profile.defaultInset, isPrecise: false)
    }

    private static func snapHairline(windowRect: CGRect,
                                     around target: CGFloat,
                                     snapshot: CGImage?,
                                     snapshotScale: CGFloat,
                                     liveBuffer: CVPixelBuffer?,
                                     liveScale: CGFloat) -> CGFloat? {
        if let snapshot {
            return HeaderEdgeRefiner.snapHairline(in: snapshot,
                                                  windowRect: windowRect,
                                                  around: target,
                                                  tolerance: 3.5,
                                                  scale: snapshotScale)
        }
        if let liveBuffer {
            return HeaderEdgeRefiner.snapHairline(in: liveBuffer,
                                                  windowRect: windowRect,
                                                  around: target,
                                                  tolerance: 3.5,
                                                  scale: liveScale)
        }
        return nil
    }

    private static func detectEdge(windowRect: CGRect,
                                   searchRange: ClosedRange<CGFloat>,
                                   preferredInset: CGFloat,
                                   minimumInset: CGFloat,
                                   snapshot: CGImage?,
                                   snapshotScale: CGFloat,
                                   liveBuffer: CVPixelBuffer?,
                                   liveScale: CGFloat) -> CGFloat? {
        if let snapshot {
            return HeaderEdgeRefiner.detectHeaderInset(in: snapshot,
                                                       windowRect: windowRect,
                                                       searchRange: searchRange,
                                                       preferredInset: preferredInset,
                                                       minimumInset: minimumInset,
                                                       scale: snapshotScale)
        }
        if let liveBuffer {
            return HeaderEdgeRefiner.detectHeaderInset(in: liveBuffer,
                                                       windowRect: windowRect,
                                                       searchRange: searchRange,
                                                       preferredInset: preferredInset,
                                                       minimumInset: minimumInset,
                                                       scale: liveScale)
        }
        return nil
    }
}

/// 화면 픽셀에서 창의 헤더(타이틀바·탭바·툴바·패널 바)와 본문 사이의 수평 경계를 찾는다.
///
/// - 다크 모드 미세 구분선과 Retina 안티앨리어싱 경계까지 감지한다.
/// - 텍스트 줄이나 중앙에 떠 있는 주소창·검색창에 오작동하지 않도록, 창 가장자리에 닿는
///   긴 수평 연속 구간만 헤더 경계 후보로 인정한다.
/// - 탭바 아래에 주소창·패널 헤더가 이어지는 다단 헤더는 단 높이와 폭 일관성을 확인해
///   마지막 헤더 단 아래까지 내려간다.
enum HeaderEdgeRefiner {
    private struct HeaderStrip {
        let pixels: [UInt8]
        let cols: Int
        let rows: Int
        let bytesPerRow: Int
        let stripTopPx: CGFloat
        let windowTopPx: CGFloat
        let scale: CGFloat

        func inset(forRow row: Int) -> CGFloat {
            (stripTopPx + CGFloat(row) - windowTopPx) / scale
        }

        func row(forInset inset: CGFloat) -> Int {
            Int(((windowTopPx + inset * scale) - stripTopPx).rounded())
        }
    }

    private struct RowEvaluation {
        let row: Int
        let runCoverage: CGFloat
        let directCoverage: CGFloat
        let meanContrast: CGFloat
        let touchesLeft: Bool
        let touchesRight: Bool
    }

    private struct EdgeCandidate {
        let inset: CGFloat
        let runCoverage: CGFloat
        let meanContrast: CGFloat
        let touchesLeft: Bool
        let touchesRight: Bool
    }

    /// 기존 단일 후보 보정 진입점.
    static func refine(in image: CGImage,
                       windowRect: CGRect,
                       candidateInset: CGFloat,
                       tolerance: CGFloat,
                       scale: CGFloat) -> CGFloat? {
        let lower = max(16, candidateInset - tolerance)
        let upper = max(lower, candidateInset + tolerance)
        return detectHeaderInset(in: image,
                                 windowRect: windowRect,
                                 searchRange: lower...upper,
                                 preferredInset: candidateInset,
                                 minimumInset: lower,
                                 scale: scale)
    }

    /// 접근성으로 찾은 본문 시작점 바로 위아래(±tolerance)에 걸친 1~2px 구분선만 정리한다.
    static func snapHairline(in image: CGImage,
                             windowRect: CGRect,
                             around targetInset: CGFloat,
                             tolerance: CGFloat = 3.5,
                             scale: CGFloat) -> CGFloat? {
        let lower = max(16, targetInset - 2.0)
        let upper = max(lower, targetInset + tolerance)
        guard let strip = extractStrip(from: image,
                                       windowRect: windowRect,
                                       topInset: lower - 4,
                                       bottomInset: upper + 4,
                                       scale: scale)
        else { return nil }
        return snapHairline(in: strip, targetInset: targetInset, range: lower...upper)
    }

    static func snapHairline(in buffer: CVPixelBuffer,
                             windowRect: CGRect,
                             around targetInset: CGFloat,
                             tolerance: CGFloat = 3.5,
                             scale: CGFloat) -> CGFloat? {
        let lower = max(16, targetInset - 2.0)
        let upper = max(lower, targetInset + tolerance)
        guard let strip = extractStrip(from: buffer,
                                       windowRect: windowRect,
                                       topInset: lower - 4,
                                       bottomInset: upper + 4,
                                       scale: scale)
        else { return nil }
        return snapHairline(in: strip, targetInset: targetInset, range: lower...upper)
    }

    /// 탐색 구간 안에서 단층 또는 다단 헤더의 최종 하단 경계 높이를 찾는다.
    static func detectHeaderInset(in image: CGImage,
                                  windowRect: CGRect,
                                  searchRange: ClosedRange<CGFloat>,
                                  preferredInset: CGFloat,
                                  minimumInset: CGFloat,
                                  scale: CGFloat) -> CGFloat? {
        // 표/목록의 반복 행인지 판별할 수 있도록 탐색 상한 아래로도 여유 줄을 함께 읽는다.
        guard let strip = extractStrip(from: image,
                                       windowRect: windowRect,
                                       topInset: max(12, searchRange.lowerBound - 6),
                                       bottomInset: searchRange.upperBound + 42,
                                       scale: scale)
        else { return nil }
        return detectHeaderInset(in: strip,
                                 searchRange: searchRange,
                                 preferredInset: preferredInset,
                                 minimumInset: minimumInset)
    }

    static func detectHeaderInset(in buffer: CVPixelBuffer,
                                  windowRect: CGRect,
                                  searchRange: ClosedRange<CGFloat>,
                                  preferredInset: CGFloat,
                                  minimumInset: CGFloat,
                                  scale: CGFloat) -> CGFloat? {
        guard let strip = extractStrip(from: buffer,
                                       windowRect: windowRect,
                                       topInset: max(12, searchRange.lowerBound - 6),
                                       bottomInset: searchRange.upperBound + 42,
                                       scale: scale)
        else { return nil }
        return detectHeaderInset(in: strip,
                                 searchRange: searchRange,
                                 preferredInset: preferredInset,
                                 minimumInset: minimumInset)
    }

    // MARK: - Core detection

    private static func snapHairline(in strip: HeaderStrip,
                                     targetInset: CGFloat,
                                     range: ClosedRange<CGFloat>) -> CGFloat? {
        let candidates = extractCandidates(in: strip, range: range)
        guard let best = candidates.max(by: { lhs, rhs in
            let lScore = lhs.runCoverage - abs(lhs.inset - targetInset) * 0.03
            let rScore = rhs.runCoverage - abs(rhs.inset - targetInset) * 0.03
            return lScore < rScore
        }) else { return nil }
        return max(targetInset - 1.0, best.inset)
    }

    private static func detectHeaderInset(in strip: HeaderStrip,
                                          searchRange: ClosedRange<CGFloat>,
                                          preferredInset: CGFloat,
                                          minimumInset: CGFloat) -> CGFloat? {
        let lookaheadUpper = searchRange.upperBound + 38
        let allCandidates = extractCandidates(in: strip, range: searchRange.lowerBound...lookaheadUpper)
        let filtered = removePeriodicGridRows(from: allCandidates)
        let valid = filtered.filter {
            $0.inset >= max(searchRange.lowerBound, minimumInset - 1.5)
                && $0.inset <= searchRange.upperBound + 1.5
        }
        guard let first = valid.first else { return nil }

        // 첫 헤더 경계가 아무 상단 단서도 없이 본문 깊숙이(예: 테두리 없는 앱의 문서 구분선)에서
        // 시작하면 오탐으로 보고 버린다.
        let maxInitialInset = max(74, preferredInset + 28)
        guard first.inset <= maxInitialInset else { return nil }

        var current = first
        var steps = 0
        for candidate in valid.dropFirst() {
            guard steps < 2 else { break }
            let bandHeight = candidate.inset - current.inset
            if bandHeight < 16 {
                if candidate.runCoverage >= current.runCoverage - 0.08 {
                    current = candidate
                }
                continue
            }

            let maxBandHeight: CGFloat = current.inset <= 38 ? 58 : 46
            if bandHeight > maxBandHeight { break }
            guard candidate.inset <= searchRange.upperBound + 1.5 else { break }

            let fullWidthBar = candidate.runCoverage >= 0.86
            let paneToolbarBelowThinTitlebar = current.inset <= 44
                && candidate.runCoverage >= 0.55
                && (candidate.touchesRight || candidate.touchesLeft)
            let sameWidthStackedBar = abs(candidate.runCoverage - current.runCoverage) <= 0.10
                && candidate.runCoverage >= 0.55

            if fullWidthBar || paneToolbarBelowThinTitlebar || sameWidthStackedBar {
                current = candidate
                steps += 1
            }
        }

        return max(minimumInset, current.inset)
    }

    /// 스프레드시트·전체 폭 표처럼 일정 간격으로 4줄 이상 반복되는 행 경계는 첫 헤더만 남기고 제거한다.
    private static func removePeriodicGridRows(from candidates: [EdgeCandidate]) -> [EdgeCandidate] {
        guard candidates.count >= 4 else { return candidates }
        var periodicIndices = Set<Int>()
        for i in 0..<(candidates.count - 3) {
            let g1 = candidates[i + 1].inset - candidates[i].inset
            guard g1 >= 18, g1 <= 40 else { continue }
            var chain = [i + 1]
            var prev = candidates[i + 1].inset
            for j in (i + 2)..<candidates.count {
                let gap = candidates[j].inset - prev
                if abs(gap - g1) <= 4, candidates[j].runCoverage <= candidates[i].runCoverage + 0.06 {
                    chain.append(j)
                    prev = candidates[j].inset
                } else if gap > g1 + 4 {
                    break
                }
            }
            if chain.count >= 3 {
                periodicIndices.formUnion(chain)
            }
        }
        guard !periodicIndices.isEmpty else { return candidates }
        return candidates.enumerated().compactMap { periodicIndices.contains($0.offset) ? nil : $0.element }
    }

    private static func extractCandidates(in strip: HeaderStrip,
                                          range: ClosedRange<CGFloat>) -> [EdgeCandidate] {
        guard strip.rows >= 5, strip.cols >= 32 else { return [] }
        let startRow = max(2, strip.row(forInset: range.lowerBound))
        let endRow = min(strip.rows - 2, strip.row(forInset: range.upperBound))
        guard startRow <= endRow else { return [] }

        let extraTail = min(strip.rows - 1, endRow + max(2, Int(ceil(3.5 * strip.scale))))
        var evaluations: [RowEvaluation] = []
        evaluations.reserveCapacity(extraTail - startRow + 1)
        for row in startRow...extraTail {
            evaluations.append(evaluateRow(row, in: strip))
        }

        let byRow = Dictionary(uniqueKeysWithValues: evaluations.map { ($0.row, $0) })
        let qualifying = evaluations.filter { eval in
            eval.row <= endRow
                && eval.runCoverage >= 0.50
                && (eval.touchesLeft || eval.touchesRight)
        }
        guard !qualifying.isEmpty else { return [] }

        // 1~2pt 구분선의 윗변·아랫변처럼 인접한 강한 행들을 하나의 경계 클러스터로 묶는다.
        let clusterGap = max(2, Int(ceil(3.5 * strip.scale)))
        var clusters: [[RowEvaluation]] = []
        for eval in qualifying {
            if let last = clusters.last?.last, eval.row - last.row <= clusterGap {
                clusters[clusters.count - 1].append(eval)
            } else {
                clusters.append([eval])
            }
        }

        let maxAdvance = max(1, Int(ceil(2.5 * strip.scale)))
        return clusters.map { cluster in
            let best = cluster.max { lhs, rhs in
                let lScore = lhs.runCoverage * 100 + min(lhs.meanContrast, 80) * 0.15
                let rScore = rhs.runCoverage * 100 + min(rhs.meanContrast, 80) * 0.15
                return lScore < rScore
            }!

            // 구분선 픽셀 자체는 헤더에 남기고 본문 첫 깨끗한 줄에서 시작하도록 아래로 밀어낸다.
            var edgeRow = cluster.last!.row
            let tailLimit = min(extraTail, edgeRow + maxAdvance)
            if edgeRow < tailLimit {
                for r in (edgeRow + 1)...tailLimit {
                    if let nextEval = byRow[r], nextEval.directCoverage >= best.runCoverage * 0.55 {
                        edgeRow = r
                    } else {
                        break
                    }
                }
            }

            return EdgeCandidate(inset: strip.inset(forRow: edgeRow),
                                 runCoverage: best.runCoverage,
                                 meanContrast: best.meanContrast,
                                 touchesLeft: best.touchesLeft,
                                 touchesRight: best.touchesRight)
        }
    }

    private static func evaluateRow(_ row: Int, in strip: HeaderStrip) -> RowEvaluation {
        let stride = strip.bytesPerRow
        let cols = strip.cols
        let upper1 = (row - 1) * stride
        let current = row * stride
        let upper2 = max(0, row - 2) * stride
        let lower1 = min(strip.rows - 1, row + 1) * stride

        var stepHits = [Bool](repeating: false, count: cols)
        var directHits = 0
        var contrastSum = 0

        strip.pixels.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            for col in 0..<cols {
                let x = col * 4
                let d1 = abs(Int(ptr[current + x]) - Int(ptr[upper1 + x]))
                    + abs(Int(ptr[current + x + 1]) - Int(ptr[upper1 + x + 1]))
                    + abs(Int(ptr[current + x + 2]) - Int(ptr[upper1 + x + 2]))
                let d2 = abs(Int(ptr[lower1 + x]) - Int(ptr[upper2 + x]))
                    + abs(Int(ptr[lower1 + x + 1]) - Int(ptr[upper2 + x + 1]))
                    + abs(Int(ptr[lower1 + x + 2]) - Int(ptr[upper2 + x + 2]))

                let step = max(d1, (d2 * 3) / 4)
                if step >= 15 {
                    stepHits[col] = true
                    contrastSum += step
                }
                if d1 >= 10 {
                    directHits += 1
                }
            }
        }

        // 세로 분할선·커서 같은 1열 미세 끊김은 이어 붙인 뒤, 창 폭의 18% 이상 이어지는
        // 수평 연속 구간만 합산한다(글자·아이콘·버튼 조각 배제).
        let minRunLength = max(6, Int((CGFloat(cols) * 0.18).rounded()))
        let edgeMargin = max(2, Int((CGFloat(cols) * 0.05).rounded()))
        var bridged = stepHits
        if cols >= 3 {
            for col in 1..<(cols - 1) where !bridged[col] && stepHits[col - 1] && stepHits[col + 1] {
                bridged[col] = true
            }
        }

        var runCols = 0
        var touchesLeft = false
        var touchesRight = false
        var index = 0
        while index < cols {
            guard bridged[index] else { index += 1; continue }
            let start = index
            while index < cols, bridged[index] { index += 1 }
            let length = index - start
            if length >= minRunLength {
                runCols += length
                if start <= edgeMargin { touchesLeft = true }
                if index - 1 >= cols - 1 - edgeMargin { touchesRight = true }
            }
        }

        let hitCount = max(1, stepHits.filter { $0 }.count)
        let meanContrast = runCols > 0 ? CGFloat(contrastSum) / CGFloat(hitCount) : 0
        return RowEvaluation(row: row,
                             runCoverage: CGFloat(runCols) / CGFloat(cols),
                             directCoverage: CGFloat(directHits) / CGFloat(cols),
                             meanContrast: meanContrast,
                             touchesLeft: touchesLeft,
                             touchesRight: touchesRight)
    }

    // MARK: - Strip extraction

    private static func extractStrip(from image: CGImage,
                                     windowRect: CGRect,
                                     topInset: CGFloat,
                                     bottomInset: CGFloat,
                                     scale: CGFloat) -> HeaderStrip? {
        guard scale > 0,
              windowRect.width >= 80,
              windowRect.height >= 120
        else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let insetX = min(max(12, windowRect.width * 0.04), windowRect.width * 0.15)
        let minX = windowRect.minX + insetX
        let maxX = windowRect.maxX - insetX
        let clampedBottom = min(windowRect.height - 32, bottomInset)
        let clampedTop = max(0, topInset)
        guard maxX - minX >= 40, clampedBottom - clampedTop >= 6 else { return nil }

        let requestedPx = CGRect(x: minX * scale,
                                 y: (windowRect.minY + clampedTop) * scale,
                                 width: (maxX - minX) * scale,
                                 height: (clampedBottom - clampedTop) * scale).integral
        let visiblePx = requestedPx.intersection(imageBounds)
        guard visiblePx.width >= 40, visiblePx.height >= 8,
              let cropped = image.cropping(to: visiblePx)
        else { return nil }

        let cols = min(Int(visiblePx.width), 256)
        let rows = Int(visiblePx.height)
        let bytesPerRow = cols * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let rendered = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: cols,
                                      height: rows,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cols, height: rows))
            return true
        }
        guard rendered else { return nil }

        return HeaderStrip(pixels: pixels,
                           cols: cols,
                           rows: rows,
                           bytesPerRow: bytesPerRow,
                           stripTopPx: visiblePx.minY,
                           windowTopPx: windowRect.minY * scale,
                           scale: scale)
    }

    private static func extractStrip(from buffer: CVPixelBuffer,
                                     windowRect: CGRect,
                                     topInset: CGFloat,
                                     bottomInset: CGFloat,
                                     scale: CGFloat) -> HeaderStrip? {
        guard scale > 0,
              windowRect.width >= 80,
              windowRect.height >= 120,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bufWidth = CVPixelBufferGetWidth(buffer)
        let bufHeight = CVPixelBufferGetHeight(buffer)
        let srcStride = CVPixelBufferGetBytesPerRow(buffer)
        let srcPtr = base.assumingMemoryBound(to: UInt8.self)

        let imageBounds = CGRect(x: 0, y: 0, width: bufWidth, height: bufHeight)
        let insetX = min(max(12, windowRect.width * 0.04), windowRect.width * 0.15)
        let minX = windowRect.minX + insetX
        let maxX = windowRect.maxX - insetX
        let clampedBottom = min(windowRect.height - 32, bottomInset)
        let clampedTop = max(0, topInset)
        guard maxX - minX >= 40, clampedBottom - clampedTop >= 6 else { return nil }

        let requestedPx = CGRect(x: minX * scale,
                                 y: (windowRect.minY + clampedTop) * scale,
                                 width: (maxX - minX) * scale,
                                 height: (clampedBottom - clampedTop) * scale).integral
        let visiblePx = requestedPx.intersection(imageBounds)
        guard visiblePx.width >= 40, visiblePx.height >= 8 else { return nil }

        let cols = min(Int(visiblePx.width), 256)
        let rows = Int(visiblePx.height)
        let bytesPerRow = cols * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)
        let startX = Int(visiblePx.minX)
        let spanX = Int(visiblePx.width)
        let startY = Int(visiblePx.minY)

        for r in 0..<rows {
            let sy = startY + r
            let dstRow = r * bytesPerRow
            let srcRow = sy * srcStride
            for c in 0..<cols {
                let sx = startX + (c * spanX) / cols
                let srcOffset = srcRow + sx * 4
                let dstOffset = dstRow + c * 4
                pixels[dstOffset] = srcPtr[srcOffset]
                pixels[dstOffset + 1] = srcPtr[srcOffset + 1]
                pixels[dstOffset + 2] = srcPtr[srcOffset + 2]
                pixels[dstOffset + 3] = 255
            }
        }

        return HeaderStrip(pixels: pixels,
                           cols: cols,
                           rows: rows,
                           bytesPerRow: bytesPerRow,
                           stripTopPx: visiblePx.minY,
                           windowTopPx: windowRect.minY * scale,
                           scale: scale)
    }
}
