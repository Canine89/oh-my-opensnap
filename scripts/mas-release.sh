#!/bin/bash
# Mac App Store 제출용 빌드/업로드.
#
# 사용법:
#   ./scripts/mas-release.sh                 # 현재 버전으로 .pkg 만들기(업로드 안 함)
#   ./scripts/mas-release.sh 1.0.84          # 버전 올려 .pkg 만들기
#   ./scripts/mas-release.sh 1.0.84 --upload # 위 + App Store Connect 업로드
#
# 하는 일:
#   1) (버전 인자 있으면) project.yml 의 MARKETING_VERSION/CURRENT_PROJECT_VERSION 올림
#   2) xcodegen generate → oh-my-opensnap-mas 스킴 아카이브(자동 서명, 프로파일 자동 발급)
#   3) app-store-connect 방식으로 export → 서명된 .pkg
#   4) --upload: xcrun altool 로 App Store Connect 업로드
#
# 🔑 준비물 (1회):
#   - Apple Distribution + Mac Installer Distribution 인증서 (Xcode → Settings → Accounts
#     → Manage Certificates). WWDR G3 중간 인증서가 없으면 인증서가 "신뢰되지 않음"으로
#     보인다 → https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer 설치.
#   - App Store Connect 에 앱 레코드 (번들 ID com.goldenrabbit.omopensnap.mas).
#     레코드가 없으면 업로드가 "no app with bundle id" 로 거부된다.
#   - 업로드 인증: App Store Connect API 키를 쓰려면 아래 두 환경변수를 설정한다.
#       export OMOS_ASC_API_KEY=<Key ID>       # ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8
#       export OMOS_ASC_API_ISSUER=<Issuer ID>
#     설정하지 않으면 업로드는 건너뛰고, Xcode Organizer 로 올리는 방법을 안내한다.
#
# ⚠️ 빌드 번호는 Developer ID 트랙(release.sh)과 project.yml 을 공유한다. App Store Connect 는
#    같은 빌드 번호의 재업로드를 거부하므로, 심사 리젝 후 다시 올릴 때는 반드시 버전을 올린다.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/scripts/release-validation.sh"

SCHEME="oh-my-opensnap-mas"
PROJECT="oh-my-opensnap.xcodeproj"
APP_NAME="Oh-my-opensnap.app"
PKG_NAME="Oh-my-opensnap.pkg"
TEAM_ID="M7NU9F8CZN"
BUNDLE_ID="com.goldenrabbit.omopensnap.mas"
DD="$ROOT/build/masdd"
ARCHIVE="$ROOT/build/mas.xcarchive"
EXPORT_DIR="$ROOT/build/mas-export"

VERSION_ARG=""
UPLOAD=0
for a in "$@"; do
  case "$a" in
    --upload) UPLOAD=1 ;;
    --*) echo "✗ 알 수 없는 옵션: $a" >&2; exit 1 ;;
    *) [ -z "$VERSION_ARG" ] || { echo "✗ 버전은 하나만 지정하세요." >&2; exit 1; }; VERSION_ARG="$a" ;;
  esac
done

validate_release_options "$VERSION_ARG" 0 0
if [ "$UPLOAD" = 1 ]; then
  require_clean_release_tree
  [ -n "${OMOS_ASC_API_KEY:-}" ] && [ -n "${OMOS_ASC_API_ISSUER:-}" ] || {
    echo "✗ 업로드에는 OMOS_ASC_API_KEY와 OMOS_ASC_API_ISSUER가 필요합니다." >&2
    exit 1
  }
fi
"$ROOT/scripts/check.sh" > "$ROOT/build-check.log" 2>&1 || { cat "$ROOT/build-check.log" >&2; exit 1; }

# --- 1) 버전 올림 (요청 버전이 현재와 다를 때만) ---
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

# --- 2) 인증서 확인 ---
for cert in "Apple Distribution" "3rd Party Mac Developer Installer"; do
  if ! security find-identity -v 2>/dev/null | grep -q "$cert"; then
    echo "✗ '$cert' 인증서를 키체인에서 찾지 못했습니다."
    echo "  Xcode → Settings → Accounts → Manage Certificates → '+' 로 발급하세요."
    echo "  발급했는데도 안 보이면 WWDR G3 중간 인증서가 없는 경우입니다:"
    echo "    curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
    echo "    security add-certificates -k ~/Library/Keychains/login.keychain-db AppleWWDRCAG3.cer"
    exit 1
  fi
done
echo "  인증서 확인 ✓"

# --- 3) 아카이브 (자동 서명: 프로비저닝 프로파일을 필요하면 새로 발급) ---
echo "▸ 아카이브 ($SCHEME)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" -archivePath "$ARCHIVE" archive -allowProvisioningUpdates >/dev/null
[ -d "$ARCHIVE" ] || { echo "✗ 아카이브 실패"; exit 1; }

APP="$ARCHIVE/Products/Applications/$APP_NAME"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
echo "  $VERSION (build $BUILD) ✓"

# Sparkle 이 섞여 들어가면 App Store 심사에서 거부된다(자체 업데이트 금지).
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "✗ MAS 빌드에 Sparkle 이 포함됐습니다 — project.yml 의 MAS 타깃에서 의존성을 빼세요."
  exit 1
fi

# --- 4) export (app-store-connect 방식 → 서명된 .pkg) ---
echo "▸ export (app-store-connect)"
OPTS="$(mktemp -t masexport).plist"
cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>destination</key>
	<string>export</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OPTS" -allowProvisioningUpdates >/dev/null
rm -f "$OPTS"

PKG="$EXPORT_DIR/$PKG_NAME"
[ -f "$PKG" ] || { echo "✗ .pkg 생성 실패"; exit 1; }
pkgutil --check-signature "$PKG"
echo "✅ 제출용 패키지: $PKG"

# --- 5) 업로드 ---
if [ "$UPLOAD" = "0" ]; then
  echo
  echo "다음 단계(업로드): ./scripts/mas-release.sh $VERSION --upload"
  echo "또는 Xcode → Window → Organizer → 이 아카이브 선택 → Distribute App"
  exit 0
fi

if [ -z "${OMOS_ASC_API_KEY:-}" ] || [ -z "${OMOS_ASC_API_ISSUER:-}" ]; then
  echo
  echo "ℹ️ App Store Connect API 키가 설정되지 않아 CLI 업로드를 건너뜁니다."
  echo "   Xcode → Window → Organizer → 아카이브 선택 → Distribute App → App Store Connect"
  echo "   로 올리거나, API 키를 만들어 아래를 설정한 뒤 다시 실행하세요:"
  echo "     export OMOS_ASC_API_KEY=<Key ID>      # ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8"
  echo "     export OMOS_ASC_API_ISSUER=<Issuer ID>"
  exit 0
fi

echo "▸ 검증 (altool --validate-app)"
xcrun altool --validate-app -f "$PKG" -t macos \
  --apiKey "$OMOS_ASC_API_KEY" --apiIssuer "$OMOS_ASC_API_ISSUER"

echo "▸ 업로드 (altool --upload-app)"
xcrun altool --upload-app -f "$PKG" -t macos \
  --apiKey "$OMOS_ASC_API_KEY" --apiIssuer "$OMOS_ASC_API_ISSUER"

echo "✅ 업로드 완료: $VERSION (build $BUILD)"
echo "   App Store Connect 에서 처리(수 분)가 끝나면 심사 제출할 수 있습니다."
