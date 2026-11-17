// 앱 상태 폴더: ~/Library/Application Support/Servers (저장소 밖).
// servers.conf · passwords.bin · identities.json · recent.json · hosts.json · lan.json · snippets.json 이 여기 있다.

import Foundation

enum AppSupport {
    static var baseURL: URL {
        // 데모(`--demo`)는 임시 폴더 — 실제 상태 파일을 읽지도 쓰지도 않는다 (DemoMode)
        if DemoMode.active { return DemoMode.directory }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Servers")
    }
}
