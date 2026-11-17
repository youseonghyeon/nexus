// this Mac 화면의 방화벽(Ports 카드)·시스템 프록시(Address 카드). 둘 다 root 없이 읽기만 한다.
//   방화벽: /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate · --getstealthmode · --getblockall
//   프록시: scutil --proxy (기본 서비스의 값 — 시스템 설정 > 네트워크 > 프록시)

import Foundation

public struct FirewallState: Sendable, Equatable {
    public var enabled: Bool
    /// ping·닫힌 포트에 응답하지 않음
    public var stealth: Bool
    /// 필수 서비스 말고 들어오는 연결 모두 차단
    public var blockAll: Bool

    public init(enabled: Bool, stealth: Bool = false, blockAll: Bool = false) {
        self.enabled = enabled; self.stealth = stealth; self.blockAll = blockAll
    }

    /// "켜짐" · "켜짐 · Stealth · 들어오는 연결 모두 차단" · "꺼짐" (꺼져 있으면 Stealth·차단 설정은 효과가 없어 뺀다)
    public var text: String {
        guard enabled else { return "꺼짐" }
        return (["켜짐"] + (stealth ? ["Stealth"] : []) + (blockAll ? ["들어오는 연결 모두 차단"] : [])).joined(separator: " · ")
    }

    /// 세 출력 → 상태. 전체 상태 줄을 못 읽으면 nil ("Firewall is enabled. (State = 1)" · "… disabled. (State = 0)")
    public static func parse(global: String, stealth: String, blockAll: String) -> FirewallState? {
        let g = global.lowercased()
        let enabled: Bool
        if g.contains("is enabled") || g.contains("state = 1") || g.contains("state = 2") { enabled = true }
        else if g.contains("is disabled") || g.contains("state = 0") { enabled = false }
        else { return nil }
        // "Firewall stealth mode is on" · "Firewall has block all state set to enabled." — State = 2 도 모두 차단
        let s = stealth.lowercased(), b = blockAll.lowercased()
        return FirewallState(enabled: enabled, stealth: s.contains("mode is on"),
                             blockAll: b.contains("set to enabled") || g.contains("state = 2"))
    }

    public static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    /// 못 읽으면 nil (화면은 "–")
    public static func fetch(runner: any CommandRunner) async -> FirewallState? {
        let global = await runner.run(tool, ["--getglobalstate"], timeout: 5)
        guard global.ok else { return nil }
        let stealth = await runner.run(tool, ["--getstealthmode"], timeout: 5)
        let blockAll = await runner.run(tool, ["--getblockall"], timeout: 5)
        return parse(global: global.stdout, stealth: stealth.ok ? stealth.stdout : "", blockAll: blockAll.ok ? blockAll.stdout : "")
    }
}

public enum SystemProxy {
    /// scutil --proxy → 켜진 프록시만 한 줄씩: "HTTP 10.0.0.1:8080" · "HTTPS …" · "SOCKS …" · "PAC http://wpad/proxy.pac" · "자동 탐지 (WPAD)".
    /// 아무것도 안 켜졌으면 빈 배열 (화면은 줄을 숨긴다)
    public static func parse(_ text: String) -> [String] {
        let values = SCDictionary.parse(text).values
        func on(_ key: String) -> Bool { values[key] == "1" }
        var out: [String] = []
        for (prefix, label) in [("HTTP", "HTTP"), ("HTTPS", "HTTPS"), ("SOCKS", "SOCKS")] where on("\(prefix)Enable") {
            guard let host = values["\(prefix)Proxy"], !host.isEmpty else { continue }
            out.append("\(label) \(host)" + (values["\(prefix)Port"].map { ":\($0)" } ?? ""))
        }
        if on("ProxyAutoConfigEnable") {
            out.append("PAC " + (values["ProxyAutoConfigURLString"] ?? "–"))
        }
        if on("ProxyAutoDiscoveryEnable") { out.append("자동 탐지 (WPAD)") }
        return out
    }

    /// 못 읽으면 빈 배열
    public static func fetch(runner: any CommandRunner) async -> [String] {
        let result = await runner.run("scutil", ["--proxy"], timeout: 5)
        return result.ok ? parse(result.stdout) : []
    }
}
