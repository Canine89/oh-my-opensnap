#!/usr/bin/env bash
#
# oh-my-opensnap 무료 배포용 DMG 빌더.
#
#   ./scripts/release.sh              # dist/oh-my-opensnap-<버전>.dmg 생성
#   ./scripts/release.sh --publish    # 위 + GitHub Release 생성/업로드(gh 필요)
#
# 하는 일:
#   1) project.yml → Xcode 프로젝트 재생성
#   2) Release 구성으로 빌드
#   3) ad-hoc 재서명(개인 Apple 인증서 제거 — 배포본에 개인 신원이 박히지 않게)
#   4) "Applications로 드래그" 형태의 DMG 패키징
#
# 공증($99 Developer Program)은 하지 않는다. 받는 사람은 첫 실행 때 한 번
# Gatekeeper를 우회해야 한다(INSTALL.md 참고).

set -euo pipefail

cd "$(dirname "$0")/.."          # 리포 루트로 이동
ROOT="$(pwd)"

SCHEME="oh-my-opensnap"
PROJECT="oh-my-opensnap.xcodeproj"
APP_NAME="oh-my-opensnap.app"
VOL_NAME="oh-my-opensnap"
DD="$ROOT/build/dd"             # 파생 데이터(빌드 산출물)
DIST="$ROOT/dist"

echo "▸ 1/4  프로젝트 재생성 (xcodegen)"
command -v xcodegen >/dev/null || { echo "✗ xcodegen 이 없습니다. 'brew install xcodegen' 후 다시 실행하세요."; exit 1; }
xcodegen generate >/dev/null

echo "▸ 2/4  Release 빌드"
rm -rf "$DD" "$DIST"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DD" \
  clean build >/dev/null

APP="$DD/Build/Products/Release/$APP_NAME"
[ -d "$APP" ] || { echo "✗ 빌드 결과 앱을 찾지 못했습니다: $APP"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

echo "▸ 3/4  ad-hoc 재서명 (개인 인증서 제거)"
codesign --remove-signature "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "  서명 확인 ✓"

echo "▸ 4/4  DMG 패키징"
mkdir -p "$DIST"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # 드래그-투-Applications
DMG="$DIST/oh-my-opensnap-$VERSION.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo
echo "✅ 완료: $DMG"
echo

if [ "${1:-}" = "--publish" ]; then
  command -v gh >/dev/null || { echo "✗ gh CLI 가 없습니다. 'brew install gh' 후 다시 실행하세요."; exit 1; }
  TAG="v$VERSION"
  echo "▸ GitHub Release '$TAG' 생성/업로드"
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" --clobber
  else
    gh release create "$TAG" "$DMG" \
      --title "oh-my-opensnap $VERSION" \
      --notes "설치 방법은 저장소의 INSTALL.md 를 참고하세요. (처음 한 번 Gatekeeper 우회 필요)"
  fi
  echo "✅ 릴리스 업로드 완료: $TAG"
else
  echo "다음 단계:"
  echo "  • 수동 배포:  GitHub → Releases → 'Draft a new release' 에서 위 DMG 업로드"
  echo "  • 자동 배포:  ./scripts/release.sh --publish   (gh CLI 로 릴리스 생성)"
fi
