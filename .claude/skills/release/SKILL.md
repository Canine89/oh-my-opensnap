---
name: release
description: >
  oh-my-opensnap 새 버전 배포 절차(Developer ID 서명 + Apple 공증 + Sparkle appcast + GitHub Release).
  사용 시점: "배포해", "릴리스", "새 버전 올려", "1.0.xx 로 내보내", "/release 1.0.77" 같은 요청.
  scripts/release.sh --publish 를 올바른 순서(CHANGELOG 섹션 → 소스 커밋 → 백그라운드 실행 → 검증 → 보고)로
  돌리는 운영 매뉴얼이다. 자체서명/무공증 경로는 전역 mac-app-release 스킬이며, 이 저장소에서는 쓰지 않는다.
---

# oh-my-opensnap 릴리스

`/release <버전>` 또는 "배포해" 요청을 받으면 아래 순서를 **그대로** 따른다. 인자가 없으면 현재
`project.yml`의 `MARKETING_VERSION`에서 패치 버전을 +1 한 값을 제안하고 진행한다.

실제 작업은 전부 `scripts/release.sh`가 한다(버전 올림 → xcodegen → Release 빌드 → inside-out
Developer ID 서명 → notarytool 공증·스테이플 → DMG+ZIP → EdDSA 서명 + appcast → 커밋/푸시 →
`gh release`). 이 스킬은 **스크립트가 하지 않는 앞뒤 일**과 **검증**을 책임진다.

---

## 0. 절대 규칙

- 배포는 되돌리기 어려운 **외부 공개 동작**이다. 사용자가 이번 턴에 명시적으로 "배포해/릴리스해"라고 한 경우에만 `--publish`를 붙인다. 이전 턴의 승인은 다음 배포로 이어지지 않는다.
- `project.yml`·`Info.plist`·`.xcodeproj`·`appcast.xml`을 손으로 고치지 않는다. 버전/빌드 번호는 스크립트가 올린다.
- 시크릿(EdDSA 개인키, 앱별 암호)은 절대 출력하거나 커밋하지 않는다.

## 1. 사전 점검 (스크립트가 안 해 주는 것)

1. **소스가 빌드되는가** — 두 스킴 모두 Debug 빌드가 통과해야 한다.
   ```bash
   xcodebuild -project oh-my-opensnap.xcodeproj -scheme oh-my-opensnap -configuration Debug -derivedDataPath build/dd build 2>&1 | grep -E 'error:|BUILD'
   xcodebuild -project oh-my-opensnap.xcodeproj -scheme oh-my-opensnap-mas -configuration Debug -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'error:|BUILD'
   ```
   새 `.swift` 파일을 추가했다면 먼저 `xcodegen generate`.
2. **`CHANGELOG.md`에 `## <버전>` 섹션이 있는가** — 스크립트가 이 섹션을 읽어 Sparkle 업데이트 창(HTML)과 GitHub 릴리스 노트(markdown) 양쪽에 그대로 쓴다. 없으면 이번 변경을 사용자 관점 불릿으로 써서 **파일 맨 위(`## <이전버전>` 바로 앞)**에 추가한다. 문체는 기존 섹션과 같게(기능이 아니라 "사용자가 보는 변화").
3. **소스 변경을 먼저 커밋한다** — 스크립트의 `--publish`는 `appcast.xml` + `project.yml` + `updates/*.zip` (+ Cask)만 `release: vX.Y.Z (appcast 갱신)`로 커밋한다. 소스가 미커밋이면 릴리스 커밋과 섞이거나 누락된다.
   ```bash
   git add -A Sources CHANGELOG.md   # 필요한 파일만
   git commit -m "feat|fix: <한 줄 요약>

   <불릿>

   Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
   ```
   `git status --short`로 남은 미커밋 파일이 의도된 것인지 확인한다(`build/`, `dist/`는 gitignore).
4. 버전 결정: 요청 버전이 현재 `MARKETING_VERSION`과 같으면 스크립트가 빌드 번호를 올리지 않는다 → Sparkle이 업데이트를 못 본다. **항상 새 버전 문자열**을 준다.

## 2. 실행

공증(`notarytool --wait`)이 보통 1~5분 걸리므로 **백그라운드**로 돌리고 로그를 파일에 남긴다. 폴링하지 말고 완료 알림을 기다린다.

```bash
# Bash 도구: run_in_background=true, timeout=600000
./scripts/release.sh <버전> --publish > build/release-<버전>.log 2>&1; echo "EXIT=$?" >> build/release-<버전>.log
```

사용자에게는 "빌드→서명→공증→업로드, 3~5분" 정도로 한 줄 알리고 턴을 끝낸다. 도중에 로그를 볼 일이 있으면 `tail -5 build/release-<버전>.log` (서명 단계의 "replacing existing signature" 줄은 정상).

변형:
- `./scripts/release.sh <버전>` — 게시 없이 DMG+ZIP+appcast만 생성(로컬 검증). 이후 같은 버전으로 `--publish`를 다시 돌리면 버전은 중복 증가하지 않는다.
- `./scripts/release.sh` (인자 없음) — 현재 버전으로 로컬 테스트 DMG만.
- `--skip-notary` — 로컬 확인용. **공개 배포에는 절대 쓰지 않는다** (Gatekeeper 경고).
- 공증 프로필명이 기본(`oh-my-opensnap`)과 다르면 `OMOS_NOTARY_PROFILE=<이름>`.

## 3. 검증 (완료 알림 후 반드시)

```bash
grep -E '^▸|EXIT=|status:|Invalid|error|https://github.com' build/release-<버전>.log | tail -30
git --no-pager log --oneline -3          # 맨 위가 "release: v<버전> (appcast 갱신)"
git status --short                        # 비어 있어야 함
gh release view v<버전> --json tagName,assets --jq '.tagName, (.assets[] | "\(.name) \(.size)")'
```

합격 기준 — 전부 만족해야 "배포 완료"라고 말한다:
- 로그에 `status: Accepted`, `▸ 공개 업데이트 ZIP 다운로드 확인` 통과, `EXIT=0`
- `release: v<버전>` 커밋이 `main`에 푸시됨
- GitHub Release에 `oh-my-opensnap-<버전>.dmg` 와 `oh-my-opensnap-<버전>.zip` 두 자산
- `appcast.xml`의 최신 `<item>`이 새 버전/빌드 번호

## 4. 실패했을 때

| 증상 | 원인/조치 |
|---|---|
| `status: Invalid` | 공증 거부. `xcrun notarytool log <submission-id> --keychain-profile oh-my-opensnap`로 사유 확인(대개 서명 누락/하드닝 런타임/entitlement). 고친 뒤 **같은 버전으로 재실행** — 버전은 중복 증가하지 않는다. |
| 공증은 됐는데 `gh release` 실패 | `gh auth status` 확인 후 같은 버전으로 재실행. 이미 릴리스가 있으면 스크립트가 upload로 처리한다. |
| 공개 ZIP 크기 불일치 | raw.githubusercontent 캐시 지연. 1~2분 후 재실행. |
| `Developer ID Application` 인증서 없음 / 프로필 없음 | 이 Mac의 1회 설정 누락. `CLAUDE.md` §4 "1회 전역 설정" 안내 후 중단. 대체 경로(ad-hoc/자체서명)로 우회하지 않는다 — TCC 권한이 풀린다. |
| 빌드 실패 | 릴리스 문제가 아니다. §1로 돌아가 Debug 빌드부터. |

스크립트는 `set -euo pipefail`이라 실패 지점 이후는 실행되지 않는다. 버전 올림은 이미 반영됐을 수 있으니 `git diff project.yml`을 확인하고, 재실행 시 같은 버전 문자열을 쓴다.

## 5. 보고 형식

완료 후 사용자에게:
- 공증 결과, 커밋 해시 2개(`feat:` + `release:`), Release URL, 자산 2개와 크기
- 이번 버전에 들어간 변경 한 줄 요약 (CHANGELOG 섹션 기준)
- 실기기 확인 없이 나간 부분이 있으면 무엇을 봐 달라고 할지 명시

## 참고

- 왜 Developer ID인가(ad-hoc 금지): `CLAUDE.md` §5. 업데이트마다 화면 녹화 권한이 풀리지 않게 하는 핵심.
- 하지 말 것 목록: `CLAUDE.md` §6.
- 스크립트 내부 단계 상세: `scripts/release.sh` 상단 주석.
