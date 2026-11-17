// Windows 서버의 Network 탭: 어댑터 · 주소 · IPv4 경로 · DNS. 화면이 리눅스와 같아 결과는 LinuxNetwork (LinuxNetworkView · 경로 그림).
// 실제 출력: Tests/ServersCoreTests/Fixtures/windows-network.txt (Windows 11 26100 · PowerShell 5.1, MAC·링크로컬 주소는 가짜 값).
// 읽기만 한다.

import Foundation

public enum WindowsNetwork {
    /// 값은 | 로 가른다 (이름이 맨 끝 — 조회 출력은 cleanOutput 이 탭을 공백으로 바꾼다).
    /// @ADAPTER  ifIndex|Status(Up · Disconnected · Disabled)|속도 bps|MAC|Virtual|HardwareInterface|이름|설명
    /// @IP       ifIndex|IPv4 · IPv6|주소|prefix|PrefixOrigin|이름
    /// @ROUTE    목적지|다음 홉(0.0.0.0 = On-link)|ifIndex|RouteMetric|InterfaceMetric|이름
    /// @DNS      ifIndex|서버들(공백)|이름
    public static let script = #"""
    $ErrorActionPreference = 'SilentlyContinue'
    function NxRow { $args -join '|' }
    "@ADAPTER"
    Get-NetAdapter | ForEach-Object { NxRow $_.ifIndex $_.Status $_.Speed $_.MacAddress $_.Virtual $_.HardwareInterface $_.Name $_.InterfaceDescription }
    "@IP"
    Get-NetIPAddress | ForEach-Object { NxRow $_.InterfaceIndex $_.AddressFamily $_.IPAddress $_.PrefixLength $_.PrefixOrigin $_.InterfaceAlias }
    "@ROUTE"
    Get-NetRoute -AddressFamily IPv4 | ForEach-Object { NxRow $_.DestinationPrefix $_.NextHop $_.InterfaceIndex $_.RouteMetric $_.InterfaceMetric $_.InterfaceAlias }
    "@DNS"
    Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | ForEach-Object { NxRow $_.InterfaceIndex ($_.ServerAddresses -join ' ') $_.InterfaceAlias }
    "@END"
    """#

    /// @END 가 없거나 어댑터를 하나도 못 읽으면 nil — 화면은 원문을 보여 준다
    public static func parse(_ lines: [String]) -> LinuxNetwork? {
        guard let s = ScriptSections.parse(lines.joined(separator: "\n"), dropEmpty: true) else { return nil }
        func fields(_ line: String, _ count: Int) -> [String]? {
            let f = line.split(separator: "|", maxSplits: count - 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            return f.count == count ? f : nil
        }
        // 주소: IPv4 먼저, 링크로컬 IPv6(fe80::)은 뺀다 (리눅스와 같다)
        var addresses: [Int: [String]] = [:]
        for line in s["IP"] ?? [] {
            guard let f = fields(line, 6), let index = Int(f[0]), !f[2].isEmpty else { continue }
            let address = f[2].split(separator: "%").first.map(String.init) ?? f[2]   // "fe80::1%19" 의 범위 표시
            if f[1] == "IPv6", address.lowercased().hasPrefix("fe80:") { continue }
            let text = f[3].isEmpty ? address : "\(address)/\(f[3])"
            if f[1] == "IPv4" { addresses[index, default: []].insert(text, at: addresses[index, default: []].filter { !$0.contains(":") }.count) }
            else { addresses[index, default: []].append(text) }
        }
        var names: [Int: String] = [:]
        var parsed: [LinuxNetInterface] = []
        for line in s["ADAPTER"] ?? [] {
            guard let f = fields(line, 8), let index = Int(f[0]), !f[6].isEmpty else { continue }
            let up = f[1] == "Up"
            let virtual = f[4].lowercased() == "true"
            names[index] = f[6]
            // 가상 어댑터의 속도(10 Gbps)는 뜻이 없다. 안 꽂힌 어댑터도 마지막 값이 남아 있다
            let speed = up && !virtual ? UInt64(f[2]).map { Int($0 / 1_000_000) }.flatMap { $0 > 0 ? Ethernet.speedLabel(mbps: $0) : nil } : nil
            let mac = f[3].isEmpty ? nil : f[3].replacingOccurrences(of: "-", with: ":").lowercased()
            parsed.append(LinuxNetInterface(name: f[6], up: up, kind: virtual ? "virtual" : nil, master: nil, mac: mac, mtu: nil,
                                            addresses: addresses[index] ?? [], rxBytes: nil, txBytes: nil,
                                            detail: [f[7].isEmpty ? nil : f[7], speed].compactMap { $0 }.joined(separator: " · ")))
        }
        guard !parsed.isEmpty else { return nil }

        var result = LinuxNetwork()
        result.foldedTitle = "가상 어댑터"
        result.interfaces = parsed.filter { !$0.ipv4.isEmpty } + parsed.filter { $0.ipv4.isEmpty }

        // 경로: 어댑터에 붙은 대역·게이트웨이만. 주소 하나짜리(/32 — 자기 주소·브로드캐스트)·멀티캐스트·루프백은 Windows 가 어댑터마다 깔아 두는 줄이다
        var routes: [OpenWrtRoute] = []
        var sawRoute = false
        for line in s["ROUTE"] ?? [] {
            guard let f = fields(line, 6), let index = Int(f[2]) else { continue }
            sawRoute = true
            guard let device = names[index], !f[0].hasSuffix("/32"), f[0] != "224.0.0.0/4" else { continue }
            let metric = (Int(f[3]) ?? 0) + (Int(f[4]) ?? 0)   // Windows 는 둘을 더한 값으로 고른다
            routes.append(OpenWrtRoute(destination: f[0] == "0.0.0.0/0" ? "default" : f[0], gateway: f[1] == "0.0.0.0" || f[1].isEmpty ? nil : f[1],
                                       device: device, interface: nil, table: "main", kind: nil, metric: metric))
        }
        if sawRoute { result.routing = OpenWrtRouting(rules: [], routes: routes) }

        for line in s["DNS"] ?? [] {
            guard let f = fields(line, 3) else { continue }
            for server in f[1].split(separator: " ").map(String.init) where !result.dns.contains(server) { result.dns.append(server) }
        }
        result.layout = LinuxNetwork.layout(result.interfaces, routing: result.routing)
        return result
    }
}
