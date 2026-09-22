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

# 게시 전 작업 트리 검사. 버전을 주면 같은 버전의 로컬 실행(`release.sh X`)이 남긴 산출물
# (appcast.xml · Cask · updates ZIP · project.yml 의 버전 두 줄)만은 허용한다 — 게시 실행이 다시 만든다.
require_clean_release_tree() {
  local version="${1:-}" line path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path="${line:3}"
    if [[ -n "$version" ]] && is_release_generated_change "$version" "$path"; then
      continue
    fi
    echo "✗ 게시 전 소스 변경을 커밋하고 작업 트리를 정리하세요: $path" >&2
    return 1
  done < <(git status --porcelain)
}

is_release_generated_change() {
  local version="$1" path="$2"
  case "$path" in
    appcast.xml|Casks/oh-my-opensnap.rb|"updates/oh-my-opensnap-$version.zip") return 0 ;;
    project.yml)
      [[ "$(project_marketing_version project.yml)" == "$version" ]] || return 1
      # 버전 두 줄 말고 다른 변경이 섞여 있으면 릴리스 커밋에 딸려 가지 않게 거부한다.
      ! git diff -U0 HEAD -- project.yml \
        | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' \
        | grep -qvE '^[-+][[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION):'
      ;;
    *) return 1 ;;
  esac
}

project_marketing_version() {
  grep 'MARKETING_VERSION:' "$1" | grep -oE '"[^"]*"' | tr -d '"' | head -1
}

# 숫자.숫자.숫자 비교 → -1 / 0 / 1 출력.
version_compare() {
  local IFS=.
  local -a left=($1) right=($2)
  local i x y
  for i in 0 1 2; do
    x=$((10#${left[i]:-0}))
    y=$((10#${right[i]:-0}))
    if (( x < y )); then echo -1; return 0; fi
    if (( x > y )); then echo 1; return 0; fi
  done
  echo 0
}

# 현재 버전보다 낮은 버전(예: 1.0.94 → 1.0.9 오타)은 거부한다. 같은 버전은 재실행/재개용으로 허용.
require_version_not_lower() {
  local requested="$1" current="$2"
  [[ -n "$current" ]] || return 0
  if [[ "$(version_compare "$requested" "$current")" == -1 ]]; then
    echo "✗ 요청 버전 $requested 이(가) 현재 버전 $current 보다 낮습니다. 버전을 확인하세요." >&2
    return 1
  fi
}

# 커밋(ref)에 경로가 있는지 — 업데이트 ZIP이 이미 커밋/게시됐는지 확인하는 데 쓴다.
git_has_path() {
  git cat-file -e "$1:$2" 2>/dev/null
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
