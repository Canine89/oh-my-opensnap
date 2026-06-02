import AppKit

// 메뉴바 상주(accessory) 앱. 스토리보드 없이 코드로 부트스트랩한다.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
