# Oh-my-opensnap 개인정보 처리방침 (Privacy Policy)

최종 수정 / Effective date: 2026-09-05

## 요약 (한국어)

Oh-my-opensnap은 **캡처 자료를 기기에 보관하며, 분석·광고 목적으로 개인정보를 수집하지 않습니다.**

- **데이터 수집 없음** — 앱 내 사용자 계정이 없으며, 캡처 자료나 사용 통계를 외부에 업로드하지 않습니다. 분석(analytics)·광고 SDK를 포함하지 않습니다.
- **캡처 결과는 기기에만 저장** — 캡처 이미지·영상·주석은 모두 사용자의 Mac 로컬 저장소와 클립보드에만 저장되며, 외부로 전송되지 않습니다. 파일 공유는 사용자가 직접 내보내기·복사·드래그할 때만 일어납니다.
- **화면 녹화 권한** — macOS 화면 녹화 권한은 사용자가 직접 실행한 캡처에만 사용됩니다. 권한은 시스템 설정에서 언제든 철회할 수 있습니다.
- **네트워크 통신** — Sparkle을 통해 GitHub의 업데이트 정보를 조회하고 새 버전 파일을 다운로드합니다. 캡처 이미지·영상·주석은 이 통신에 포함되지 않습니다. 서버에는 IP 주소 등 통신에 필요한 접속 정보가 전달될 수 있습니다.

- **저장 실패와 복구** — 저장에 실패한 최신 이미지와 주석은 재시도를 위해 메모리에 보관합니다. 사용자는 다시 시도하거나 다른 폴더에 복구본을 저장하거나, 확인 후 저장하지 않은 변경 내용을 버릴 수 있습니다. 이미지·주석을 함께 저장하는 동안에는 이전 상태의 로컬 복구 기록을 만들고, 저장 완료 후 삭제합니다.
- **휴지통과 주석** — 캡처를 휴지통으로 옮겨도 원본 위치·이름으로 복원할 때 편집을 되살릴 수 있도록 주석 파일은 저장 폴더의 `.annotations`에 남습니다. 주석까지 완전히 삭제하려면 해당 로컬 주석 파일도 삭제할 수 있습니다.
- **설정과 파일 정보** — 앱 자체 설정과 저장 폴더 경로를 기기에 저장합니다. 라이브러리를 날짜별로 표시하기 위해 앱 저장소 또는 사용자가 선택한 파일·폴더의 생성·수정 시간을 읽으며 외부로 전송하지 않습니다.

문의: hgpark@goldenrabbit.co.kr 또는 https://github.com/Canine89/oh-my-opensnap/issues

---

## Privacy Policy (English)

Oh-my-opensnap is a macOS screen capture and recording application developed by Golden Rabbit.

### Data collection

Oh-my-opensnap does not upload screen captures, annotations, or usage analytics. It does not use analytics or advertising SDKs, tracking technologies, or app accounts.

### Screens, recordings, and files

The app needs the macOS Screen & System Audio Recording permission so that it can capture the screen areas you choose. Captured images, recordings, and the app's preferences are stored locally on your Mac. You choose where files are saved and may delete them at any time.

The app does not upload your screen captures or recordings. Any sharing of a file happens only when you explicitly export, copy, drag, or otherwise share it using macOS.

### Recovery and retention

When a save fails, the latest image and annotations remain in memory for retry. You may retry, save recoverable copies to another folder, or explicitly discard unsaved changes. During a combined image-and-annotation save, the app writes a local recovery record containing the previous state, then removes it after a successful save.

Moving a capture to the Trash retains its annotation file in the library’s local `.annotations` folder so edits can be restored if the capture is returned to its original name and location. You can also delete these local annotation files to remove them permanently.

App preferences and storage folder paths stay on your Mac. File creation and modification times are read for date-based library organization and are not transmitted.

### Network

Sparkle checks update information hosted on GitHub and downloads new app versions. These requests do not include your captures or annotations. Update servers may receive connection information such as your IP address as part of normal network communication.

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
