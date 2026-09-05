#!/usr/bin/env bash
# 배포 스크립트와 모의 도구 테스트가 공유하는 검증 함수.

validate_release_options() {
  local version="$1" publish="$2" skip_notary="$3"
  if [[ -n "$version" && ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ 버전은 숫자.숫자.숫자 형식이어야 합니다." >&2
    return 1
  fi
  if [[ "$publish" = 1 && ( "$skip_notary" = 1 || -z "$version" ) ]]; then
    echo "✗ 게시는 명시한 버전과 Apple 공증이 필요합니다." >&2
    return 1
  fi
}

require_clean_release_tree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ 게시 전 소스 변경을 커밋하고 작업 트리를 정리하세요." >&2
    return 1
  fi
}

require_notarization_history() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    history = json.load(source).get("history", [])
if not any(item.get("id") == sys.argv[2] and item.get("status") == "Accepted" for item in history):
    sys.exit("✗ 공증 이력에서 해당 제출의 Accepted 상태를 확인하지 못했습니다.")
PY
}

require_accepted_notarization() {
  python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get("status") != "Accepted" or not result.get("id"):
    sys.exit("✗ Apple 공증 결과가 Accepted가 아닙니다.")
print(result["id"])
PY
}

verify_notarized_artifacts() {
  local app="$1" dmg="$2" verdict
  codesign --verify --deep --strict "$app" || return 1
  codesign --verify --strict "$dmg" || return 1
  xcrun stapler validate "$app" || return 1
  xcrun stapler validate "$dmg" || return 1
  verdict=$(spctl -a -vv "$app" 2>&1) || { echo "$verdict" >&2; return 1; }
  echo "$verdict"
  [[ "$verdict" == *"accepted"* && "$verdict" == *"source=Notarized Developer ID"* ]] || return 1
  verdict=$(spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1) || { echo "$verdict" >&2; return 1; }
  echo "$verdict"
  [[ "$verdict" == *"accepted"* && "$verdict" == *"source=Notarized Developer ID"* ]]
}
