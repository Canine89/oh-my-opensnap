import AppKit
import ScreenCaptureKit

/// 캡처 세션의 수명주기를 관리한다:
/// 디스플레이별 오버레이 윈도우 + 루페 스트림 시작 → 선택 확정 시 캡처/출력 → 정리.
@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private init() {}

    enum Mode {
        case stillImage
        case video
        case askAfterSelection
    }

    private var windows: [OverlayWindow] = []
    private var choiceHUD: CaptureChoiceHUD?
    private var providers: [CGDirectDisplayID: DisplayStreamProvider] = [:]
    // 우리 오버레이 윈도우들의 SCWindow 매핑. 루페/스틸 캡처에서 이것만 제외해
    // 자기참조(자기 자신이 캡처에 찍힘)를 막는다. OBS 등 외부 녹화엔 그대로 보인다.
    private var overlayWindows: [SCWindow] = []
    private var hitTester: WindowHitTester?
    private var refreshTimer: Timer?
    private var active = false
    private var cursorHidden = false

    // 안전장치: first-responder 라우팅이 실패해도 Esc로 항상 빠져나올 수 있게 하고,
    // 무언가 막혀 오버레이가 떠 있는 채로 굳어도 워치독이 자동으로 해제한다.
    private var escMonitors: [Any] = []
    private var watchdog: Timer?
    private let watchdogTimeout: TimeInterval = 30

    func begin(mode: Mode = .stillImage) {
        guard !active, choiceHUD == nil else { return }
        active = true
        // 캡처 모드에선 라이브러리 창이 화면(스틸 캡처)에 찍히지 않도록 자동으로 가린다.
        LibraryWindowController.shared.hideForCapture()
        NSApp.activate(ignoringOtherApps: true)
        Task { await setup(mode: mode) }
    }

    private func setup(mode: Mode) async {
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

        // (provider, scDisplay) 쌍. 오버레이를 화면에 올린 뒤에야 SCWindow 매핑이 가능하므로
        // 루페 스트림 시작은 윈도우 생성 루프가 끝난 뒤로 미룬다.
        var pending: [(provider: DisplayStreamProvider, display: SCDisplay)] = []

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
            view.confirmEnabled = mode != .askAfterSelection
            view.onFinish = { [weak self, weak window] rect in
                switch mode {
                case .stillImage:
                    self?.finishStillImage(viewRect: rect, scale: scale, display: scDisplay)
                case .video:
                    self?.finishVideo(viewRect: rect, scale: scale, display: scDisplay, displayID: displayID)
                case .askAfterSelection:
                    guard let window else { self?.cancel(); return }
                    self?.finishAreaWithChoice(viewRect: rect,
                                               scale: scale,
                                               display: scDisplay,
                                               displayID: displayID,
                                               overlayWindow: window)
                }
            }
            view.onWindowCapture = { [weak self] scWindow, windowRect in
                switch mode {
                case .stillImage:
                    self?.finishWindow(scWindow)
                case .video:
                    self?.finishVideo(viewRect: windowRect, scale: scale, display: scDisplay, displayID: displayID)
                case .askAfterSelection:
                    self?.finishWindowWithChoice(scWindow,
                                                 windowRect: windowRect,
                                                 scale: scale,
                                                 display: scDisplay,
                                                 displayID: displayID,
                                                 overlayWindow: window)
                }
            }
            view.onCancel = { [weak self] in self?.cancel() }
            view.onAdjustingStarted = { [weak self, weak window, weak view] in
                guard let self else { return }
                // 선택이 조정(확정 대기) 단계로 들어가면:
                // 핸들을 잡을 수 있게 커서를 되살리고, 조정하는 동안 워치독이
                // 오버레이를 닫아 버리지 않도록 해제한다(Esc 모니터는 그대로 살아 있다).
                self.watchdog?.invalidate()
                self.watchdog = nil
                if self.cursorHidden {
                    NSCursor.unhide()
                    self.cursorHidden = false
                }
                if let window {
                    window.makeKeyAndOrderFront(nil)   // ⏎ 확정 키를 받도록 선택이 일어난 창을 key로
                    window.makeFirstResponder(window.captureView)
                }
                if mode == .askAfterSelection, let view, let window {
                    self.presentAdjustingChoice(for: view,
                                                in: window,
                                                scale: scale,
                                                display: scDisplay,
                                                displayID: displayID)
                }
            }
            view.onSelectionActivity = { [weak self, weak view] in
                // 새 선택이 시작되면 다른 디스플레이의 선택과 떠 있던 선택 HUD를 정리한다.
                guard let self else { return }
                self.choiceHUD?.dismiss()
                self.choiceHUD = nil
                for other in self.windows where other.captureView !== view {
                    other.captureView.deactivateSelection()
                }
            }
            view.onSelectionChanged = { [weak self, weak window] rect in
                // 선택 HUD가 떠 있는 경우(윈도우 선택 등) 위치를 새 선택 근처로 따라 옮긴다.
                guard let self, let window, let hud = self.choiceHUD else { return }
                hud.move(near: self.screenRect(for: rect, in: window))
            }

            let provider = DisplayStreamProvider(displayID: displayID, scale: scale)
            view.provider = provider
            providers[displayID] = provider
            windows.append(window)
            pending.append((provider, scDisplay))
        }

        guard !windows.isEmpty else {
            teardown()
            LibraryWindowController.shared.restoreAfterCapture()
            return
        }

        for window in windows { window.orderFrontRegardless() }

        // 오버레이가 화면에 올라온 뒤 SCWindow로 매핑하고, 그 제외 목록으로 루페 스트림을 시작한다.
        overlayWindows = await Self.resolveOverlayWindows(windows)
        for item in pending {
            await item.provider.start(display: item.display, excluding: overlayWindows)
        }

        if let keyWindow = windows.first {
            // 전역 단축키로 떴을 때 앱이 활성/key가 못 돼 ESC가 안 먹는 경우가 있어,
            // 윈도우가 화면에 올라온 직후 다시 활성화하고 key로 만든다.
            NSApp.activate(ignoringOtherApps: true)
            keyWindow.makeKeyAndOrderFront(nil)
            keyWindow.makeFirstResponder(keyWindow.captureView)   // Esc 등 키 입력을 받기 위해
        }
        // 이벤트가 오기 전이라도 현재 커서 위치로 크로스헤어를 맞춰 둔다(좌상단 0,0 깜빡임 방지).
        for window in windows { window.captureView.primeCursor() }
        NSCursor.hide()
        cursorHidden = true

        installEscapeHatch()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windows.forEach { $0.captureView.tick() }
            }
        }
    }

    /// 화면에 올라온 오버레이 NSWindow들을 SCWindow로 매핑한다.
    /// (NSWindow.windowNumber ↔ SCWindow.windowID). 캡처 제외 목록으로 쓴다.
    private static func resolveOverlayWindows(_ windows: [OverlayWindow]) async -> [SCWindow] {
        let ids = Set(windows.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
        guard !ids.isEmpty, let content = try? await SCShareableContent.current else { return [] }
        return content.windows.filter { ids.contains($0.windowID) }
    }

    /// 어떤 상황에서도 오버레이를 닫을 수 있도록 보장하는 안전장치.
    /// - 전역/로컬 Esc 모니터: first-responder 라우팅이 깨져도 Esc가 항상 취소시킨다.
    /// - 워치독: 선택 없이 일정 시간이 지나면 자동으로 해제해 락아웃을 방지한다.
    private func installEscapeHatch() {
        // 로컬 모니터만 사용한다. 전역(global) keyDown 모니터는 입력 모니터링 권한을
        // 요구해 새 권한 prompt를 유발할 수 있어 피한다. 오버레이 중 앱은 활성/key라 충분하다.
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }   // Esc
            if event.keyCode == 36 || event.keyCode == 76,          // Return / 키패드 Enter
               self?.windows.contains(where: { $0.captureView.confirmIfAdjusting() }) == true {
                // first-responder 라우팅과 무관하게 ⏎ 확정이 항상 동작하게 한다
                // (멀티 디스플레이에서 key 윈도우가 다른 디스플레이일 수 있다).
                return nil
            }
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

    private func finishStillImage(viewRect: CGRect, scale: CGFloat, display: SCDisplay) {
        // 너무 작은 선택은 취소로 간주
        guard viewRect.width > 2, viewRect.height > 2 else { cancel(); return }
        let excluded = overlayWindows        // teardown 전에 제외 목록을 확보
        teardown()

        Task {
            do {
                let full = try await StillImageCapturer.capture(display: display, scale: scale, excluding: excluded)
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

    private func finishVideo(viewRect: CGRect, scale: CGFloat, display: SCDisplay, displayID: CGDirectDisplayID) {
        guard viewRect.width > 2, viewRect.height > 2 else { cancel(); return }
        let excluded = overlayWindows
        teardown()

        Task {
            do {
                try await VideoRecordingController.shared.start(display: display,
                                                               displayID: displayID,
                                                               rect: viewRect,
                                                               scale: scale,
                                                               excluding: excluded)
            } catch {
                NSLog("Video recording start failed: \(error)")
                await MainActor.run { LibraryWindowController.shared.restoreAfterCapture() }
            }
        }
    }

    private func finishAreaWithChoice(viewRect: CGRect,
                                      scale: CGFloat,
                                      display: SCDisplay,
                                      displayID: CGDirectDisplayID,
                                      overlayWindow: OverlayWindow) {
        let excluded = overlayWindows
        let anchor = screenRect(for: viewRect, in: overlayWindow)
        teardown()
        presentChoice(anchor: anchor,
                      imageAction: { [weak self] in
                          self?.captureStillImage(viewRect: viewRect,
                                                  scale: scale,
                                                  display: display,
                                                  excluding: excluded)
                      },
                      videoAction: { [weak self] in
                          self?.startVideo(viewRect: viewRect,
                                           scale: scale,
                                           display: display,
                                           displayID: displayID,
                                           excluding: excluded)
                      })
    }

    private func presentAdjustingChoice(for view: OverlayView,
                                        in window: OverlayWindow,
                                        scale: CGFloat,
                                        display: SCDisplay,
                                        displayID: CGDirectDisplayID) {
        guard let rect = view.currentSelection else { return }
        let anchor = screenRect(for: rect, in: window)
        if let hud = choiceHUD {
            hud.move(near: anchor)
            return
        }
        let hud = CaptureChoiceHUD(anchor: anchor,
                                   onImage: { [weak self, weak view] in
                                       guard let self else { return }
                                       self.choiceHUD = nil
                                       if let windowSelection = view?.currentWindowSelection {
                                           self.teardown()
                                           self.captureWindow(windowSelection.window)
                                           return
                                       }
                                       guard let rect = view?.currentSelection else { self.cancel(); return }
                                       let excluded = self.overlayWindows
                                       self.teardown()
                                       self.captureStillImage(viewRect: rect,
                                                              scale: scale,
                                                              display: display,
                                                              excluding: excluded)
                                   },
                                   onVideo: { [weak self, weak view] in
                                       guard let self else { return }
                                       self.choiceHUD = nil
                                       guard let rect = view?.currentSelection else { self.cancel(); return }
                                       let excluded = self.overlayWindows
                                       self.teardown()
                                       self.startVideo(viewRect: rect,
                                                       scale: scale,
                                                       display: display,
                                                       displayID: displayID,
                                                       excluding: excluded)
                                   },
                                   onCancel: { [weak self] in
                                       self?.choiceHUD = nil
                                       self?.cancel()
                                   })
        choiceHUD = hud
        hud.show()
    }

    private func finishWindowWithChoice(_ window: SCWindow,
                                        windowRect: CGRect,
                                        scale: CGFloat,
                                        display: SCDisplay,
                                        displayID: CGDirectDisplayID,
                                        overlayWindow: OverlayWindow) {
        let excluded = overlayWindows
        let anchor = screenRect(for: windowRect, in: overlayWindow)
        teardown()
        presentChoice(anchor: anchor,
                      imageAction: { [weak self] in
                          self?.captureWindow(window)
                      },
                      videoAction: { [weak self] in
                          self?.startVideo(viewRect: windowRect,
                                           scale: scale,
                                           display: display,
                                           displayID: displayID,
                                           excluding: excluded)
                      })
    }

    private func presentChoice(anchor: CGRect, imageAction: @escaping () -> Void, videoAction: @escaping () -> Void) {
        let hud = CaptureChoiceHUD(anchor: anchor,
                                   onImage: { [weak self] in
                                       self?.choiceHUD = nil
                                       imageAction()
                                   },
                                   onVideo: { [weak self] in
                                       self?.choiceHUD = nil
                                       videoAction()
                                   },
                                   onCancel: { [weak self] in
                                       self?.choiceHUD = nil
                                       LibraryWindowController.shared.restoreAfterCapture()
                                   })
        choiceHUD = hud
        hud.show()
    }

    private func captureStillImage(viewRect: CGRect, scale: CGFloat, display: SCDisplay, excluding excluded: [SCWindow]) {
        Task {
            do {
                let full = try await StillImageCapturer.capture(display: display, scale: scale, excluding: excluded)
                await MainActor.run {
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

    private func startVideo(viewRect: CGRect,
                            scale: CGFloat,
                            display: SCDisplay,
                            displayID: CGDirectDisplayID,
                            excluding excluded: [SCWindow]) {
        Task {
            do {
                try await VideoRecordingController.shared.start(display: display,
                                                               displayID: displayID,
                                                               rect: viewRect,
                                                               scale: scale,
                                                               excluding: excluded)
            } catch {
                NSLog("Video recording start failed: \(error)")
                await MainActor.run { LibraryWindowController.shared.restoreAfterCapture() }
            }
        }
    }

    private func captureWindow(_ window: SCWindow) {
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

    private func screenRect(for viewRect: CGRect, in window: OverlayWindow) -> CGRect {
        CGRect(x: window.frame.minX + viewRect.minX,
               y: window.frame.maxY - viewRect.maxY,
               width: viewRect.width,
               height: viewRect.height)
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
        choiceHUD?.dismiss()
        choiceHUD = nil
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
        overlayWindows.removeAll()
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
