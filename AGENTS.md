# AGENTS.md instructions

항상 한글로만 답해.

## macOS 앱 배포/공증 기본 원칙

사용자가 macOS 앱을 GitHub Releases 등으로 배포하려고 하면, 기본적으로 Apple Developer ID 서명과 Apple 공증까지 완료된 DMG를 만드는 방향으로 처리한다.

공증 배포의 표준 흐름:

1. Release 빌드
2. `.app` 내부의 중첩 코드부터 바깥쪽 순서로 Developer ID Application 인증서 서명
3. 앱 본체 서명 시 hardened runtime 사용
4. DMG 생성
5. DMG 파일 자체도 Developer ID Application 인증서로 서명
6. `notarytool submit --wait`로 DMG 공증 제출
7. 공증 Accepted 후 DMG와 `.app`에 `stapler staple`
8. `stapler validate`, `spctl`로 최종 검증

기본 인증서/프로필 관례:

- 코드서명 인증서: `Developer ID Application`
- notarytool 키체인 프로필 기본 이름: `oh-my-opensnap`
- 프로젝트에서 다른 프로필명을 쓰면 환경변수로 받게 한다. 예: `OMOS_NOTARY_PROFILE`

대표 명령:

```bash
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile oh-my-opensnap
codesign --force --options runtime --timestamp --sign "Developer ID Application: <Name> (<TEAMID>)" MyApp.app
codesign --force --timestamp --sign "Developer ID Application: <Name> (<TEAMID>)" MyApp.dmg
xcrun notarytool submit MyApp.dmg --keychain-profile oh-my-opensnap --wait
xcrun stapler staple MyApp.dmg
xcrun stapler staple MyApp.app
xcrun stapler validate MyApp.dmg
xcrun stapler validate MyApp.app
spctl -a -vv MyApp.app
spctl -a -vv -t open --context context:primary-signature MyApp.dmg
```

검증 기준:

- `.app`는 `spctl -a -vv MyApp.app`에서 `accepted` 및 `source=Notarized Developer ID`가 나와야 한다.
- `.dmg`는 `spctl -a -vv -t open --context context:primary-signature MyApp.dmg`에서 `accepted` 및 `source=Notarized Developer ID`가 나와야 한다.
- `notarytool history`에서 해당 제출이 `Accepted`여야 한다.

주의:

- Apple Development 인증서는 로컬 개발용이고 일반 사용자 배포 공증용이 아니다.
- Developer ID Application 인증서와 Apple Developer Program 멤버십이 필요하다.
- 공증은 로컬 빌드보다 Apple notary 서버 대기 시간이 걸릴 수 있다.
- DMG 안의 `.app`만 공증하고 DMG 자체를 서명하지 않으면 DMG 검사에서 `no usable signature`가 날 수 있으므로 DMG도 서명한다.
- Sparkle, XPC, helper app, framework 같은 중첩 코드는 가능하면 inside-out 순서로 서명한다. 무조건 `codesign --deep`에 의존하지 않는다.
