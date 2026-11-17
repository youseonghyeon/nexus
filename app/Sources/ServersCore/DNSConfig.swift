// DNS (읽기 전용, 루트 권한 필요 없음): scutil --dns 를 읽는다.
// 장치별 값은 "for scoped queries" 구역 (if_index 줄의 장치 이름), 이 Mac 이 실제로 쓰는 값은 위 구역의 첫 리졸버(도메인 한정·mDNS 제외).
// networksetup -getdnsservers 는 DHCP 로 받은 값을 "설정 없음" 으로 보여서 쓰지 않는다.

import Foundation

public struct DNSResolver: Sendable, Equatable {
    public var nameservers: [String] = []
    public var searchDomains: [String] = []
    public var device: String?
    /// "local" 처럼 특정 도메인만 맡는 리졸버
    public var domain: String?

    public init(nameservers: [String] = [], searchDomains: [String] = [], device: String? = nil, domain: String? = nil) {
        self.nameservers = nameservers; self.searchDomains = searchDomains; self.device = device; self.domain = domain
    }

    /// "168.126.63.1, 168.126.63.2" (없으면 nil)
    public var nameserverText: String? { nameservers.isEmpty ? nil : nameservers.joined(separator: ", ") }
    public var searchDomainText: String? { searchDomains.isEmpty ? nil : searchDomains.joined(separator: ", ") }
}

public struct DNSConfig: Sendable, Equatable {
    /// 기본 질의에 쓰는 리졸버 — 이 Mac 화면
    public var primary: DNSResolver?
    /// 장치별 리졸버 ("en0" → …) — Wi-Fi·Ethernet 화면
    public var scoped: [String: DNSResolver]
    /// 도메인별 리졸버 (/etc/resolver/<도메인> · VPN 이 넣는 도메인) — 그 도메인 이름만 이 서버에 묻는다. this Mac Hosts 카드.
    /// mDNS(local·*.arpa — 이름 서버 없음)는 뺀다
    public var domainResolvers: [DNSResolver]

    public init(primary: DNSResolver?, scoped: [String: DNSResolver], domainResolvers: [DNSResolver] = []) {
        self.primary = primary; self.scoped = scoped; self.domainResolvers = domainResolvers
    }

    public static func fetch(runner: any CommandRunner) async -> DNSConfig {
        parse(await runner.run("scutil", ["--dns"], timeout: 5).stdout)
    }

    public static func parse(_ text: String) -> DNSConfig {
        var general: [DNSResolver] = []
        var scoped: [String: DNSResolver] = [:]
        var inScoped = false
        var current: DNSResolver?

        func flush() {
            guard let resolver = current else { return }
            if inScoped {
                if let device = resolver.device, scoped[device] == nil { scoped[device] = resolver }
            } else {
                general.append(resolver)
            }
            current = nil
        }

        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration") {
                flush()
                inScoped = line.contains("scoped")
                continue
            }
            if line.hasPrefix("resolver #") {
                flush()
                current = DNSResolver()
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if key.hasPrefix("nameserver[") {
                current?.nameservers.append(value)
            } else if key.hasPrefix("search domain[") {
                current?.searchDomains.append(value)
            } else if key == "domain" {
                current?.domain = value
            } else if key == "if_index", let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
                // "28 (en11)"
                current?.device = String(value[value.index(after: open)..<close])
            }
        }
        flush()
        let primary = general.first { $0.domain == nil && !$0.nameservers.isEmpty }
        return DNSConfig(primary: primary, scoped: scoped, domainResolvers: general.filter { $0.domain != nil && !$0.nameservers.isEmpty })
    }
}
