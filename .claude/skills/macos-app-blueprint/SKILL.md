---
name: macos-app-blueprint
description: >
  새 macOS 유틸리티/메뉴바 앱을 oh-my-opensnap에서 검증된 스택으로 흔들림 없이 스캐폴딩하고
  개발하는 청사진. Swift 5 언어모드 + AppKit(코드 부트스트랩) + XcodeGen(project.yml) +
  SPM + Sparkle 자동 업데이트 + 안정적 코드서명(TCC 권한 유지; 이 저장소는 Developer ID+공증).
  사용 시점: "새 macOS 앱 시작/스캐폴딩", "메뉴바 앱 만들어줘", "macOS 데스크톱 앱 프로젝트 구성",
  "Swift 맥 앱 처음부터", "이 프로젝트처럼 새 앱" 같은 요청. 배포/릴리스/자동 업데이트 파이프라인
  자체는 전역 스킬 mac-app-release로 위임한다(멤버십 있으면 Developer ID+공증 권장).
---

# macOS 앱 청사진 (oh-my-opensnap 검증 스택)

새 macOS 데스크톱/메뉴바 유틸리티를 **매번 다시 고민하지 말고** 이 기본형에서 출발한다.
이 스킬은 oh-my-opensnap의 실제 구성(v1.0.65까지 운영)을 일반화한 것이다. "무엇을/왜"의 근거는
이 프로젝트 루트 `CLAUDE.md` §2를 함께 보라.

> **역할 분담**
> - **이 스킬** = 새 앱을 *개발*하기 위한 스택 선택 + 프로젝트 골격 + 아키텍처 패턴.
> - **`mac-app-release` (전역 스킬)** = 빌드 *배포* + 자동 업데이트 파이프라인. oh-my-opensnap 본가의 `scripts/release.sh`는 **Developer ID + 공증 + EdDSA appcast** 경로다. 멤버십이 없을 때만 스킬 템플릿의 자체서명 경로를 쓴다.

---

## 1. 확정 스택 (이유 없이 바꾸지 말 것)

- **Swift 5 언어모드** (`SWIFT_VERSION: "5.0"`, `SWIFT_STRICT_CONCURRENCY: minimal`) — AppKit/콜백 안정성.
- **AppKit, 스토리보드 없음** — `main.swift`에서 `NSApplication` + `AppDelegate` 코드 부트스트랩.
- **XcodeGen `project.yml`이 유일한 진실의 원천** — `.xcodeproj`/생성 `Info.plist`는 gitignore.
- **SPM 의존성 최소화** — 필요한 것만(자동 업데이트 쓰면 Sparkle 2.5.0).
- **Apple 1st-party API 우선** — 캡처는 ScreenCaptureKit/CG, 전역 단축키는 Carbon `RegisterEventHotKey`(접근성 권한 불필요).
- **TCC 권한은 표준 시스템 프롬프트 + 설정 딥링크** — 숨은 앱 설정 강요 금지.

메뉴바 상주 앱이면: `.accessory` 활성화 정책 + `Info.plist`의 `LSUIElement: true` + `applicationShouldTerminateAfterLastWindowClosed → false`.

---

## 2. 새 앱 스캐폴딩 절차

1. **디렉터리 골격**
   ```
   <App>/
     project.yml
     Config/Info.plist        # XcodeGen이 info.properties로 생성 (gitignore)
     Sources/                 # 기능별 디렉터리로 분리 (App/ 부터)
     Resources/Assets.xcassets # AppIcon
     scripts/                 # release.sh, make-signing-cert.sh (mac-app-release에서 복사)
     CHANGELOG.md             # "## <버전>" 섹션 — 릴리스 노트 소스
     README.md / INSTALL.md
     .gitignore
   ```

2. **`project.yml`** — 아래 골격에서 이름/번들ID/배포 타깃만 바꾼다.
   ```yaml
   name: <App>
   options:
     bundleIdPrefix: com.<org>
     deploymentTarget: { macOS: "26.0" }
     createIntermediateGroups: true
   packages:
     Sparkle: { url: https://github.com/sparkle-project/Sparkle, from: "2.5.0" }
   settings:
     base:
       SWIFT_VERSION: "5.0"
       MARKETING_VERSION: "1.0.0"
       CURRENT_PROJECT_VERSION: "1"      # 매 릴리스 +1 (release.sh가 자동)
       SWIFT_STRICT_CONCURRENCY: minimal
       DEAD_CODE_STRIPPING: YES
   targets:
     <App>:
       type: application
       platform: macOS
       deploymentTarget: "26.0"
       sources: [ { path: Sources }, { path: Resources } ]
       dependencies: [ { package: Sparkle } ]
       info:
         path: Config/Info.plist
         properties:
           LSUIElement: true                          # 메뉴바 앱이면
           CFBundleShortVersionString: "$(MARKETING_VERSION)"
           CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
           LSMinimumSystemVersion: "$(MACOSX_DEPLOYMENT_TARGET)"
           SUFeedURL: https://raw.githubusercontent.com/<owner>/<repo>/main/appcast.xml
           SUPublicEDKey: <EdDSA 공개키>              # mac-app-release §A에서 생성
           SUEnableAutomaticChecks: true
           SUScheduledCheckInterval: 86400
       settings:
         base:
           PRODUCT_BUNDLE_IDENTIFIER: com.<org>.<app>
           ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
           ENABLE_APP_SANDBOX: NO                     # 화면 캡처 등 필요 시
           MACOSX_DEPLOYMENT_TARGET: "26.0"
           LD_RUNPATH_SEARCH_PATHS: [ "$(inherited)", "@executable_path/../Frameworks" ]
   ```

3. **`Sources/App/main.swift`** — 코드 부트스트랩
   ```swift
   import AppKit
   let app = NSApplication.shared
   let delegate = AppDelegate()
   app.delegate = delegate
   app.setActivationPolicy(.accessory)   // 메뉴바 앱
   app.run()
   ```

4. **`AppDelegate`** — 얇게: 메인 메뉴(편집 메뉴로 `⌘Z`/`⌘C` 라우팅) + 전역 단축키 연결 + 메뉴바 컨트롤러 + `UpdaterController.shared` 기동.

5. **`xcodegen generate` → 빌드 확인.**

6. **자동 업데이트/배포는 `mac-app-release` + 이 저장소 `scripts/release.sh` 참고** — Developer ID·notarytool 프로필·EdDSA 키 1회 준비, `SUPublicEDKey` 채우기. TCC가 필요한 앱은 ad-hoc 금지.

---

## 3. 아키텍처 패턴

- 기능별 디렉터리 분리(`App/`, `Permissions/`, `Hotkey/`, `Settings/`, 그리고 도메인별 모듈).
- 전역 상태/리소스는 `.shared` 싱글톤 + UI는 `@MainActor`.
- 윈도우는 `NSWindowController` 기반(스토리보드/XIB 없음).
- 앱 이름·식별 문자열은 `Brand.swift` 한 곳에 모아 새 앱에서 한 번만 교체.
- 권한 게이트는 전용 enum으로(`isGranted` 프리플라이트 / `request()` 프롬프트 / `openSystemSettings()` 딥링크).

---

## 4. 함정 (반복 금지)

- `.xcodeproj`/`Config/Info.plist` 직접 편집 ❌ → `project.yml` 고치고 `xcodegen generate`.
- `GENERATE_INFOPLIST_FILE` ❌ → Sparkle 커스텀 키 때문에 명시적 `Info.plist`.
- ad-hoc 서명 ❌ → TCC 권한이 업데이트마다 풀린다. Developer ID(권장) 또는 고정 자체서명으로 안정적 신원 유지.
- 빌드 번호(`CURRENT_PROJECT_VERSION`) 고정 ❌ → Sparkle이 업데이트 감지 못 함.
- 시크릿(`.p12`/EdDSA 개인키) 커밋 ❌ (`.gitignore`에 `*.p12`).
- 숨은 앱 설정으로 권한 강요 ❌ → 표준 시스템 권한 UX.
