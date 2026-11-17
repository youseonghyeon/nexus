// 진단 [Scan]의 "어떤 장비인지": 추측 없이 등록부·장비가 준 값만.
//   제조사 — MAC 앞자리를 IEEE 배정 목록(MA-L 6 · MA-M 7 · MA-S 9 자리, Resources/oui/oui.tsv)에서 찾는다. 오프라인.
//   임의 MAC — 첫 바이트의 "로컬 관리" 비트(둘째 자리 2·6·A·E)가 켜져 있으면 휴대폰·노트북의 사설 주소라 제조사가 없다.
//   Windows 이름 — NetBIOS (smbutil status). 최근 Windows 는 꺼 둔 경우가 많아 비어 있을 수 있다.
//   DNS 이름 — 그 화면 DNS 서버에 PTR (공유기 dnsmasq 는 DHCP 로 받은 장비 이름을 답한다). 없으면 빈칸.
//   UPnP 이름 — SSDP 로 한 번 찾고 응답한 장비의 설명 XML 의 friendlyName (공유기·TV·프린터). 없으면 빈칸.
// (Bonjour 역방향 질의는 macOS 27 이 자기 자신에게도 답하지 않아 넣지 않았다 — 2026-10-15 확인)

import Foundation

public struct OUITable: Sendable {
    /// 접두(대문자 16진 6·7·9자리) → 조직 이름
    let names: [String: String]

    public init(names: [String: String]) { self.names = names }

    /// "588694\tEFM Networks" 줄들 (# 로 시작하면 주석)
    public static func parse(_ text: String) -> OUITable {
        var names: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            names[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return OUITable(names: names)
    }

    public static func load(path: String) -> OUITable? {
        (try? String(contentsOfFile: path, encoding: .utf8)).map(parse)
    }

    /// 가장 긴 접두부터 (MA-S 9 → MA-M 7 → MA-L 6)
    public func vendor(mac: String) -> String? {
        let hex = mac.replacingOccurrences(of: ":", with: "").uppercased()
        guard hex.count == 12 else { return nil }
        for length in [9, 7, 6] {
            if let name = names[String(hex.prefix(length))] { return name }
        }
        return nil
    }
}

public struct DeviceIdentity: Sendable, Equatable {
    public var vendor: String?
    /// 사설(임의) MAC — 제조사를 알 수 없다
    public var randomMAC = false
    /// DNS 이름 (PTR, 끝 "." 뺌)
    public var hostname: String?
    /// Windows 컴퓨터 이름 (NetBIOS)
    public var netbios: String?
    /// UPnP 장치 이름 (SSDP 설명 XML)
    public var upnp: String?

    public init(vendor: String? = nil, randomMAC: Bool = false, hostname: String? = nil, netbios: String? = nil, upnp: String? = nil) {
        self.vendor = vendor; self.randomMAC = randomMAC; self.hostname = hostname; self.netbios = netbios; self.upnp = upnp
    }

    /// "EFM Networks" · "임의 MAC · iphone.lan" · "Samsung Electronics Co.,Ltd · desktop-abc.lan" — 아무것도 없으면 nil.
    /// 이름은 DNS → NetBIOS → UPnP 순, 첫 마디가 앞 이름과 같으면(대소문자 무시) 뺀다 ("window-pc.lan" 뒤의 "WINDOW-PC")
    public var text: String? {
        let label = { (name: String) in String(name.split(separator: ".").first ?? "").lowercased() }
        var names: [String] = []
        for name in [hostname, netbios, upnp].compactMap({ $0 }) where !names.contains(where: { label($0) == label(name) }) {
            names.append(name)
        }
        let parts = [randomMAC ? "임의 MAC" : vendor].compactMap { $0 } + names
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 첫 바이트 둘째 비트(로컬 관리)가 켜져 있는가 — "16:12:17:…" 의 0x16
    public static func isRandomMAC(_ mac: String) -> Bool {
        guard let first = mac.split(separator: ":").first, let byte = UInt8(first, radix: 16) else { return false }
        return byte & 0x02 != 0
    }

    /// smbutil status 출력의 "Server: DESKTOP-ABC"
    public static func parseNetBIOS(_ text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Server:") else { continue }
            let name = line.dropFirst("Server:".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// dig +short -x 출력의 첫 이름 ("brume3.lan." → "brume3.lan"). ";" 로 시작하는 줄은 오류
    public static func parsePTR(_ text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            let name = line.hasSuffix(".") ? String(line.dropLast()) : line
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// PTR 을 물을 곳: 그 화면 DNS 서버, 보내는 주소(그 화면 서비스 IP)
    public struct DNSTarget: Sendable {
        public var server: String
        public var source: String?
        public init(server: String, source: String?) { self.server = server; self.source = source }
    }

    /// 그 DNS 서버에 PTR 한 번 (1초)
    static func ptr(_ ip: String, dns: DNSTarget?, runner: any CommandRunner) async -> String? {
        guard let dns else { return nil }
        let args = ["+short", "+time=1", "+tries=1"] + (dns.source.map { ["-b", $0] } ?? []) + ["@\(dns.server)", "-x", ip]
        let output = await runner.run("dig", args, timeout: 3)
        return output.ok ? parsePTR(output.stdout) : nil
    }

    /// 장비 하나: 제조사(목록) + DNS 이름(PTR) + Windows 이름(질의 한 번, 2초) — 두 질의는 함께
    public static func identify(_ entry: ArpEntry, table: OUITable?, dns: DNSTarget? = nil, runner: any CommandRunner) async -> DeviceIdentity {
        guard let mac = entry.mac else { return DeviceIdentity() }
        let random = isRandomMAC(mac)
        async let hostname = ptr(entry.ip, dns: dns, runner: runner)
        let status = await runner.run("smbutil", ["status", entry.ip], timeout: 2)
        return DeviceIdentity(vendor: random ? nil : table?.vendor(mac: mac), randomMAC: random, hostname: await hostname,
                              netbios: status.ok ? parseNetBIOS(status.stdout) : nil)
    }

    /// 응답한 장비 전부 — 장비별 질의는 병렬로, UPnP 는 ssdpSource(그 화면 서비스 IP)에서 SSDP 한 번 (같은 시간에)
    public static func identifyAll(_ entries: [ArpEntry], table: OUITable?, dns: DNSTarget? = nil, ssdpSource: String? = nil,
                                   device: String? = nil, runner: any CommandRunner) async -> [String: DeviceIdentity] {
        async let upnp = SSDP.names(source: ssdpSource, device: device, only: Set(entries.map(\.ip)), runner: runner)
        var result = await withTaskGroup(of: (String, DeviceIdentity).self) { group in
            for entry in entries where entry.mac != nil {
                group.addTask { (entry.ip, await identify(entry, table: table, dns: dns, runner: runner)) }
            }
            var result: [String: DeviceIdentity] = [:]
            for await (ip, identity) in group { result[ip] = identity }
            return result
        }
        for (ip, name) in await upnp where result[ip] != nil { result[ip]?.upnp = name }
        return result
    }
}

/// SSDP: 239.255.255.250:1900 에 M-SEARCH → 응답한 장비의 LOCATION(그 장비 자신의 http 주소만) → 설명 XML 의 이름
public enum SSDP {
    static let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: upnp:rootdevice\r\n\r\n"

    /// 응답 머리의 LOCATION 값
    public static func location(_ response: String) -> String? {
        for line in response.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 응답한 그 장비(같은 IP)의 http 주소일 때만 받는다 — 다른 곳을 가리키면 따라가지 않는다
    public static func acceptable(_ location: String, from ip: String) -> Bool {
        guard let url = URL(string: location), url.scheme?.lowercased() == "http" else { return false }
        return url.host == ip
    }

    /// 설명 XML 의 첫 friendlyName, 비었으면 modelName
    public static func name(fromDescription xml: String) -> String? {
        element("friendlyName", in: xml) ?? element("modelName", in: xml)
    }

    static func element(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"), let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        let value = decodeEntities(String(xml[open.upperBound..<close.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// XML 글자 참조 풀기: 이름 다섯 개와 숫자 참조(&#39; · &#x27;) — 숫자 참조를 안 풀어 "window-pc&#39;s AirScreen" 처럼 보였다.
    /// &amp; 는 맨 끝에 (먼저 풀면 "&amp;#39;" 가 작은따옴표가 된다)
    static func decodeEntities(_ text: String) -> String {
        var out = text
        for (pattern, radix) in [(#"&#x([0-9A-Fa-f]{1,6});"#, 16), (#"&#([0-9]{1,7});"#, 10)] {
            while let range = out.range(of: pattern, options: .regularExpression) {
                let digits = out[range].dropFirst(radix == 16 ? 3 : 2).dropLast()
                let replacement = UInt32(digits, radix: radix).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
                out.replaceSubrange(range, with: replacement)
            }
        }
        return out
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 찾기(2초) → 설명 받기(curl, 2초, 그 장치로) → IP → 이름. only 에 든 IP(응답한 장비)만. source 가 없으면(VPN) 빈 결과
    public static func names(source: String?, device: String?, only: Set<String>, runner: any CommandRunner) async -> [String: String] {
        guard let source else { return [:] }
        let locations = await search(source: source).filter { only.contains($0.key) }
        return await withTaskGroup(of: (String, String?).self) { group in
            for (ip, location) in locations {
                group.addTask {
                    // LOCATION 은 망에서 온 값: -g 범위 문법([1-99]·{a,b})으로 읽지 않게 · --proto http 밖으로 가지 않게 · 설명 XML 은 1MB 까지만
                    let output = await runner.run("curl", ["-s", "-g", "--proto", "=http", "--max-filesize", "1048576", "-m", "2"] + (device.map { ["--interface", $0] } ?? []) + [location], timeout: 4)
                    return (ip, output.ok ? name(fromDescription: output.stdout) : nil)
                }
            }
            var result: [String: String] = [:]
            for await (ip, name) in group { if let name { result[ip] = name } }
            return result
        }
    }

    /// M-SEARCH 를 그 주소에서 보내고 wait 초 동안 응답을 모은다 (IP → LOCATION). 소켓을 못 열면 빈 결과
    public static func search(source: String, wait: TimeInterval = 2) async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: searchBlocking(source: source, wait: wait)) }
        }
    }

    static func searchBlocking(source: String, wait: TimeInterval) -> [String: String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        var local = sockaddr_in()
        local.sin_len = UInt8(size); local.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, source, &local.sin_addr) == 1,
              withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }) == 0 else { return [:] }
        // 그 화면 서비스의 장치로 내보낸다
        var interface = local.sin_addr
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var destination = sockaddr_in()
        destination.sin_len = UInt8(size); destination.sin_family = sa_family_t(AF_INET); destination.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)
        let message = Array(request.utf8)
        // UDP 라 하나가 빠질 수 있어 두 번
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &destination) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, message, message.count, 0, $0, size) } }
        }
        var found: [String: String] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            var from = sockaddr_in()
            var length = size
            let count = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            guard count > 0 else {
                // 시간 초과(200ms)·끊김이 아닌 오류면 그만 — 바로 실패하는 recvfrom 을 wait 초 동안 헛돌지 않게
                if count < 0, errno != EAGAIN, errno != EINTR { break }
                continue
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(decoding: text.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            if found[ip] == nil, let location = location(String(decoding: buffer[..<count], as: UTF8.self)), acceptable(location, from: ip) {
                found[ip] = location
            }
        }
        return found
    }
}
