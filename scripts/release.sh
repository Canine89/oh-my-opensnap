#!/usr/bin/env bash
#
# oh-my-opensnap 배포 빌더 (Sparkle 자동 업데이트 포함).
#
#   ./scripts/release.sh                      # 현재 버전으로 DMG만 빌드(로컬 테스트)
#   ./scripts/release.sh 1.0.1                # 1.0.1 로 올려 DMG+ZIP+appcast 생성 (게시 X)
#   ./scripts/release.sh 1.0.1 --publish      # 위 + appcast 푸시 + GitHub Release 업로드
#
# 하는 일:
#   1) (버전 인자 있으면) project.yml 의 MARKETING_VERSION/CURRENT_PROJECT_VERSION 올림
#   2) project.yml → Xcode 프로젝트 재생성 → Release 빌드
#   3) ad-hoc 재서명(개인 인증서 제거)
#   4) 사람이 받을 DMG + Sparkle 업데이트용 ZIP 패키징
#   5) ZIP 을 EdDSA 개인키(키체인)로 서명 → appcast.xml 생성
#   6) --publish: appcast.xml 커밋/푸시 + gh 로 릴리스 생성/자산 업로드
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
APPCAST="$ROOT/appcast.xml"

# --- 인자 파싱: [버전] [--publish] ---
VERSION_ARG=""
PUBLISH=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
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

# 자체서명 인증서로 재서명.
#  - ad-hoc 는 빌드마다 cdhash 가 바뀌어 macOS 26 에서 화면 녹화 권한이 업데이트마다 풀린다.
#  - 이 앱 전용 자체서명 인증서로 서명하면 Designated Requirement 가 인증서에 고정되어,
#    같은 인증서로 서명한 모든 업데이트에서 권한이 유지된다.
#  - 팀ID 없는 인증서라 하드닝 런타임은 끈다(라이브러리 검증이 임베드 프레임워크를 막지 않도록).
SIGN_ID="oh-my-opensnap"
echo "▸ 자체서명 인증서로 재서명 ($SIGN_ID)"
if ! security find-identity 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  echo "✗ '$SIGN_ID' 코드서명 인증서가 키체인에 없습니다."
  echo "  백업해 둔 .p12 를 import 하거나, scripts/make-signing-cert.sh 로 (재)생성하세요."
  echo "  ⚠️ 재생성하면 DR 이 바뀌어 기존 사용자가 화면 녹화 권한을 한 번 다시 켜야 합니다."
  exit 1
fi
codesign --remove-signature "$APP" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "  서명 확인 ✓"
codesign -d --requirements - "$APP" 2>&1 | grep -i designated || true

echo "▸ 패키징 (DMG + ZIP)"
mkdir -p "$DIST"
# 사람이 받는 DMG (드래그-투-Applications)
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$DIST/oh-my-opensnap-$VERSION.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
# Sparkle 업데이트용 ZIP
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
ZIP_URL="https://github.com/$REPO/releases/download/v$VERSION/oh-my-opensnap-$VERSION.zip"
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
  echo "▸ appcast.xml + project.yml(버전) 커밋/푸시"
  git add appcast.xml project.yml
  git commit -q -m "release: v$VERSION (appcast 갱신)" || true
  git push
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
