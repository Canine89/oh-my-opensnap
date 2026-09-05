#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PREVIEW_ROOT="$(mktemp -d -t omos-store-preview)"
PREVIEW_APP="$PREVIEW_ROOT/StorePreview.app"
mkdir -p "$PREVIEW_APP/Contents/MacOS"
python3 - "$PREVIEW_APP" "$PREVIEW_ROOT" <<'PY'
from pathlib import Path
import plistlib, subprocess, sys
app, root = map(Path, sys.argv[1:])
sources = sorted(str(p) for p in Path('Sources').rglob('*.swift') if p.name not in ['main.swift', 'AppDelegate.swift'])
subprocess.run(['swiftc','-swift-version','5','-D','MAS','-D','DEBUG',*sources,
                'scripts/store-screenshots/main.swift','-o',str(app/'Contents/MacOS/StorePreview')],check=True)
with (app/'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier':'com.goldenrabbit.omopensnap.storepreview',
                  'CFBundleExecutable':'StorePreview','CFBundlePackageType':'APPL',
                  'CFBundleName':'Oh-my-opensnap','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','ko'],
                  'CFBundleShortVersionString':'1.0.91',
                  'CFBundleVersion':'92','LSUIElement':True},f)
with (root/'entitlements.plist').open('wb') as f:
    plistlib.dump({'com.apple.security.app-sandbox':True,
                  'com.apple.security.files.user-selected.read-write':True,
                  'com.apple.security.files.bookmarks.app-scope':True},f)
PY
codesign --force --options runtime --timestamp --sign "${OMOS_SIGN_IDENTITY:-Developer ID Application}" \
  --entitlements "$PREVIEW_ROOT/entitlements.plist" "$PREVIEW_APP"
for language in en ko; do
  open -n "$PREVIEW_APP" --stdout "$PREVIEW_ROOT/$language.log" --stderr "$PREVIEW_ROOT/$language-errors.log" --args -appLanguage "$language"
  python3 - "$PREVIEW_ROOT/$language.log" "$language" <<'PY'
from pathlib import Path
import subprocess,sys,time
log=Path(sys.argv[1])
window_id=None
for _ in range(100):
    lines=log.read_text().splitlines() if log.exists() else []
    values=[line.removeprefix('PREVIEW_WINDOW: ') for line in lines if line.startswith('PREVIEW_WINDOW: ')]
    if values:
        window_id=values[-1]
        break
    time.sleep(0.1)
if not window_id: sys.exit('스토어 화면 준비 실패: '+str(log))
destination=Path('app-store/screenshots')/sys.argv[2]/'library.png'
destination.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',window_id,str(destination)],check=True)
print(destination)
# 다음 언어와 QA 창이 겹치지 않도록 자체 종료를 기다린다.
for _ in range(150):
    if 'PREVIEW_PATH: ' in log.read_text(): break
    time.sleep(0.1)

PY
done
