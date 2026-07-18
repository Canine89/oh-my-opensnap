# CLAUDE.md — oh-my-opensnap

이 파일은 두 가지 역할을 한다.
1. **이 저장소(oh-my-opensnap)를 작업할 때의 운영 매뉴얼.**
2. **다른 macOS 앱을 새로 만들 때 그대로 가져갈 검증된 청사진(blueprint).** 아래의 스택 선택과 릴리스 절차는 실제로 v1.0.65까지 운영하며 다듬은 것이다. 새 앱에서 흔들리지 말고 이 기본형에서 출발하라.

> 새 macOS 앱을 **처음부터 스캐폴딩**할 때는 로컬 스킬 `macos-app-blueprint`(`.claude/skills/macos-app-blueprint/`)를, **배포/자동 업데이트 파이프라인**을 붙일 때는 전역 스킬 `mac-app-release`를 함께 쓴다. 이 문서는 "무엇을/왜" 골랐는지의 기준선이다.
>
> 이 저장소의 실제 배포는 **Developer ID Application + Apple 공증**이다. 전역 `mac-app-release` 스킬 템플릿의 “자체서명(공증 없음)” 경로는 멤버십이 없을 때의 대안이며, TCC 권한이 필요한 앱에서는 **고정된 코드 서명 신원**이 핵심이다(ad-hoc 금지).

---

## 1. 앱 한 줄 요약

macOS 26(Tahoe)+ **메뉴 막대 상주 화면 캡처 도구**. 영역을 픽셀 단위로 캡처 → 즉시 클립보드 복사 → 라이브러리에 모아 보기/주석/크롭. **Developer ID 서명 + Apple 공증** DMG로 배포 + Sparkle 자동 업데이트.

- Bundle ID: `com.goldenrabbit.ohmyopensnap`
- Repo: `Canine89/oh-my-opensnap`
- Team ID: `M7NU9F8CZN`

---

## 2. 검증된 기술 스택 (그리고 왜)

| 영역 | 선택 | 이유 (전이되는 판단 기준) |
|---|---|---|
| 언어 | **Swift 5 언어 모드** (`SWIFT_VERSION 5.0`, `SWIFT_STRICT_CONCURRENCY: minimal`) | AppKit + 콜백/델리게이트 코드의 안정성 우선. Swift 6 동시성 엄격 모드는 AppKit 상호운용에서 마찰이 크다. |
| UI 프레임워크 | **AppKit** (SwiftUI 아님) | 메뉴바·오버레이 윈도우·픽셀 단위 캡처 HUD처럼 윈도우 레벨/이벤트를 직접 제어해야 하는 유틸리티는 AppKit이 정직하다. |
| 부트스트랩 | **스토리보드 없이 코드로** — `Sources/App/main.swift`에서 `NSApplication` + `AppDelegate` 직접 구성 | 메뉴바 앱은 메인 윈도우가 없다. 코드 부트스트랩이 흐름이 명확하고 진단이 쉽다. |
| 앱 종류 | **`.accessory` 활성화 정책 + `LSUIElement: true`** | Dock 아이콘 없이 메뉴 막대에만 상주. 마지막 윈도우가 닫혀도 종료 안 함. |
| 프로젝트 생성 | **XcodeGen (`project.yml`)** | `project.yml`이 **유일한 진실의 원천(source of truth)**. `.xcodeproj`와 `Config/Info.plist`는 생성물이라 `.gitignore` 처리됨. |
| 의존성 | **SPM** (XcodeGen `packages:`) | 외부 의존성은 **Sparkle 2.5.0 단 하나.** 의존성은 최소로. |
| 캡처 엔진 | **ScreenCaptureKit + CoreGraphics** (`Sources/CaptureCore/`) | 정지 이미지/디스플레이 스트림/영역 영상 모두 Apple 1st-party API. |
| 전역 단축키 | **Carbon `RegisterEventHotKey`** (`Sources/Hotkey/`) | 접근성 권한 불필요 + 샌드박스 호환. `CGEventTap`은 접근성 권한을 요구하니 피한다. |
| 권한 | **TCC 화면 녹화** — `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` + 시스템 설정 딥링크 | 권한은 entitlement가 아니라 사용자 동의로만. 코드로는 프리플라이트 확인·시스템 프롬프트 유도·설정 딥링크까지만 가능. **숨은 앱 설정을 강요하지 말고 표준 시스템 권한 UX를 쓴다.** |
| 자동 업데이트 | **Sparkle** (`SPUStandardUpdaterController(startingUpdater: true)`) + **EdDSA 서명** | ZIP 무결성은 EdDSA로 보장. Gatekeeper는 공증된 앱으로 통과. |
| 코드 서명 | **Developer ID Application** (Team ID 고정) + **hardened runtime** | 아래 §5 참고 — 업데이트해도 TCC 권한이 유지되는 핵심. ad-hoc 금지. |
| 공증 | **`notarytool` + `stapler`** (DMG와 `.app` 모두) | Gatekeeper “확인되지 않은 개발자” 없이 설치. |
| 배포 | **DMG(사람, 공증) + ZIP(Sparkle)** → GitHub Releases + `appcast.xml`(raw.githubusercontent) | §4 릴리스 절차 참고. Homebrew Cask도 동일 DMG를 가리킨다. |

---

## 3. 소스 구조 / 아키텍처 패턴

```
Sources/
  App/         main.swift · AppDelegate · MenuBarController · CaptureCoordinator · UpdaterController · Brand
  CaptureCore/ ScreenCaptureKit/CG 기반 캡처 엔진 (StillImage·DisplayStream·VideoRecording·AreaVideo·WindowHitTester)
  Overlay/     영역 선택 디밍 + 크로스헤어 오버레이 윈도우
  Output/      캡처 직후 HUD (선택/녹화/썸네일/버튼)
  Library/     캡처 보관함 + 이미지/영상 편집기 (크롭·번호·화살표·도형)
  Hotkey/      Carbon 전역 단축키 등록 + 포맷터
  Permissions/ 화면 녹화 권한 확인/프롬프트/딥링크
  Settings/    설정 저장 + 환경설정 창
  Geometry/    멀티 디스플레이/Retina 좌표 계산
```

**패턴 규칙 (새 앱에도 적용):**
- 싱글톤은 `.shared`, UI 상태는 `@MainActor`로 격리. (`HotkeyManager.shared`, `CaptureCoordinator.shared`, `UpdaterController.shared`)
- 윈도우는 `NSWindowController` 기반. 스토리보드/XIB 없음.
- 앱 이름·식별 문자열은 **`Brand.swift` 한 곳**에 모은다 → 새 앱은 여기만 바꾸면 UI 문자열이 따라온다.
- `AppDelegate`는 얇게: 메인 메뉴 구성(편집 메뉴로 `⌘Z`/`⌘C` 라우팅) + 전역 단축키 연결 + 메뉴바 컨트롤러 기동.

---

## 4. 빌드 · 실행 · 릴리스

### 빌드/실행 (로컬)
```bash
brew install xcodegen                 # 최초 1회
xcodegen generate                     # project.yml → .xcodeproj 재생성
open oh-my-opensnap.xcodeproj         # Xcode에서 Run, 또는
./scripts/release.sh                  # 버전 인자 없이 → 로컬 테스트용 DMG만 빌드
./scripts/release.sh --skip-notary    # 공증 없이 Developer ID 서명만 (빠른 로컬)
```
아이콘 재생성: `scripts/icongen.swift`.

### 릴리스 (`scripts/release.sh`)
```bash
./scripts/release.sh 1.0.65            # 버전 올려 DMG+ZIP+appcast 생성 (게시는 안 함)
./scripts/release.sh 1.0.65 --publish  # 위 + 커밋/푸시 + GitHub Release 업로드
```

**`--publish`가 한 번에 처리하는 것들 (= "릴리스할 때 처리한 목록"):**
1. **버전 올림** — `project.yml`의 `MARKETING_VERSION`(=표시 버전)과 `CURRENT_PROJECT_VERSION`(=빌드 번호, +1). 요청 버전이 현재와 다를 때만 올려 재실행 시 중복 증가 방지.
   - ⚠️ **빌드 번호(`CURRENT_PROJECT_VERSION`)는 매 릴리스 증가해야 Sparkle이 업데이트를 감지한다.**
2. **재생성 + Release 빌드** — `xcodegen generate` → `xcodebuild ... -configuration Release clean build`(`build/dd`로).
3. **Developer ID 서명(inside-out)** — Sparkle XPC/Updater/framework → 앱 본체. `codesign --options runtime --timestamp`. (`--deep`에 의존하지 않음.)
4. **공증 + 스테이플** — DMG를 `notarytool submit --wait` → DMG와 `.app`에 `stapler staple`. (`OMOS_NOTARY_PROFILE`, 기본 `oh-my-opensnap`)
5. **패키징** — `dist/`에:
   - DMG: 스테이징 + `/Applications` 심볼릭 링크 → `hdiutil ... UDZO` (사람이 드래그-투-Applications)
   - ZIP: `ditto -c -k --keepParent` (Sparkle 업데이트용, 공증·스테이플된 앱)
6. **EdDSA 서명 + appcast** — DerivedData에서 Sparkle `sign_update`를 찾아 ZIP 서명 → `appcast.xml` 생성. ZIP은 `updates/`에 버전별로 복사하고 `raw.githubusercontent.com/.../updates/...zip`로 서빙.
7. **릴리스 노트** — `CHANGELOG.md`의 `## <버전>` 섹션을 읽어 Sparkle 업데이트 창(HTML)과 GitHub 릴리스 노트(markdown) 양쪽에 사용. → **릴리스 전에 `CHANGELOG.md`에 `## <새버전>` 섹션을 먼저 추가하라.**
8. **게시(`--publish`)** — `appcast.xml` + `project.yml` + `updates/*.zip`(+ Cask)을 `release: vX.Y.Z` 커밋으로 푸시 → 공개 ZIP 다운로드 크기 일치 검증 → `gh release create/upload`로 DMG+ZIP 업로드.

### 1회 전역 설정 (이 Mac에서 한 번, 분실 시 치명적)
- **Developer ID Application 인증서** + Apple Developer Program 멤버십.
- **notarytool 키체인 프로필**: `xcrun notarytool store-credentials "oh-my-opensnap" --apple-id … --team-id M7NU9F8CZN --password <앱별암호>`
- **Sparkle EdDSA 키쌍**: `generate_keys`로 생성, `generate_keys -x`로 백업. 공개키는 `Info.plist`의 `SUPublicEDKey`.
- 🔐 **EdDSA 개인키·앱별 암호는 절대 git에 커밋 금지**. 분실하면 기존 사용자에게 업데이트를 못 보낸다.

---

## 5. 왜 ad-hoc이 아니라 안정적 서명 신원인가 (가장 중요한 교훈)

ad-hoc 서명은 **빌드마다 cdhash가 바뀌어** macOS가 매 업데이트를 "다른 앱"으로 본다 → **화면 녹화 권한이 업데이트마다 풀린다.**

**Developer ID Application**(고정 Team ID)으로 서명하면 Designated Requirement가 팀/인증서에 묶여, 같은 팀으로 서명한 모든 업데이트에서 TCC 권한이 유지된다. (과거에 쓰던 고정 자체서명도 같은 원리였고, 현재 이 앱은 공증까지 가는 Developer ID로 통일했다.)

→ 새 앱에서도 동일: **TCC 권한(화면/마이크/카메라 등)이 필요한 앱은 반드시 안정적 서명 신원을 써라. ad-hoc 금지.**

배포 모델: 공증된 DMG → 일반 사용자는 Gatekeeper 우회 없이 설치. Sparkle 업데이트도 동일 신원으로 권한이 유지된다.

---

## 6. 하지 말 것 (함정 모음)

- ❌ **`.xcodeproj` / `Config/Info.plist` 직접 편집** — 생성물이다. `project.yml`을 고치고 `xcodegen generate`.
- ❌ **`GENERATE_INFOPLIST_FILE` 사용** — Sparkle 커스텀 키(`SUFeedURL` 등) 때문에 명시적 `Info.plist`(XcodeGen `info:`)를 쓴다.
- ❌ **ad-hoc 서명** — §5.
- ❌ **빌드 번호 그대로 두고 릴리스** — Sparkle이 업데이트를 못 본다.
- ❌ **시크릿(EdDSA 개인키, 앱별 암호) 커밋.**
- ❌ **숨은 앱 내부 설정으로 권한을 강요** — 표준 시스템 권한 프롬프트 + 설정 딥링크를 쓴다. 자동화 진행 중에는 사용자 입력을 막지 않는다.
- ❌ **DMG만 공증하고 DMG 서명을 생략** — DMG도 Developer ID로 서명한다.
- ❌ **`codesign --deep`에만 의존** — Sparkle 중첩 XPC는 inside-out으로 서명한다.
