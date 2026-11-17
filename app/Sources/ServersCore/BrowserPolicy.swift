// 앱 안 브라우저 탭 = "그 서버에 앉아 브라우저를 켠 것" (2026-11-17 사용자 결정 — 그 전에는 서버 IP·터널 주소 말고는 막았다).
// 탭의 모든 요청은 앱 안 SOCKS 중계(SocksRelay)를 거쳐 그 서버로 연 ssh -D 로 간다. 이름 풀이도 서버가 한다. 막는 주소는 없다.
// 루프백만 따로 다룬다: WebKit 은 127.0.0.0/8·localhost 를 프록시에 보내지 않고 이 Mac 으로 직접 붙는다
// (2026-11-17 가짜 SOCKS 로 확인 — 프록시 설정의 matchDomains·excludedDomains·allowFailover 를 바꿔도 같다. `foo.localhost` 같은 이름은 프록시로 간다).
// 그래서 루프백 주소는 프록시를 타는 별칭 이름(127-0-0-1.server.localhost)으로 바꿔 열고, 중계가 그 별칭을 서버의 루프백으로 연결한다.
// 주소창에는 입력한 주소 그대로 보인다. 별칭은 이 탭의 중계만 안다 — /etc/hosts·시스템 리졸버와 무관하다.
// 한계: 서버가 받는 Host 헤더는 별칭 이름이다. 페이지 안에 루프백 절대 주소로 박힌 하위 요청(이미지·스크립트)은 못 바꾼다(이 Mac 으로 간다).
// 이 파일은 그 판정과 주소 바꾸기만 (순수 함수, 테스트 대상). WebKit·중계는 앱 쪽.

import Foundation

public enum BrowserPolicy {
    /// 루프백 별칭의 꼬리. 앞은 원래 호스트의 점을 줄표로 (127.0.0.1 → 127-0-0-1.server.localhost, localhost → localhost.server.localhost)
    static let aliasSuffix = ".server.localhost"

    /// User-Agent 의 꼬리 — Safari 가 붙이는 것과 같은 꼴 ("Version/27.1 Safari/605.1.15").
    /// WebKit 기본값은 "… AppleWebKit/605.1.15 (KHTML, like Gecko)" 에서 끝나 브라우저 이름이 없다 — 구글이 모르는 브라우저로 보고 옛 기본 HTML 판을 내줬다 (2026-11-17).
    /// Safari 버전은 macOS 버전을 따라간다 (26 부터). 605.1.15 는 Safari 가 고정해 쓰는 값.
    public static func userAgentSuffix(osMajor: Int, osMinor: Int) -> String {
        "Version/\(osMajor).\(osMinor) Safari/605.1.15"
    }

    /// 127.0.0.0/8·localhost 인가. IPv6 루프백(::1)은 다루지 않는다 (별칭으로 바꾸지 않고 그대로 둔다).
    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil }
    }

    /// 루프백 호스트 → 별칭. 루프백이 아니면 nil.
    public static func alias(forLoopback host: String) -> String? {
        guard isLoopback(host) else { return nil }
        return host.lowercased().replacingOccurrences(of: ".", with: "-") + aliasSuffix
    }

    /// 별칭 → 원래 루프백 호스트 (127.0.0.1 · localhost). 별칭이 아니면 nil.
    public static func loopback(fromAlias host: String) -> String? {
        let h = host.lowercased()
        guard h.hasSuffix(aliasSuffix) else { return nil }
        let original = h.dropLast(aliasSuffix.count).replacingOccurrences(of: "-", with: ".")
        return isLoopback(original) ? original : nil
    }

    /// 웹 주소(http·https·ws·wss)인가 — 별칭 바꾸기는 이 스킴에만 한다
    public static func isWeb(_ url: URL) -> Bool {
        ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? "")
    }

    /// 탭이 열 수 있는 주소인가: 웹 주소와 페이지 내부용(about·data·blob). file: 같은 이 Mac 의 것은 열지 않는다.
    public static func isOpenable(_ url: URL) -> Bool {
        isWeb(url) || ["about", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
    }

    /// 실제로 열 주소: 루프백 호스트면 별칭으로 바꾼 것 (포트·경로·질의는 그대로). 바꿀 것이 없으면 그대로.
    public static func proxied(_ url: URL) -> URL {
        guard isWeb(url), let host = url.host, let alias = alias(forLoopback: host) else { return url }
        return replacingHost(of: url, with: alias)
    }

    /// 주소창에 보일 주소: 별칭이면 원래 루프백 주소로 되돌린 것.
    public static func displayed(_ url: URL) -> URL {
        guard isWeb(url), let host = url.host, let original = loopback(fromAlias: host) else { return url }
        return replacingHost(of: url, with: original)
    }

    private static func replacingHost(of url: URL, with host: String) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = host
        return parts.url ?? url
    }

    /// SOCKS 중계의 판정: 별칭이면 서버 쪽에서 그 루프백 주소로, 나머지는 받은 그대로 서버로 넘긴다 (ssh -D 가 서버에서 연결한다).
    public static func route(host: String, port: Int) -> SocksRoute {
        if let original = loopback(fromAlias: host) { return .upstreamTo(host: original == "localhost" ? "127.0.0.1" : original) }
        return .upstream
    }
}
