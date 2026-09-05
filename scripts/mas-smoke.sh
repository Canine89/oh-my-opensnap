#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SMOKE_ROOT="$(mktemp -d -t omos-mas-smoke)"
SMOKE_APP="$SMOKE_ROOT/StoreValidation.app"
mkdir -p "$SMOKE_APP/Contents/MacOS"
swiftc -swift-version 5 Sources/Library/LibraryFileStore.swift \
  Sources/Library/CoordinatedFileExporter.swift Sources/Library/LibraryCatalog.swift \
  scripts/mas-smoke/main.swift -o "$SMOKE_APP/Contents/MacOS/StoreValidation"
python3 - "$SMOKE_APP" "$SMOKE_ROOT" <<'PY'
import plistlib
from pathlib import Path
import sys
app, root = map(Path, sys.argv[1:])
with (app/'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier':'com.goldenrabbit.omopensnap.validation',
                  'CFBundleExecutable':'StoreValidation','CFBundlePackageType':'APPL',
                  'CFBundleName':'StoreValidation','LSUIElement':True}, f)
with (root/'entitlements.plist').open('wb') as f:
    plistlib.dump({'com.apple.security.app-sandbox':True,
                  'com.apple.security.files.user-selected.read-write':True,
                  'com.apple.security.files.bookmarks.app-scope':True}, f)
PY
codesign --force --options runtime --timestamp --sign "${OMOS_SIGN_IDENTITY:-Developer ID Application}" \
  --entitlements "$SMOKE_ROOT/entitlements.plist" "$SMOKE_APP"
open -W -n "$SMOKE_APP" --stdout "$SMOKE_ROOT/report.log" --stderr "$SMOKE_ROOT/stderr.log"
python3 - "$SMOKE_ROOT" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
output=(root/'report.log').read_text()
print(output)
reports=[json.loads(line) for line in output.splitlines() if line.startswith('{')]
if not reports or not reports[-1].get('sandbox'):
    sys.exit('샌드박스 실행 검증 실패: '+str(root))
print('검증 기록:', root)
PY
