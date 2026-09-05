#!/usr/bin/env python3
"""업로드 전 실제 PKG의 서명, 샌드박스, 프로필, 개인정보 리소스를 검증한다."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def verify(app: Path, bundle_id: str, team: str):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    assert info['CFBundleIdentifier'] == bundle_id, '번들 ID 불일치'
    assert info['LSApplicationCategoryType'] == 'public.app-category.productivity'
    assert not any(key.startswith('SU') for key in info), '스토어판에 자동 업데이트 설정이 포함됨'
    assert not list(app.rglob('Sparkle.framework')), 'Sparkle 포함'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True, check=True).stderr
    assert 'Authority=Apple Distribution:' in signature, 'App Store 배포 인증서가 아님'
    assert f'TeamIdentifier={team}' in signature, '서명 팀 불일치'
    entitlement = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL)
    rights = plistlib.loads(entitlement)
    assert rights.get('com.apple.security.app-sandbox') is True
    assert rights.get('com.apple.security.files.user-selected.read-write') is True
    assert rights.get('com.apple.security.files.bookmarks.app-scope') is True
    assert not rights.get('com.apple.security.get-task-allow', False)
    assert not rights.get('com.apple.security.network.client', False)
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(app/'Contents/embedded.provisionprofile')], stderr=subprocess.DEVNULL))
    assert profile['Entitlements']['com.apple.application-identifier'] == team + '.' + bundle_id
    with (app/'Contents/Resources/PrivacyInfo.xcprivacy').open('rb') as stream:
        privacy = plistlib.load(stream)
    assert privacy['NSPrivacyTracking'] is False
    assert privacy['NSPrivacyCollectedDataTypes'] == []
    reasons = {item['NSPrivacyAccessedAPIType']: set(item['NSPrivacyAccessedAPITypeReasons']) for item in privacy['NSPrivacyAccessedAPITypes']}
    assert reasons['NSPrivacyAccessedAPICategoryUserDefaults'] == {'CA92.1'}
    assert reasons['NSPrivacyAccessedAPICategoryFileTimestamp'] == {'C617.1', '3B52.1'}
    return {'bundleID': bundle_id, 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'distributionSignature': True, 'sandbox': True, 'privacyManifest': True, 'sparkle': False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('package', type=Path)
    parser.add_argument('--bundle-id', default='com.goldenrabbit.omopensnap.mas')
    parser.add_argument('--team', default='M7NU9F8CZN')
    args = parser.parse_args()
    result = subprocess.run(['pkgutil', '--check-signature', str(args.package)], check=True, capture_output=True, text=True)
    assert '3rd Party Mac Developer Installer:' in result.stdout, 'Mac App Store 설치 인증서가 아님'
    with tempfile.TemporaryDirectory(prefix='omos-mas-verify-') as directory:
        expanded = Path(directory)/'expanded'
        subprocess.run(['pkgutil', '--expand-full', str(args.package), str(expanded)], check=True)
        apps = [p for p in expanded.rglob('*.app') if (p/'Contents/Info.plist').is_file()]
        assert len(apps) == 1, '패키지 앱 수가 예상과 다름'
        print(json.dumps(verify(apps[0], args.bundle_id, args.team), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
