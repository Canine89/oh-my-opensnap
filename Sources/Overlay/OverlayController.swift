import AppKit
import ScreenCaptureKit

/// 캡처 세션의 수명주기를 관리한다:
/// 디스플레이별 오버레이 윈도우 + 루페 스트림 시작 → 선택 확정 시 캡처/출력 → 정리.
@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private init() {}

    private var windows: [OverlayWindow] = []
    private var providers: [CGDirectDisplayID: DisplayStreamProvider] = [:]
    private var hitTester: WindowHitTester?
    private var refreshTimer: Timer?
    private var active = false
    private var cursorHidden = false

    // 안전장치: first-responder 라우팅이 실패해도 Esc로 항상 빠져나올 수 있게 하고,
    // 무언가 막혀 오버레이가 떠 있는 채로 굳어도 워치독이 자동으로 해제한다.
    private var escMonitors: [Any] = []
    private var watchdog: Timer?
    private let watchdogTimeout: TimeInterval = 30

    func begin() {
        guard !active else { return }
        active = true
        // 캡처 모드에선 라이브러리 창이 화면(스틸 캡처)에 찍히지 않도록 자동으로 가린다.
        LibraryWindowController.shared.hideForCapture()
        NSApp.activate(ignoringOtherApps: true)
        Task { await setup() }
    }

    private func setup() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            NSLog("SCShareableContent failed: \(error)")
            active = false
            LibraryWindowController.shared.restoreAfterCapture()
            return
        }

        let tester = WindowHitTester(content: content)
        hitTester = tester

        for screen in NSScreen.screens {
            let displayID = screen.displayID
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let scale = screen.backingScaleFactor

            let window = OverlayWindow(screen: screen)
            let view = window.captureView
            view.scale = scale
            view.displayID = displayID
            view.cgOrigin = CGDisplayBounds(displayID).origin   // CG 전역 좌상단 원점(point)
            view.hitTester = tester
            view.onFinish = { [weak self] rect in
                self?.finish(viewRect: rect, scale: scale, display: scDisplay)
            }
            view.onWindowCapture = { [weak self] scWindow in
                self?.finishWindow(scWindow)
            }
            view.onCancel = { [weak self] in self?.cancel() }

            let provider = DisplayStreamProvider(displayID: displayID, scale: scale)
            view.provider = provider
            providers[displayID] = provider
            windows.append(window)

            await provider.start(display: scDisplay)
        }

        guard !windows.isEmpty else {
            teardown()
            LibraryWindowController.shared.restoreAfterCapture()
            return
        }

        for window in windows { window.orderFrontRegardless() }
        if let keyWindow = windows.first {
            keyWindow.makeKey()
            keyWindow.makeFirstResponder(keyWindow.captureView)   // Esc 등 키 입력을 받기 위해
        }
        NSCursor.hide()
        cursorHidden = true

        installEscapeHatch()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windows.forEach { $0.captureView.refreshLoupe() }
            }
        }
    }

    /// 어떤 상황에서도 오버레이를 닫을 수 있도록 보장하는 안전장치.
    /// - 전역/로컬 Esc 모니터: first-responder 라우팅이 깨져도 Esc가 항상 취소시킨다.
    /// - 워치독: 선택 없이 일정 시간이 지나면 자동으로 해제해 락아웃을 방지한다.
    private func installEscapeHatch() {
        // 로컬 모니터만 사용한다. 전역(global) keyDown 모니터는 입력 모니터링 권한을
        // 요구해 새 권한 prompt를 유발할 수 있어 피한다. 오버레이 중 앱은 활성/key라 충분하다.
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }   // Esc
            return event
        }
        escMonitors = [local].compactMap { $0 }

        watchdog = Timer.scheduledTimer(withTimeInterval: watchdogTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                NSLog("Overlay watchdog fired — auto-dismissing to avoid lockout")
                self?.cancel()
            }
        }
    }

    private func finish(viewRect: CGRect, scale: CGFloat, display: SCDisplay) {
        // 너무 작은 선택은 취소로 간주
        guard viewRect.width > 2, viewRect.height > 2 else { cancel(); return }
        teardown()

        Task {
            do {
                let full = try await StillImageCapturer.capture(display: display, scale: scale)
                await MainActor.run {
                    // 스틸 픽셀을 다 읽은 뒤에만 라이브러리 창을 되돌린다(자르기 실패 경로 포함).
                    defer { LibraryWindowController.shared.restoreAfterCapture() }
                    let pxRect = CGRect(x: viewRect.minX * scale,
                                        y: viewRect.minY * scale,
                                        width: viewRect.width * scale,
                                        height: viewRect.height * scale).integral
                    let imageBounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
                    let clamped = pxRect.intersection(imageBounds)
                    guard !clamped.isEmpty, let crop = full.cropping(to: clamped) else { return }
                    CaptureOutput.deliver(cgImage: crop, scale: scale)
                }
            } catch {
                NSLog("Still capture failed: \(error)")
                await MainActor.run { LibraryWindowController.shared.restoreAfterCapture() }
            }
        }
    }

    private func finishWindow(_ window: SCWindow) {
        teardown()
        Task {
            do {
                let result = try await StillImageCapturer.captureWindow(window)
                await MainActor.run {
                    CaptureOutput.deliver(cgImage: result.image, scale: result.scale)
                    LibraryWindowController.shared.restoreAfterCapture()
                }
            } catch {
                NSLog("Window capture failed: \(error)")
                await MainActor.run { LibraryWindowController.shared.restoreAfterCapture() }
            }
        }
    }

    private func cancel() {
        teardown()
        LibraryWindowController.shared.restoreAfterCapture()
    }

    private func teardown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        for monitor in escMonitors { NSEvent.removeMonitor(monitor) }
        escMonitors.removeAll()
        for provider in providers.values { provider.stop() }
        providers.removeAll()
        hitTester = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if cursorHidden {            // 숨긴 적 있을 때만 복구(unhide 카운터 불균형 방지)
            NSCursor.unhide()
            cursorHidden = false
        }
        active = false
    }
}
