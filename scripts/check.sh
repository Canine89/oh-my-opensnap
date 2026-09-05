#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DD="${OMOS_CHECK_DERIVED_DATA:-$PWD/build/check}"
command -v xcodegen >/dev/null || { echo "xcodegen 설치가 필요합니다." >&2; exit 1; }
xcodegen generate
python3 -m unittest discover -s Tests -p 'test_*.py' -v
for script in scripts/*.sh; do bash -n "$script"; done
node --check scripts/app-store-connect.mjs
xcodebuild -project oh-my-opensnap.xcodeproj -scheme RegressionTests \
  -destination 'platform=macOS' -derivedDataPath "$CHECK_DD" \
  test CODE_SIGNING_ALLOWED=NO
xcodebuild -project oh-my-opensnap.xcodeproj -scheme RegressionTests \
  -destination 'platform=macOS' -derivedDataPath "$CHECK_DD" \
  test CODE_SIGNING_ALLOWED=NO 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MAS'
for scheme in oh-my-opensnap oh-my-opensnap-mas; do
  xcodebuild -project oh-my-opensnap.xcodeproj -scheme "$scheme" \
    -configuration Release -derivedDataPath "$CHECK_DD" \
    build CODE_SIGNING_ALLOWED=NO
done
