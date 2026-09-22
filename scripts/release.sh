#!/usr/bin/env bash
#
# oh-my-opensnap 배포 빌더 (Sparkle 자동 업데이트 포함).
#
#   ./scripts/release.sh 1.0.1 --publish      # 배포(권장): 버전 올림 → 빌드·공증 → GitHub Release → appcast 푸시
#   ./scripts/release.sh                      # 현재 버전으로 DMG만 빌드(로컬 테스트)
#   ./scripts/release.sh 1.0.1                # 로컬 리허설: 1.0.1 로 올려 DMG+ZIP+appcast 생성 (게시 X)
#                                             #  → 이어서 같은 버전으로 --publish 하면 리허설 산출물은 허용되고 새로 만들어진다
#   (옵션) --skip-notary                       # 공증 건너뛰고 Developer ID 서명만 (빠른 로컬 테스트)
#
# 하는 일:
#   1) (버전 인자 있으면) project.yml 의 MARKETING_VERSION/CURRENT_PROJECT_VERSION 올림
#      — 현재보다 낮은 버전은 거부, 이미 커밋된(게시된) 버전은 재빌드하지 않음
#   2) project.yml → Xcode 프로젝트 재생성 → Release 빌드
#   3) Developer ID 서명(inside-out) + Apple 공증(notarytool --wait) + 스테이플
#   4) 사람이 받을 DMG(공증·스테이플) + Sparkle 업데이트용 ZIP 패키징
#   5) ZIP 을 EdDSA 개인키(키체인)로 서명 → appcast.xml 생성
#   6) --publish: 릴리스 커밋(로컬) → gh 로 릴리스 생성/자산 업로드 → 푸시 → 공개 ZIP 검증
#
# 재실행: 같은 버전의 updates ZIP 이 이미 커밋돼 있으면 새로 빌드하지 않는다(같은 이름에 다른 바이트를
#   올리면 CDN 캐시와 EdDSA 서명이 어긋난다). 이때 --publish 는 커밋된 ZIP + dist/ 의 DMG 로
#   GitHub Release 업로드·푸시·검증만 재개한다. DMG 가 없으면 버전을 올려 새로 배포한다.
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
source "$ROOT/scripts/release-validation.sh"

SCHEME="oh-my-opensnap"
PROJECT="oh-my-opensnap.xcodeproj"
APP_NAME="oh-my-opensnap.app"
VOL_NAME="oh-my-opensnap"
REPO="Canine89/oh-my-opensnap"
DD="$ROOT/build/dd"
DIST="$ROOT/dist"
UPDATES="$ROOT/updates"
APPCAST="$ROOT/appcast.xml"
CASK="$ROOT/Casks/oh-my-opensnap.rb"

# --- 인자 파싱: [버전] [--publish] ---
VERSION_ARG=""
PUBLISH=0
SKIP_NOTARY=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --skip-notary) SKIP_NOTARY=1 ;;
    --*) echo "✗ 알 수 없는 옵션: $a" >&2; exit 1 ;;
    *) [ -z "$VERSION_ARG" ] || { echo "✗ 버전은 하나만 지정하세요." >&2; exit 1; }; VERSION_ARG="$a" ;;
  esac
done

validate_release_options "$VERSION_ARG" "$PUBLISH" "$SKIP_NOTARY"

STAGING=""
RELEASE_TMP="$(mktemp -d)"
trap 'rm -rf "$STAGING" "$RELEASE_TMP"' EXIT

# 릴리스 노트: CHANGELOG.md 의 "## <버전>" 섹션 (없으면 기본 문구).
release_notes_md() {
  local notes=""
  if [ -f CHANGELOG.md ]; then
    notes="$(awk -v v="$1" '$0 ~ ("^## " v "( |$)"){f=1;next} /^## /{f=0} f' CHANGELOG.md)"
  fi
  printf '%s\n' "${notes:-- 개선 및 버그 수정}"
}

# GitHub Release 생성(또는 기존 릴리스에 자산 덮어쓰기). 태그가 없으면 원격 기본 브랜치 HEAD 에 만든다.
publish_github_release() {
  local version="$1" dmg="$2" zip="$3" tag="v$1"
  echo "▸ GitHub Release '$tag' 업로드 (DMG + ZIP)"
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$dmg" "$zip" --clobber
  else
    cat > "$RELEASE_TMP/release-notes.md" <<NOTES
$(release_notes_md "$version")

---
설치: [INSTALL.md](https://github.com/$REPO/blob/main/INSTALL.md) 참고. 이미 설치한 사용자는 앱이 자동으로 업데이트합니다.
NOTES
    gh release create "$tag" "$dmg" "$zip" \
      --title "oh-my-opensnap $version" --notes-file "$RELEASE_TMP/release-notes.md"
  fi
}

# raw.githubusercontent 에서 받은 ZIP 이 appcast 가 서명한 로컬 ZIP 과 같은 바이트인지 확인.
verify_public_update_zip() {
  local url="$1" expected_zip="$2" actual expected
  echo "▸ 공개 업데이트 ZIP 다운로드 확인"
  curl --fail --location --retry 12 --retry-delay 5 --retry-all-errors \
    --output "$RELEASE_TMP/update-check.zip" "$url" >/dev/null
  actual="$(shasum -a 256 "$RELEASE_TMP/update-check.zip" | awk '{print $1}')"
  expected="$(shasum -a 256 "$expected_zip" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "✗ 공개 ZIP SHA-256 불일치" >&2
    exit 1
  fi
}

# --- 0) 이미 커밋(게시)된 버전인지 확인 ---
RESUME=0
if [ -n "$VERSION_ARG" ]; then
  CUR_MARKETING="$(project_marketing_version project.yml)"
  require_version_not_lower "$VERSION_ARG" "$CUR_MARKETING"
  UPDATE_ZIP_REL="updates/oh-my-opensnap-$VERSION_ARG.zip"
  if [ "$PUBLISH" = 1 ]; then
    git fetch --quiet origin main || { echo "✗ origin/main 을 가져오지 못했습니다." >&2; exit 1; }
  fi
  if git_has_path HEAD "$UPDATE_ZIP_REL"; then
    RESUME=1
  elif git_has_path origin/main "$UPDATE_ZIP_REL"; then
    echo "✗ v$VERSION_ARG 은(는) 이미 origin/main 에 게시됐습니다. git pull 후 재개하거나 새 버전을 지정하세요." >&2
    exit 1
  fi
  if [ "$RESUME" = 1 ] && [ "$PUBLISH" != 1 ]; then
    echo "✗ v$VERSION_ARG 업데이트 ZIP 이 이미 커밋돼 있어 다시 빌드하지 않습니다(공개 ZIP·EdDSA 서명과 어긋남)." >&2
    echo "  새 버전을 지정하거나, GitHub Release 업로드만 재개하려면 --publish 로 실행하세요." >&2
    exit 1
  fi
fi
if [ "$PUBLISH" = 1 ]; then
  if [ "$RESUME" = 1 ]; then
    require_clean_release_tree
  else
    require_clean_release_tree "$VERSION_ARG"
  fi
  [ "$(git branch --show-current)" = main ] || { echo "✗ appcast 게시 브랜치는 main이어야 합니다." >&2; exit 1; }
fi

# --- 재개: 커밋된 ZIP + 이전 실행의 DMG 로 GitHub Release·푸시·검증만 ---
if [ "$RESUME" = 1 ]; then
  command -v gh >/dev/null || { echo "✗ 'brew install gh' 필요"; exit 1; }
  VERSION="$VERSION_ARG"
  DMG="$DIST/oh-my-opensnap-$VERSION.dmg"
  UPDATE_ZIP="$ROOT/$UPDATE_ZIP_REL"
  echo "▸ v$VERSION 은(는) 이미 커밋돼 있음 → 재빌드 없이 GitHub Release 업로드·푸시·검증만 재개"
  [ -f "$DMG" ] || {
    echo "✗ $DMG 가 없습니다. 같은 산출물을 다시 만들 수 없으니 버전을 올려 새로 배포하세요." >&2
    exit 1
  }
  if [ -f "$CASK" ]; then
    CASK_SHA="$(sed -n 's/.*sha256 "\([^"]*\)".*/\1/p' "$CASK" | head -1)"
    [ "$(shasum -a 256 "$DMG" | awk '{print $1}')" = "$CASK_SHA" ] || {
      echo "✗ dist 의 DMG 가 커밋된 Cask sha256 과 다릅니다. 버전을 올려 새로 배포하세요." >&2
      exit 1
    }
  fi
  codesign --verify --strict "$DMG"
  xcrun stapler validate "$DMG" >/dev/null
  publish_github_release "$VERSION" "$DMG" "$UPDATE_ZIP"
  git push
  verify_public_update_zip "https://raw.githubusercontent.com/$REPO/main/$UPDATE_ZIP_REL" "$UPDATE_ZIP"
  echo "✅ 게시 재개 완료: v$VERSION"
  exit 0
fi

# 테스트 실패를 서명·공증·게시 전에 차단한다.
"$ROOT/scripts/check.sh" > "$ROOT/build-check.log" 2>&1 || {
  cat "$ROOT/build-check.log" >&2
  exit 1
}

# --- 1) 버전 올림 (요청 버전이 현재와 다를 때만 → 재실행 시 중복 올림 방지) ---
if [ -n "$VERSION_ARG" ]; then
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
# 빌드 자체는 서명 없이 한다 — 서명은 아래에서 Developer ID 로 inside-out 으로 다시 하므로,
# Xcode 자동 서명이 요구하는 'Apple Development' 인증서가 없는 Mac 에서도 릴리스가 가능하다.
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" clean build CODE_SIGNING_ALLOWED=NO >/dev/null

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
DEV_ID="${OMOS_SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${OMOS_NOTARY_PROFILE:-oh-my-opensnap}"   # xcrun notarytool store-credentials 프로필명
echo "▸ Developer ID 서명 ($DEV_ID)"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$DEV_ID"; then
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
# `cmd && echo` 목록은 set -e 를 빠져나가므로 실패를 명시적으로 치명 처리한다.
if ! codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null; then
  echo "✗ 앱 서명 검증 실패" >&2
  exit 1
fi
echo "  서명 확인 ✓"

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
  NOTARY_RESULT="$DIST/notarization-$VERSION.json"
  if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_RESULT"; then
    echo "✗ 공증 실패. 원인 보기:"
    echo "    xcrun notarytool history --keychain-profile \"$NOTARY_PROFILE\""
    echo "    xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
    exit 1
  fi
  SUBMISSION_ID="$(require_accepted_notarization "$NOTARY_RESULT")"
  xcrun notarytool info "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" --output-format json > "$RELEASE_TMP/notary-info.json"
  require_accepted_notarization "$RELEASE_TMP/notary-info.json" >/dev/null
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > "$RELEASE_TMP/notary-history.json"
  require_notarization_history "$RELEASE_TMP/notary-history.json" "$SUBMISSION_ID"
  echo "▸ 스테이플 (DMG + .app) — 공증 티켓을 cdhash 로 첨부 → 오프라인에서도 무경고 실행"
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  verify_notarized_artifacts "$APP" "$DMG"
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
SIGN_UPDATE="$(find "$DD/SourcePackages" "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -path '*sparkle*' -type f 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "✗ sign_update 도구를 못 찾음 (Sparkle 패키지 해석 필요)"; exit 1; }
# 예: sparkle:edSignature="..." length="12345"
SIG_ATTRS="$("$SIGN_UPDATE" "$ZIP")"
UPDATE_SIGNATURE="$(printf '%s' "$SIG_ATTRS" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
UPDATE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
swift "$ROOT/scripts/verify-update.swift" "$ZIP" "$UPDATE_SIGNATURE" "$UPDATE_PUBLIC_KEY"

mkdir -p "$UPDATES"
UPDATE_ZIP="$UPDATES/oh-my-opensnap-$VERSION.zip"
cp "$ZIP" "$UPDATE_ZIP"
ZIP_URL="https://raw.githubusercontent.com/$REPO/main/updates/oh-my-opensnap-$VERSION.zip"
PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"

if [ -f "$CASK" ]; then
  DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  sed -i '' "s/version \"[^\"]*\"/version \"$VERSION\"/" "$CASK"
  sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"$DMG_SHA\"/" "$CASK"
  sed -i '' 's@oh-my-opensnap-#{version}[^"]*\.dmg@oh-my-opensnap-#{version}.dmg@' "$CASK"
  echo "  Homebrew Cask 갱신 ✓ ($DMG_SHA)"
fi

# 릴리스 노트: CHANGELOG.md 의 "## <버전>" 섹션을 읽어
#  - Sparkle 업데이트 창(appcast description, HTML)
#  - GitHub 릴리스 노트(markdown)
# 양쪽에 보여준다.
NOTES_MD="$(release_notes_md "$VERSION")"
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
  # 1) 릴리스 커밋은 로컬에만 먼저 만든다. (이후 실패하면 재실행이 이 커밋의 ZIP 으로 재개한다)
  echo "▸ appcast.xml + project.yml(버전) + updates ZIP + Cask 커밋"
  git add appcast.xml project.yml "$UPDATE_ZIP"
  [ -f "$CASK" ] && git add "$CASK"
  if ! git diff --cached --quiet; then
    git commit -q -m "release: v$VERSION (appcast 갱신)"
  fi
  # 2) GitHub Release(DMG+ZIP)를 먼저 만든다 — Cask·appcast 가 가리킬 DMG 가 공개된 뒤에 푸시해야
  #    gh 실패 시 존재하지 않는 DMG 를 가리키는 Cask 가 배포되지 않는다.
  #    (태그는 원격 main HEAD = 이 버전의 소스 커밋에 만들어진다)
  publish_github_release "$VERSION" "$DMG" "$ZIP"
  # 3) appcast/Cask 푸시 → 공개 ZIP 이 서명한 바이트와 같은지 확인
  echo "▸ 릴리스 커밋 푸시"
  git push
  verify_public_update_zip "$ZIP_URL" "$ZIP"
  echo "✅ 게시 완료: v$VERSION"
else
  echo
  echo "(로컬 리허설 — 게시하지 않았습니다. 게시: ./scripts/release.sh $VERSION --publish)"
fi
