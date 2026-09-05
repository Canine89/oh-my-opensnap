# Oh-my-opensnap 개인정보 처리방침 (Privacy Policy)

최종 수정 / Effective date: 2026-09-05

## 요약 (한국어)

Oh-my-opensnap은 **어떤 개인정보도 수집하지 않습니다.**

- **데이터 수집 없음** — 사용자 계정, 이름, 이메일, 위치, 사용 통계, 광고 식별자 등 어떤 데이터도 수집·전송하지 않습니다. 분석(analytics)·광고 SDK를 포함하지 않습니다.
- **캡처 결과는 기기에만 저장** — 캡처 이미지·영상·주석은 모두 사용자의 Mac 로컬 저장소와 클립보드에만 저장되며, 외부로 전송되지 않습니다. 파일 공유는 사용자가 직접 내보내기·복사·드래그할 때만 일어납니다.
- **화면 녹화 권한** — macOS 화면 녹화 권한은 사용자가 직접 실행한 캡처에만 사용됩니다. 권한은 시스템 설정에서 언제든 철회할 수 있습니다.
- **네트워크 통신** — Mac App Store 버전은 네트워크 통신을 하지 않습니다. (GitHub 배포 버전에 한해 앱 업데이트 확인 목적으로 GitHub의 업데이트 정보 파일을 조회하며, 개인정보는 전송되지 않습니다.)

- **저장 실패와 복구** — 저장에 실패한 최신 이미지와 주석은 재시도를 위해 메모리에 보관합니다. 사용자는 다시 시도하거나 다른 폴더에 복구본을 저장하거나, 확인 후 저장하지 않은 변경 내용을 버릴 수 있습니다. 이미지·주석을 함께 저장하는 동안에는 이전 상태의 로컬 복구 기록을 만들고, 저장 완료 후 삭제합니다.
- **휴지통과 주석** — 캡처를 휴지통으로 옮겨도 원본 위치·이름으로 복원할 때 편집을 되살릴 수 있도록 주석 파일은 저장 폴더의 `.annotations`에 남습니다. 주석까지 완전히 삭제하려면 해당 로컬 주석 파일도 삭제할 수 있습니다.
- **설정과 파일 정보** — 앱 자체 설정과 접근 권한 북마크를 기기에 저장합니다. 라이브러리를 날짜별로 표시하기 위해 앱 저장소 또는 사용자가 선택한 파일·폴더의 생성·수정 시간을 읽으며 외부로 전송하지 않습니다.

문의: hgpark@goldenrabbit.co.kr 또는 https://github.com/Canine89/oh-my-opensnap/issues

---

## Privacy Policy (English)

Oh-my-opensnap is a macOS screen capture and recording application developed by Golden Rabbit.

### Data collection

Oh-my-opensnap does not collect, transmit, sell, or share personal data. It does not use analytics, advertising SDKs, tracking technologies, accounts, or remote servers.

### Screens, recordings, and files

The app needs the macOS Screen & System Audio Recording permission so that it can capture the screen areas you choose. Captured images, recordings, and the app's preferences are stored locally on your Mac. You choose where files are saved and may delete them at any time.

The app does not upload your screen captures or recordings. Any sharing of a file happens only when you explicitly export, copy, drag, or otherwise share it using macOS.

### Recovery and retention

When a save fails, the latest image and annotations remain in memory for retry. You may retry, save recoverable copies to another folder, or explicitly discard unsaved changes. During a combined image-and-annotation save, the app writes a local recovery record containing the previous state, then removes it after a successful save.

Moving a capture to the Trash retains its annotation file in the library’s local `.annotations` folder so edits can be restored if the capture is returned to its original name and location. You can also delete these local annotation files to remove them permanently.

App preferences and folder access bookmarks stay on your Mac. File creation and modification times are read for date-based library organization and are not transmitted.

### Network

The Mac App Store version performs no network communication. The GitHub-distributed version only checks a GitHub-hosted file for app updates; no personal data is sent.

### Permissions

- **Screen & System Audio Recording:** used only to capture the screen region you select.
- **User-selected file access:** used only for folders and files you select for saving, opening, exporting, or managing captures.

You can revoke permissions at any time in macOS System Settings.

### Children's privacy

Oh-my-opensnap is not directed to children and does not collect personal information from anyone.

### Changes to this policy

If this policy changes, the updated version will be posted in this repository with a new effective date.

### Contact

For questions or support, email hgpark@goldenrabbit.co.kr or open an issue at:
https://github.com/Canine89/oh-my-opensnap/issues
