# Mac App Store 출시 검증

## 자동 검증

```bash
./scripts/check.sh
./scripts/mas-smoke.sh
./scripts/store-screenshots.sh
./scripts/mas-release.sh 1.0.91
python3 scripts/verify-mas-package.py build/mas-export/Oh-my-opensnap.pkg
```

`check.sh`는 일반 회귀 테스트와 두 배포 타깃 빌드를 실행합니다. 단위 테스트 결과만으로 샌드박스 검증을 대신하지 않습니다.

`mas-smoke.sh`는 별도 번들 ID의 검증 앱을 Developer ID로 서명하고 실제 App Sandbox를 켜 실행합니다. 운영 앱의 저장소와 권한을 변경하지 않으며, 다음을 확인합니다.

- 컨테이너 내부 이미지·주석 저장 및 읽기
- macOS 파일 조정을 이용한 파일 생성·덮어쓰기·복사
- 허용하지 않은 외부 경로 쓰기 차단
- 1만 개 파일의 실제 라이브러리 목록 읽기와 정렬 소요 시간

이 검증은 화면 녹화 권한이나 사용자가 저장 패널로 부여한 권한을 자동으로 만들지 않습니다. 외부 폴더와 실제 화면 녹화는 아래 수동 검증이 추가로 필요합니다.

`store-screenshots.sh`는 예제 이미지와 주석만 들어 있는 별도 샌드박스에서 실제 라이브러리 UI를 실행하고 해당 창만 캡처합니다. 개인 캡처는 읽지 않습니다. 호스트의 창 캡처 권한이 없으면 실패하며, 실패한 이미지를 제출용으로 사용하지 않습니다.

`verify-mas-package.py`는 PKG를 풀어 실제 제출 앱의 Apple Distribution 서명, 설치 인증서, 번들 ID, 프로비저닝 프로필, 샌드박스 권한, 개인정보 매니페스트, Sparkle 제외를 확인합니다. Developer ID 공증은 App Store 배포 서명·심사를 대체하지 않습니다.

## TestFlight 확인표

각 결과에 테스트한 Mac·macOS 버전·날짜와 재현 기록을 남깁니다. 검증하지 않은 항목은 통과로 표기하지 않습니다.

| 항목 | 상태 |
|---|---|
| 개발 환경이 없는 다른 Mac에서 첫 실행과 메뉴 막대 안내 | 대기 |
| 화면 녹화 권한 거부 → 허용 → 철회 → 재허용 | 대기 |
| 저장 패널로 고른 외부 파일의 최초 저장·덮어쓰기 | 대기 |
| 외부 폴더 선택 후 앱 재시작·북마크 복원 | 대기 |
| 외장 디스크 분리·재연결 중 저장 실패와 다른 폴더 복구 | 대기 |
| 서로 다른 Retina 배율의 다중 모니터 캡처 | 대기 |
| 30분 이상 녹화·일시정지·재개·중지 | 대기 |
| 캡처·내보내기·저장 도중 앱 종료 | 대기 |
| 기존 스토어판에서 업데이트 후 파일·설정·주석 유지 | 대기 |
| VoiceOver 및 키보드만으로 기본 조작 | 대기 |

공식 참고: [파일 접근](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [API 사용 사유](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons), [TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview).

## 로컬 검증 기록 (2026-09-05)

- 실제 샌드박스 실행: 컨테이너 저장·덮어쓰기·내보내기 성공, 허용하지 않은 외부 파일 쓰기 차단 확인.
- 1만 개 파일의 라이브러리 메타데이터 읽기·정렬: 이 Mac에서 약 0.32초. 이미지 1만 장을 동시에 디코딩한 측정은 아니다.
- 1.0.91 (92) 제출용 PKG: Apple Distribution 및 Mac Installer 서명, 스토어 프로비저닝 프로필, 샌드박스, 개인정보 매니페스트 포함 검증 통과. Intel·Apple Silicon 공용 바이너리.
- 한국어·영어 라이브러리 화면: 별도 샌드박스의 예제 데이터로 실제 창을 캡처. 각 2880×1800 PNG.
- TestFlight 업로드·다른 Mac의 실제 사용 검증: 아직 완료되지 않았다.

## App Store Connect 인증

개인키를 저장소에 넣지 않는다. 이 Mac의 `~/.appstoreconnect/private_keys/AuthKey_<키ID>.p8`를 사용한다. 발급자 ID를 확인한 후 아래 환경변수를 설정한다.

```bash
export OMOS_ASC_API_KEY='<키 ID>'
export OMOS_ASC_API_ISSUER='<Issuer ID>'
node scripts/app-store-connect.mjs inspect
```

또는 `~/.appstoreconnect/oh-my-opensnap.json`에 비밀키가 아닌 `keyId`, `issuerId`만 저장할 수 있다. API 키 업로드는 배포 스크립트의 `--upload`를 사용하고, 그 뒤 `node scripts/app-store-connect.mjs wait-build 1.0.91 92`로 Apple의 처리 완료를 확인한다. Xcode에 App Store Connect 접근 권한이 있는 계정으로 로그인되어 있으면 `./scripts/mas-release.sh 1.0.91 --upload-xcode`로 API 키 없이 업로드할 수도 있다. 검사 도구는 정식 심사 제출이나 테스터 초대를 자동으로 수행하지 않는다.
