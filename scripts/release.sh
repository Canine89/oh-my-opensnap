#!/usr/bin/env bash
#
# oh-my-opensnap 배포 빌더 (Sparkle 자동 업데이트 포함).
#
#   ./scripts/release.sh                      # 현재 버전으로 DMG만 빌드(로컬 테스트)
#   ./scripts/release.sh 1.0.1                # 1.0.1 로 올려 DMG+ZIP+appcast 생성 (게시 X)
#   ./scripts/release.sh 1.0.1 --publish      # 위 + appcast 푸시 + GitHub Release 업로드
#   (옵션) --skip-notary                       # 공증 건너뛰고 Developer ID 서명만 (빠른 로컬 테스트)
#
# 하는 일:
#   1) (버전 인자 있으면) project.yml 의 MARKETING_VERSION/CURRENT_PROJECT_VERSION 올림
#   2) project.yml → Xcode 프로젝트 재생성 → Release 빌드
#   3) Developer ID 서명(inside-out) + Apple 공증(notarytool --wait) + 스테이플
#   4) 사람이 받을 DMG(공증·스테이플) + Sparkle 업데이트용 ZIP 패키징
#   5) ZIP 을 EdDSA 개인키(키체인)로 서명 → appcast.xml 생성
#   6) --publish: appcast.xml 커밋/푸시 + gh 로 릴리스 생성/자산 업로드
#
# 🔑 공증 준비물 (1회): Apple Developer Program($99) 멤버십 활성 → 'Developer ID Application'
#    인증서(키체인) + notarytool 프로필. 프로필은 아래로 등록:
#      xcrun notarytool store-credentials "oh-my-opensnap" \
#        --apple-id <id> --team-id <TEAMID> --password <앱별-암호>
#    (프로필명을 바꾸면 OMOS_NOTARY_PROFILE 환경변수로 지정)
#
# ⚠️ 업데이트 서명용 EdDSA 개인키는 이 Mac 의 키체인에 있습니다. 분실하면 더 이상
#    기존 사용자에게 업데이트를 내보낼 수 없으니, 'generate_keys -x' 로 백업해 두세요.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SCHEME="oh-my-opensnap"
PROJECT="oh-my-opensnap.xcodeproj"
APP_NAME="oh-my-opensnap.app"
VOL_NAME="oh-my-opensnap"
REPO="Canine89/oh-my-opensnap"
DD="$ROOT/build/dd"
DIST="$ROOT/dist"
UPDATES="$ROOT/updates"
APPCAST="$ROOT/appcast.xml"

# --- 인자 파싱: [버전] [--publish] ---
VERSION_ARG=""
PUBLISH=0
SKIP_NOTARY=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --skip-notary) SKIP_NOTARY=1 ;;
    *) VERSION_ARG="$a" ;;
  esac
done

# --- 1) 버전 올림 (요청 버전이 현재와 다를 때만 → 재실행 시 중복 올림 방지) ---
if [ -n "$VERSION_ARG" ]; then
  CUR_MARKETING=$(grep 'MARKETING_VERSION:' project.yml | grep -oE '"[^"]*"' | tr -d '"' | head -1)
  if [ "$VERSION_ARG" != "$CUR_MARKETING" ]; then
    CUR_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | grep -oE '[0-9]+' | head -1)
    NEW_BUILD=$((CUR_BUILD + 1))
    echo "▸ 버전 올림: $CUR_MARKETING → $VERSION_ARG (빌드 $CUR_BUILD → $NEW_BUILD)"
    sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION_ARG\"/" project.yml
    sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml
  else
    echo "▸ 버전 동일($VERSION_ARG) → 올림 생략(재빌드)"
  fi
fi

echo "▸ 프로젝트 재생성 (xcodegen)"
command -v xcodegen >/dev/null || { echo "✗ 'brew install xcodegen' 필요"; exit 1; }
xcodegen generate >/dev/null

echo "▸ Release 빌드"
rm -rf "$DD" "$DIST"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" clean build >/dev/null

APP="$DD/Build/Products/Release/$APP_NAME"
[ -d "$APP" ] || { echo "✗ 빌드 결과 앱 없음: $APP"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
MINOS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")"

# Developer ID 서명 → 공증(notarization) → 스테이플.
#  - Developer ID Application 인증서(유료 멤버십)로 서명하면 고정 Team ID 가 신원이 되어,
#    같은 팀으로 서명한 모든 업데이트에서 TCC(화면 녹화) 권한이 유지된다.
#  - 공증에는 하드닝 런타임(--options runtime) + 보안 타임스탬프(--timestamp)가 필수.
#  - Sparkle 의 중첩 코드(XPC/Updater/Autoupdate/framework)를 안쪽→바깥(app) 순서로 서명한다.
#    (codesign --deep 는 중첩 XPC 봉인을 망가뜨릴 수 있어 쓰지 않는다.)
DEV_ID="Developer ID Application"
NOTARY_PROFILE="${OMOS_NOTARY_PROFILE:-oh-my-opensnap}"   # xcrun notarytool store-credentials 프로필명
echo "▸ Developer ID 서명 ($DEV_ID)"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_ID"; then
  echo "✗ '$DEV_ID' 인증서가 키체인에 없습니다."
  echo "  Apple Developer Program($99) 멤버십 활성 후, Xcode → Settings → Accounts →"
  echo "  Manage Certificates → '+' → 'Developer ID Application' 로 발급하세요."
  exit 1
fi
SIGN=(codesign --force --options runtime --timestamp --sign "$DEV_ID")
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  FWV="$(readlink "$FW/Versions/Current")"   # 보통 'B'
  B="$FW/Versions/$FWV"
  for nested in \
    "$B/XPCServices/Downloader.xpc" \
    "$B/XPCServices/Installer.xpc" \
    "$B/Autoupdate" \
    "$B/Updater.app"; do
    [ -e "$nested" ] && "${SIGN[@]}" "$nested"
  done
  "${SIGN[@]}" "$FW"
fi
"${SIGN[@]}" "$APP"            # 마지막에 앱 본체 (샌드박스/추가 entitlement 필요해지면 --entitlements 추가)
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null && echo "  서명 확인 ✓"

echo "▸ 패키징 (DMG)"
mkdir -p "$DIST"
# 사람이 받는 DMG (드래그-투-Applications)
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$DIST/oh-my-opensnap-$VERSION.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
"${SIGN[@]}" "$DMG"

if [ "$SKIP_NOTARY" = "0" ]; then
  echo "▸ 공증 제출 (notarytool, 보통 1~5분 소요)"
  if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "✗ 공증 실패. 원인 보기:"
    echo "    xcrun notarytool history --keychain-profile \"$NOTARY_PROFILE\""
    echo "    xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
    exit 1
  fi
  echo "▸ 스테이플 (DMG + .app) — 공증 티켓을 cdhash 로 첨부 → 오프라인에서도 무경고 실행"
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP" >/dev/null && echo "  스테이플 확인 ✓"
  spctl -a -vv "$APP" 2>&1 | grep -iE "accepted|origin" || true
else
  echo "▸ 공증 건너뜀(--skip-notary): Developer ID 서명만 (다운로드 시 Gatekeeper 경고 남음)"
fi

# Sparkle 업데이트용 ZIP (공증·스테이플된 앱으로)
ZIP="$DIST/oh-my-opensnap-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✅ 빌드 산출물:"
echo "   $DMG"
echo "   $ZIP"

# 버전 인자가 없으면 여기서 끝(로컬 테스트용 DMG만).
if [ -z "$VERSION_ARG" ]; then
  echo
  echo "(버전 인자 없이 실행 → appcast/게시는 건너뜀. 예: ./scripts/release.sh 1.0.1 --publish)"
  exit 0
fi

echo "▸ EdDSA 서명 + appcast.xml 생성"
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -path '*sparkle*' -type f 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "✗ sign_update 도구를 못 찾음 (Sparkle 패키지 해석 필요)"; exit 1; }
# 예: sparkle:edSignature="..." length="12345"
SIG_ATTRS="$("$SIGN_UPDATE" "$ZIP")"
mkdir -p "$UPDATES"
UPDATE_ZIP="$UPDATES/oh-my-opensnap-$VERSION.zip"
cp "$ZIP" "$UPDATE_ZIP"
ZIP_URL="https://raw.githubusercontent.com/$REPO/main/updates/oh-my-opensnap-$VERSION.zip"
PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"

# 릴리스 노트: CHANGELOG.md 의 "## <버전>" 섹션을 읽어
#  - Sparkle 업데이트 창(appcast description, HTML)
#  - GitHub 릴리스 노트(markdown)
# 양쪽에 보여준다.
NOTES_MD=""
if [ -f CHANGELOG.md ]; then
  NOTES_MD="$(awk -v v="$VERSION" '$0 ~ ("^## " v "( |$)"){f=1;next} /^## /{f=0} f' CHANGELOG.md)"
fi
[ -n "$NOTES_MD" ] || NOTES_MD="- 개선 및 버그 수정"
# appcast 용 HTML (불릿 → <li>, XML 특수문자 이스케이프)
NOTES_HTML="$(printf '%s\n' "$NOTES_MD" \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
  | awk 'BEGIN{print "<ul>"} {line=$0; sub(/^[[:space:]]*[-*][[:space:]]+/,"",line); if(line!="") print "<li>"line"</li>"} END{print "</ul>"}')"

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>oh-my-opensnap</title>
    <link>https://raw.githubusercontent.com/$REPO/main/appcast.xml</link>
    <description>oh-my-opensnap 업데이트</description>
    <language>ko</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <description><![CDATA[<h2>oh-my-opensnap $VERSION</h2>
$NOTES_HTML]]></description>
      <enclosure url="$ZIP_URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML
echo "  appcast.xml 작성 ✓ (버전 $VERSION / build $BUILD)"

if [ "$PUBLISH" = "1" ]; then
  command -v gh >/dev/null || { echo "✗ 'brew install gh' 필요"; exit 1; }
  TAG="v$VERSION"
  # 1) appcast/버전 먼저 푸시 → 릴리스 태그가 최신 커밋을 가리키도록
  echo "▸ appcast.xml + project.yml(버전) + updates ZIP 커밋/푸시"
  git add appcast.xml project.yml "$UPDATE_ZIP"
  git commit -q -m "release: v$VERSION (appcast 갱신)" || true
  git push
  echo "▸ 공개 업데이트 ZIP 다운로드 확인"
  curl --fail --location --retry 12 --retry-delay 5 --retry-all-errors \
    --output /tmp/oh-my-opensnap-update-check.zip "$ZIP_URL" >/dev/null
  ACTUAL_SIZE="$(stat -f%z /tmp/oh-my-opensnap-update-check.zip)"
  EXPECTED_SIZE="$(stat -f%z "$ZIP")"
  rm -f /tmp/oh-my-opensnap-update-check.zip
  if [ "$ACTUAL_SIZE" != "$EXPECTED_SIZE" ]; then
    echo "✗ 공개 ZIP 크기 불일치: expected=$EXPECTED_SIZE actual=$ACTUAL_SIZE"
    exit 1
  fi
  # 2) 릴리스 생성/자산 업로드
  echo "▸ GitHub Release '$TAG' 업로드 (DMG + ZIP)"
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$ZIP" --clobber
  else
    gh release create "$TAG" "$DMG" "$ZIP" \
      --title "oh-my-opensnap $VERSION" \
      --notes "$NOTES_MD

---
설치: [INSTALL.md](https://github.com/$REPO/blob/main/INSTALL.md) 참고. 이미 설치한 사용자는 앱이 자동으로 업데이트합니다."
  fi
  echo "✅ 게시 완료: $TAG"
else
  echo
  echo "다음 단계(게시): ./scripts/release.sh $VERSION --publish"
fi
