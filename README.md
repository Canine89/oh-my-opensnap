# oh-my-snap — 편집자의 빨간펜 ✍️

정밀하게 영역을 짚어 캡처하고, **그 자리에서 빨갛게 표시(번호·화살표·도형)하고 잘라내는** macOS 메뉴바 캡처 앱.

> macOS 26 (Tahoe) 이상 · 메뉴바 상주 · 무료 / 오픈소스

---

## 📥 설치 (사용자)

1. [**Releases**](../../releases/latest) 에서 `.dmg` 를 내려받아 `Applications` 로 드래그
2. 처음 한 번만 **시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"** 로 실행 허용
3. 첫 캡처 시 **화면 녹화 권한**을 켜 주기

👉 **그림과 함께 따라 하는 자세한 설치법: [INSTALL.md](INSTALL.md)** (터미널 없이 가능)

> 공증($99 Apple Developer Program)을 하지 않은 무료 앱이라 첫 실행 때 한 번 보안 우회가 필요합니다. 자세한 이유는 INSTALL.md 하단 참고.

---

## ✨ 기능

- 메뉴바 상주 + 전역 단축키 **⌘⇧2** 로 영역 캡처
- 전체 화면 디밍 + **크로스헤어 + 라이브 확대경(루페)** — 픽셀 격자 / 좌표 / HEX
- 드래그로 영역 선택, 실시간 **W×H(px)** 표시 · `Esc` 취소
- 캡처 즉시 **클립보드 자동 복사** (PNG / 레거시 PNGf / TIFF)
- **라이브러리 + 편집기**
  - 캡처본을 바탕화면 `oh-my-snap` 폴더에 보관, 썸네일로 다시 보기
  - 편집 도구: **크롭 · 번호(➊–➒) · 화살표 · 사각형 · 원**, 색/굵기 조절
  - 번호 도구는 커서를 따라다니는 **스탬프 미리보기** 제공
  - 도형 드래그 중 **`⇧`**: 사각형/원 1:1, 화살표 45° 스냅
  - **⌘Z 되돌리기**(크롭 포함) · ⌘C 복사 · 확대/축소
  - 썸네일 **우클릭 → Finder에서 보기**
- 멀티 디스플레이 / Retina 대응

---

## 🛠 직접 빌드 (개발자)

프로젝트 파일은 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 `project.yml` 에서 생성합니다.

```bash
brew install xcodegen      # 최초 1회
xcodegen generate          # project.yml → oh-my-snap.xcodeproj
open oh-my-snap.xcodeproj  # Xcode 에서 ⌘R
```

> Xcode → Signing & Capabilities → **Team** 을 본인 계정으로 지정해야 화면 녹화 권한이 빌드마다 유지됩니다.
> (ad-hoc 서명은 매 빌드 "새 앱"으로 인식되어 권한을 반복 요청합니다.)

### 기술 스택
- Swift 5 language mode, Xcode 26, 최소 타깃 **macOS 26.0**
- ScreenCaptureKit: `SCStream`(루페 라이브 프레임) + `SCScreenshotManager`(최종 풀해상도)
- 전역 단축키: Carbon `RegisterEventHotKey` (접근성 권한 불필요)
- 오버레이 자기참조 차단: `sharingType = .none`

---

## 📦 배포 (메인테이너)

무료 배포는 **ad-hoc 서명 + DMG + GitHub Releases** 방식입니다(공증 없음).

```bash
./scripts/release.sh             # dist/oh-my-snap-<버전>.dmg 생성
./scripts/release.sh --publish   # 위 + GitHub Release 자동 생성/업로드 (gh CLI)
```

스크립트가 하는 일: `xcodegen generate` → Release 빌드 → **ad-hoc 재서명**(개인 인증서 제거) → 드래그-투-Applications DMG 패키징.

> 경고 없는 매끄러운 설치를 원하면 [Apple Developer Program]($99/년) 가입 후 Developer ID 서명 + 공증(notarization)으로 전환하면 됩니다. 현재 구조(샌드박스 OFF, Hardened Runtime ON)는 그 전환에 바로 맞습니다.

---

## 📁 프로젝트 구조

```
Sources/
├─ App/           메뉴바 라이프사이클, 캡처 진입 조율, 브랜드 상수
├─ Hotkey/        전역 단축키 (Carbon)
├─ Permissions/   화면 녹화 권한 프리플라이트 + 설정 딥링크
├─ CaptureCore/   ScreenCaptureKit 래퍼 (루페 스트림 / 정지 캡처 / 픽셀 샘플)
├─ Geometry/      좌표계 변환 (point ↔ pixel, 멀티 디스플레이)
├─ Overlay/       크로스헤어 / 확대경 / 영역 선택 (AppKit)
├─ Output/        클립보드 다중타입 + 파일 저장 + 썸네일 HUD
├─ Library/       캡처 라이브러리 + 편집기(크롭/주석) 창
└─ Settings/      환경설정
```
