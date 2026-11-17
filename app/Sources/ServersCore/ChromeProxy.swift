// Chrome 프록시 모드 실행 인자. 서버로 연 SOCKS 터널(ssh -D)을 Chrome 이 쓰게 한다.
// 별도 프로필(--user-data-dir)이 필수: 이미 떠 있는 Chrome 에 --proxy-server 를 주면 무시되고 기존 창만 앞으로 온다.

import Foundation

public enum ChromeProxy {
    public static let bundleID = "com.google.Chrome"

    /// 프로필 디렉터리: 서버별로 따로 (~/Library/Application Support/Servers/chrome-proxy/<서버키>). 처음엔 빈 프로필이고 그 뒤로 유지된다.
    public static func profileDir(serverKey: String, base: URL = HostAliasStore.defaultURL.deletingLastPathComponent()) -> URL {
        base.appendingPathComponent("chrome-proxy").appendingPathComponent(serverKey)
    }

    /// --proxy-server: SOCKS5 로 전부 내보낸다. socks5:// 스킴은 호스트 이름을 프록시에 그대로 넘겨 이름 풀이도 서버 쪽에서 한다 (socks4 는 로컬).
    ///   --host-resolver-rules 로 로컬 DNS 를 아예 막는 방법도 있지만 Chrome 이 "지원되지 않는 플래그" 배너를 매번 띄워 쓰지 않는다.
    /// --no-first-run·--no-default-browser-check: 새 프로필의 환영 화면·기본 브라우저 물음을 끈다.
    public static func arguments(proxyPort: Int, profileDir: String) -> [String] {
        [
            "--proxy-server=socks5://127.0.0.1:\(proxyPort)",
            "--user-data-dir=\(profileDir)",
            "--no-first-run",
            "--no-default-browser-check",
        ]
    }
}
