// 앱 안 브라우저 탭의 통신 범위. 탭의 모든 요청은 앱 안 SOCKS 중계(SocksRelay)로 오고, 중계가 route 로 갈 곳을 정한다:
//   서버 IP(포트 무관)              → 그 서버로 연 ssh -D(내부망 장치에 묶임)로 전달
//   루프백(127.0.0.0/8·localhost)  → 이 Mac 의 터널 리스너로 직접
//   그 서버의 터널 hosts 이름         → 그 이름의 루프백 주소로 직접 (jenkins.acme → 127.0.0.2). 시스템 리졸버를 안 거치니 Safari 가 못 풀던 이름도 된다
//   그 밖(다른 내부 서버·인터넷)      → 거절
// WebKit 쪽에서도 두 겹으로 막는다: 페이지 이동은 내비게이션 정책으로, 페이지 안의 하위 요청(스크립트·CSS·이미지·웹소켓)은 콘텐츠 규칙으로.
// 이 파일은 그 판정과 규칙 생성만 (순수 함수, 테스트 대상). WebKit·중계는 앱 쪽.

import Foundation

public struct BrowserScope: Sendable, Equatable {
    /// 그 서버 IP — SOCKS 를 거쳐 가는 유일한 호스트
    public let serverIP: String
    /// 그 서버의 서버 이름 터널: hosts 이름(소문자) → 루프백 주소 (jenkins.acme → 127.0.0.2)
    public let loopbackNameAddresses: [String: String]

    public init(serverIP: String, loopbackNameAddresses: [String: String] = [:]) {
        self.serverIP = serverIP
        // 대소문자만 다른 이름 둘이 와도 죽지 않게 (uniqueKeysWithValues 는 겹치면 크래시) — 하나만 남긴다
        self.loopbackNameAddresses = Dictionary(loopbackNameAddresses.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    public var loopbackNames: Set<String> { Set(loopbackNameAddresses.keys) }
}

public enum BrowserPolicy {
    /// 127.0.0.0/8 인가. IPv6 루프백(::1)은 받지 않는다 — 터널 리스너는 127.0.0.x 뿐이고, 중계(SocksRelay)가 IPv6 주소를
    /// "0:0:0:0:0:0:0:1" 꼴로 넘겨 어차피 거절돼, 페이지 이동만 허용되고 연결은 막히는 어긋남이 있었다.
    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil }
    }

    /// 이 URL 로 가도 되는가. data:·blob:·about: 는 페이지 내부용이라 허용. http(s)·ws(s) 는 호스트가 서버 IP·루프백·루프백 이름이어야 한다.
    public static func isAllowed(_ url: URL, scope: BrowserScope) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if ["about", "data", "blob"].contains(scheme) { return true }
        guard ["http", "https", "ws", "wss"].contains(scheme), let host = url.host?.lowercased() else { return false }
        return host == scope.serverIP.lowercased() || isLoopback(host) || scope.loopbackNames.contains(host)
    }

    /// SOCKS 중계의 판정. 포트는 그대로 (jenkins.acme:9090 → 127.0.0.2:9090).
    public static func route(host: String, port: Int, scope: BrowserScope) -> SocksRoute {
        let h = host.lowercased()
        if h == scope.serverIP.lowercased() { return .upstream }
        if let address = scope.loopbackNameAddresses[h] { return .direct(host: address, port: port) }
        if isLoopback(h) { return .direct(host: h == "localhost" ? "127.0.0.1" : h, port: port) }
        return .deny
    }

    /// 시작 주소 = 사용자가 그 서버로 열어 둔 첫 포트 터널의 **로컬 주소**. 서버 이름 터널이면 그 이름(jenkins.acme:9090), 아니면 localhost:<로컬 포트>.
    /// 서버 IP 로 시작하지 않는다. 터널이 없으면 nil (빈 탭).
    public static func startURL(firstTunnel: TunnelSpec?) -> URL? {
        guard let spec = firstTunnel, case .port = spec.kind else { return nil }
        let host = spec.hostName ?? (spec.localBind == "127.0.0.1" ? "localhost" : spec.localBind)
        return URL(string: "http://\(host):\(spec.localPort)/")
    }

    /// WKContentRuleList JSON: 전부 막고, 허용 호스트(와 페이지 내부 스킴)만 앞선 규칙을 무시하게 한다.
    /// url-filter 는 WebKit 의 제한된 정규식이라 `|`·`{}` 없이 쓴다. 호스트 뒤는 ":포트" 또는 "/" 또는 끝.
    public static func contentRulesJSON(scope: BrowserScope) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^blob:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^about:"], "action": ["type": "ignore-previous-rules"]],
        ]
        var hostPatterns = [escapeForURLFilter(scope.serverIP), "localhost", "127\\.[0-9]+\\.[0-9]+\\.[0-9]+"]
        hostPatterns += scope.loopbackNames.sorted().map(escapeForURLFilter)
        for host in hostPatterns {
            for scheme in ["https?", "wss?"] {
                for tail in [":[0-9]+/", ":[0-9]+$", "/", "$"] {
                    rules.append(["trigger": ["url-filter": "^\(scheme)://\(host)\(tail)"], "action": ["type": "ignore-previous-rules"]])
                }
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// 호스트를 url-filter 정규식에 넣을 수 있게 — 점만 이스케이프하면 된다 (호스트 이름·IP).
    static func escapeForURLFilter(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: "\\.")
    }
}
