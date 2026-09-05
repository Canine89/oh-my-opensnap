# App Review 제출 메모

아래 영어 본문은 심사 메모와 TestFlight 테스트 안내로 사용할 수 있습니다. 계정 로그인이 없는 앱이므로 데모 계정은 필요하지 않습니다.

## Review instructions

Oh-my-opensnap is a sandboxed macOS menu bar utility for screen captures, annotations, and screen video recordings.

1. Launch the app and look for its camera icon in the macOS menu bar. It intentionally does not appear in the Dock. The welcome popover explains where to find it.
2. Press Command-Shift-2, or choose Capture from the menu bar.
3. On the first capture, grant Screen & System Audio Recording permission in System Settings. Return to the app; if macOS requests a relaunch, quit and open the app again. Denying permission leaves the app usable for settings and existing library items.
4. Drag to select an area, or click a window. Press Return for an image capture or R for screen recording. Escape cancels the selection.
5. An image capture is copied to the clipboard and saved in the app’s local library. In the Library, add numbered markers, text, arrows, callouts, shapes, or mosaic effects. Crop and undo/redo are available.
6. During recording, the menu bar and recording HUD show the active recording and provide pause/resume/stop. Recording currently has no audio track. Use the Library’s Export menu to save a selected range as MP4 or GIF.
7. In Settings → Storage, choose another folder if desired. The app stores a security-scoped bookmark for future access. Exported files use the standard macOS save panel.
8. If saving fails, the app offers retry, saving recoverable copies to another folder, continued editing, or confirmed discard of unsaved changes.

The Mac App Store build does not request Accessibility permission and does not include Sparkle or another self-updater. Window content boundaries are estimated in this build; users can manually adjust the selection.

No account, subscription, advertising, analytics, or cloud upload is included. Captures, annotations, preferences, and recovery records stay on the Mac. The app’s privacy policy is accessible from Settings → About.

Support: hgpark@goldenrabbit.co.kr

## 제출 전에 App Store Connect에서 확인할 항목

- 번들 ID: `com.goldenrabbit.omopensnap.mas`, 버전 `1.0.91`, 빌드 `92`.
- 기존 앱 레코드와 계약·세금·은행 상태, 가격과 배포 지역은 계정에 설정된 값을 확인한다.
- 개인정보 답변은 앱 자체의 수집·추적 없음과 일치하게 설정한다. Apple 플랫폼이 처리하는 TestFlight 피드백과 앱 자체 데이터 수집을 혼동하지 않는다.
- 연령 등급 질문에 실제 기능으로 답한다. 앱은 공개 콘텐츠 피드, 계정 기반 사용자 커뮤니티, 웹 브라우저 기능을 제공하지 않는다.
- 심사 연락처의 이름·전화번호는 계정 소유자가 확인한 기존 정보를 사용한다.
- `metadata.json`의 소개·키워드·지원 URL 및 언어별 실제 앱 화면을 적용한다.
- TestFlight에서 실제 사용자 검증 결과를 확인한 뒤 정식 심사에 제출한다.
