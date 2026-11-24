// 진단 카드의 TCP 포트 확인 · DNS 조회 (그 화면의 장치·DNS 로만). 서버에 로그인하지 않는다 — 연결을 한 번 열고 닫거나, 이름 하나를 묻는다.
// TCP: ping 이 막혀도 서비스 포트(22·5432 …)는 열려 있는 경우가 많다 — "서버는 사는데 포트가 닫힘"과 "아예 안 닿음"을 가른다. IPv4 만 (TCPProbe).
// DNS: 그 화면 장치의 DNS 서버에 dig 로 A 한 번 + AAAA 한 번 + 그 이름을 관리하는 영역의 네임서버(NS, 많아야 4번) (macOS 기본 /usr/bin/dig). 출력 모양 (2026-10-15 이 Mac):
//   www.apple.com.		251	IN	CNAME	www-apple-com.v.aaplimg.com.
//   e6858.dsce9.akamaiedge.net. 10	IN	A	23.41.89.203
//   ;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 45433
//   ;; Query time: 9 msec
//   ;; connection timed out; no servers could be reached

import Foundation

// MARK: 공용 (이 Mac 의 진단 카드와 서버 Diagnose 탭이 같이 쓰는 문구 · 입력 검사)

public enum DiagnosticText {
    /// 이름이 안 풀렸을 때의 결과 줄 (ping · HTTP · 서버 쪽 ping · dns)
    public static let unresolved = "이름을 찾지 못했습니다"
}

enum DiagnosticInput {
    /// 앞뒤 공백을 지운 호스트(이름 · 주소): 영문·숫자·. - 와 extra 한 글자만, 253자까지. "-" 로 시작하면 옵션으로 읽히므로 거른다. 아니면 nil
    static func host(_ input: String, extra: Character) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 253, !text.hasPrefix("-"),
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == extra) }) else { return nil }
        return text
    }
}

// MARK: TCP

public struct TCPPortResult: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let device: String
    public let at: Date
    /// nil = 확인 중
    public var open: Bool?
    public var ms: Int?

    public init(host: String, port: Int, device: String, at: Date = Date()) {
        self.host = host; self.port = port; self.device = device; self.at = at
    }

    public var text: String {
        switch open {
        case true?: return "열림" + (ms.map { " · \($0) ms" } ?? "")
        case false?: return "응답 없음 (닫힘·막힘)"
        case nil: return "확인 중…"
        }
    }

    public var reportText: String {
        "TCP \(host):\(port) · \(device) · \(at.formatted(date: .abbreviated, time: .standard))\n결과: \(text)"
    }
}

public enum TCPPortTest {
    public static let timeout: TimeInterval = 3

    /// "10.0.0.1:22" · "10.0.0.1 22" → (IPv4, 포트). 꼴이 틀리면 nil
    public static func target(_ input: String) -> (host: String, port: Int)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " }).map(String.init)
        guard parts.count == 2, IPv4.parse(parts[0]) != nil,
              let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
        return (parts[0], port)
    }
}

// MARK: DNS

public struct DNSAnswer: Sendable, Equatable {
    public let name: String
    public let type: String
    public let value: String
    /// 답이 캐시에 남는 시간(초) — 재귀 서버가 주면 남은 시간
    public var ttl: Int? = nil
}

public struct DNSLookupResult: Sendable, Equatable {
    public let name: String
    public let server: String
    public let device: String
    public let at: Date
    /// nil = 묻는 중
    public var answers: [DNSAnswer]?
    /// NOERROR · NXDOMAIN · SERVFAIL … (응답이 있을 때)
    public var status: String?
    public var ms: Int?
    /// 서버가 답하지 않음
    public var timedOut = false
    /// 이 이름을 관리하는 영역(상위 도메인)과 그 네임서버 — 못 찾으면 nil (DNSLookup.nameservers)
    public var zone: String?
    public var nameservers: [String] = []
    /// IPv6 주소 (AAAA 를 따로 물은 답 — A 가 답했을 때만 묻는다)
    public var answers6: [DNSAnswer] = []

    public var addresses6: [String] { answers6.filter { $0.type == "AAAA" }.map(\.value) }
    /// 주소(A) 답의 TTL 가운데 가장 짧은 것 — 이만큼 지나면 다시 묻는다
    public var ttl: Int? { (answers ?? []).filter { $0.type == "A" }.compactMap(\.ttl).min() }

    /// 네임서버 이름으로 알아본 DNS 서비스 ("Route 53") — 모르는 곳이면 nil
    public var provider: String? { DNSProvider.name(for: nameservers) }

    public init(name: String, server: String, device: String, at: Date = Date()) {
        self.name = name; self.server = server; self.device = device; self.at = at
    }

    /// 최종 주소들 (A·AAAA) — CNAME 을 따라간 끝
    public var addresses: [String] { (answers ?? []).filter { $0.type == "A" || $0.type == "AAAA" }.map(\.value) }

    public var text: String {
        if timedOut { return "DNS 서버 응답 없음" }
        guard let answers else { return "묻는 중…" }
        if status == "NXDOMAIN" { return "이름 없음 (NXDOMAIN)" }
        if let status, status != "NOERROR" { return "실패 (\(status))" }
        if answers.isEmpty { return addresses6.isEmpty ? "답 없음" : "IPv4 주소 없음" }
        return addresses.isEmpty ? answers.map(\.value).joined(separator: ", ") : addresses.joined(separator: ", ")
    }

    public var reportText: String {
        var lines = ["DNS \(name) @\(server) · \(device) · \(at.formatted(date: .abbreviated, time: .standard))", "결과: \(text)" + (ms.map { " · \($0) ms" } ?? "")]
        for answer in (answers ?? []) + answers6.filter({ $0.type == "AAAA" }) {
            lines.append("  \(answer.name) \(answer.type) \(answer.value)" + (answer.ttl.map { " (TTL \($0))" } ?? ""))
        }
        if let zone, !nameservers.isEmpty {
            lines.append("네임서버 (\(zone))" + (provider.map { " · \($0)" } ?? "") + ":")
            lines += nameservers.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

public enum DNSLookup {
    /// 이름: 영문·숫자·. - _ 만, "-" 로 시작하지 않게 (dig 옵션으로 읽히지 않게)
    public static func name(_ input: String) -> String? {
        DiagnosticInput.host(input, extra: "_")
    }

    /// dig +noall +comments +answer +stats 출력
    public static func parse(_ text: String) -> (answers: [DNSAnswer], status: String?, ms: Int?, timedOut: Bool) {
        var answers: [DNSAnswer] = [], status: String?, ms: Int?
        var timedOut = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.contains("connection timed out") || line.contains("no servers could be reached") { timedOut = true }
            if let range = line.range(of: "status: ") {
                status = line[range.upperBound...].split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            if let range = line.range(of: "Query time: ") {
                ms = line[range.upperBound...].split(separator: " ").first.flatMap { Int($0) }
            }
            guard !line.hasPrefix(";") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 5, fields[2] == "IN" else { continue }
            let trim = { (s: String) in s.hasSuffix(".") ? String(s.dropLast()) : s }
            answers.append(DNSAnswer(name: trim(fields[0]), type: fields[3], value: trim(fields[4...].joined(separator: " ")), ttl: Int(fields[1])))
        }
        return (answers, status, ms, timedOut)
    }

    /// 그 DNS 서버에 A 를 한 번 묻는다. source 를 주면 그 주소에서 보낸다 (그 화면 장치의 스코프 경로로)
    public static func query(_ name: String, server: String, source: String?, device: String, runner: any CommandRunner) async -> DNSLookupResult {
        var result = DNSLookupResult(name: name, server: server, device: device)
        let args = ["+noall", "+comments", "+answer", "+stats", "+time=2", "+tries=1"] + (source.map { ["-b", $0] } ?? []) + ["@\(server)", name, "A"]
        let output = await runner.run("dig", args, timeout: 8)
        let parsed = parse(output.stdout + output.stderr)
        result.answers = parsed.answers
        result.status = parsed.status
        result.ms = parsed.ms
        result.timedOut = parsed.timedOut || (output.exitCode == 9)
        // 이름이 없거나 서버가 답하지 않으면 네임서버는 묻지 않는다
        guard !result.timedOut, result.status != "NXDOMAIN" else { return result }
        // IPv6 주소와 네임서버는 함께 묻는다 (차례로 물으면 그만큼 결과가 늦다)
        async let v6 = runner.run("dig", ["+noall", "+answer", "+time=2", "+tries=1"] + (source.map { ["-b", $0] } ?? []) + ["@\(server)", name, "AAAA"], timeout: 8)
        async let found = nameservers(for: name, server: server, source: source, runner: runner)
        result.answers6 = parse(await v6.stdout).answers
        if let found = await found {
            result.zone = found.zone
            result.nameservers = found.servers
        }
        return result
    }

    /// 이 이름을 관리하는 영역의 네임서버 (같은 DNS 서버에 NS 를 묻는다 — 많아야 4번).
    /// "www.example.com" 같은 하위 이름엔 NS 가 없다: 답의 SOA 가 가리키는 영역으로 올라가고, CNAME 이면(SOA 가 건너간 쪽 것) 앞 낱말을 떼며 올라간다.
    public static func nameservers(for name: String, server: String, source: String?, runner: any CommandRunner) async -> (zone: String, servers: [String])? {
        let trim = { (s: String) in (s.hasSuffix(".") ? String(s.dropLast()) : s).lowercased() }
        var candidate = trim(name)
        for _ in 0..<4 {
            let args = ["+noall", "+comments", "+answer", "+authority", "+time=2", "+tries=1"] + (source.map { ["-b", $0] } ?? []) + ["@\(server)", candidate, "NS"]
            let output = await runner.run("dig", args, timeout: 8)
            let parsed = parse(output.stdout + output.stderr)
            if parsed.timedOut || output.exitCode == 9 { return nil }
            let covers = { (owner: String) in !owner.isEmpty && (owner == candidate || candidate.hasSuffix("." + owner)) }
            // 그 이름이나 상위 영역의 NS (권한 구역에 영역의 NS 를 실어 주는 서버도 있다) — 가장 가까운 영역 것
            let records = parsed.answers.filter { $0.type == "NS" && covers($0.name.lowercased()) }
            if let zone = records.map({ $0.name.lowercased() }).max(by: { $0.count < $1.count }) {
                return (zone, records.filter { $0.name.lowercased() == zone }.map { trim($0.value) }.sorted())
            }
            let soa = parsed.answers.first { $0.type == "SOA" }.map { $0.name.lowercased() }
            if !parsed.answers.contains(where: { $0.type == "CNAME" }), let soa, soa != candidate, covers(soa) {
                candidate = soa
            } else if let dot = candidate.firstIndex(of: ".") {
                candidate = String(candidate[candidate.index(after: dot)...])
            } else {
                return nil
            }
        }
        return nil
    }
}

/// 네임서버 이름 → DNS 서비스. 목록에 없으면 nil (화면은 네임서버 이름만 보인다).
public enum DNSProvider {
    /// (이름에 들어 있는 글, 서비스) — 앞에서부터 먼저 맞는 것
    static let table: [(String, String)] = [
        (".awsdns-", "Amazon Route 53"), (".cloudflare.com", "Cloudflare"), (".googledomains.com", "Google Cloud DNS"), (".google.com", "Google"),
        (".azure-dns.", "Azure DNS"), (".ns-ncloud.com", "Naver Cloud"), (".gabia.", "가비아"), (".cafe24.", "Cafe24"), (".hosting.co.kr", "호스팅케이알"),
        (".whoisdomain.kr", "후이즈"), (".dnszi.com", "DNSZi"), (".dnsever.com", "DNSEver"), (".domaincontrol.com", "GoDaddy"),
        (".registrar-servers.com", "Namecheap"), (".nsone.net", "NS1"), (".akam.net", "Akamai"), (".dynect.net", "Oracle Dyn"), (".ultradns.", "UltraDNS"),
        (".dnsimple.com", "DNSimple"), (".dnsmadeeasy.com", "DNS Made Easy"), (".digitalocean.com", "DigitalOcean"), (".linode.com", "Linode"),
        (".vercel-dns.com", "Vercel"), (".wixdns.net", "Wix"), (".squarespacedns.com", "Squarespace"), (".dnspod.net", "DNSPod"), (".alidns.com", "Alibaba Cloud"),
        (".he.net", "Hurricane Electric"), (".ovh.net", "OVH"), (".gandi.net", "Gandi"), (".hetzner.", "Hetzner"), (".porkbun.com", "Porkbun"),
        (".name.com", "Name.com"), (".cscdns.net", "CSC"), (".markmonitor.com", "MarkMonitor"),
    ]

    /// 네임서버가 모두 같은 서비스일 때만 (섞여 있으면 하나로 말할 수 없다)
    public static func name(for nameservers: [String]) -> String? {
        let found = nameservers.map { server in table.first { ("." + server.lowercased()).contains($0.0) }?.1 }
        guard let first = found.first, let name = first, found.allSatisfy({ $0 == name }) else { return nil }
        return name
    }
}
