// 진단 카드의 ARP: 이 Mac 의 ARP 표(IP ↔ MAC)를 읽는다 (arp -an · arp -n). 표 읽기는 패킷을 보내지 않는다 — ping 뒤에 캐시를 본다.
// 보내는 것은 둘뿐: 게이트웨이 확인(gatewayPresent, ping 한 번) · 이웃 찾기(sweep, 대역에 ping 한 번씩) — 둘 다 그 장치에 묶는다.
// ping 이 막힌 장비(Windows 기본 방화벽)도 같은 대역이면 ARP 에는 답하므로, "ping 응답 없음 + MAC 있음" = 장비는 켜져 있다.
// 터미널에선 관리자 권한 없이 보이지만(2026-10-15 사용자 확인) 앱 안에서는 가려질 수 있어 관리자 권한으로 다시 읽는 길을 둔다.
// 출력 모양 (2026-10-15 사용자 Mac):
//   ? (10.50.10.254) at 0:5:66:a0:b1:1b on en10 ifscope [ethernet]
//   ? (192.168.100.3) at 26:85:c7:a8:b1:2a on en0 ifscope permanent [ethernet]
//   ? (10.0.0.9) at (incomplete) on en10 ifscope [ethernet]
//   10.0.0.9 (10.0.0.9) -- no entry

import Foundation

public struct ArpEntry: Sendable, Equatable, Identifiable {
    public var id: String { "\(device) \(ip)" }
    public let ip: String
    /// 00:05:66:a0:b1:1b (두 자리로 맞춤). nil = incomplete (물었는데 답이 없음)
    public let mac: String?
    public let device: String
    /// 이 Mac 자신의 주소 (permanent)
    public let permanent: Bool

    public init(ip: String, mac: String?, device: String, permanent: Bool = false) {
        self.ip = ip; self.mac = mac; self.device = device; self.permanent = permanent
    }
}

/// ping 결과의 ARP 줄
public enum ArpLookup: Sendable, Equatable {
    case found(mac: String)
    /// 물었는데 답이 없다 (같은 대역에 그 장비가 없거나 꺼짐)
    case incomplete
    /// 표에 없다
    case noEntry
    /// 같은 대역이 아니다 — 게이트웨이 너머라 ARP 로는 알 수 없다
    case notLocal

    public var text: String {
        switch self {
        case .found(let mac): return "응답 있음 · \(mac)"
        case .incomplete: return "응답 없음"
        case .noEntry: return "기록 없음"
        case .notLocal: return "같은 대역 아님 (게이트웨이 너머)"
        }
    }
}

public enum Arp {
    /// arp -an 출력 → 항목. 멀티캐스트(224–239)·브로드캐스트(ff:…)는 뺀다.
    public static func parse(_ text: String) -> [ArpEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")"),
                  let atRange = line.range(of: " at "), let onRange = line.range(of: " on ") else { return nil }
            let ip = String(line[line.index(after: open)..<close])
            let rawMAC = String(line[atRange.upperBound..<onRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let device = line[onRange.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            guard !device.isEmpty, NetworkServiceDraft.ipv4(ip) != nil else { return nil }
            if let first = ip.split(separator: ".").first.flatMap({ Int($0) }), (224...239).contains(first) { return nil }
            let mac = rawMAC == "(incomplete)" ? nil : normalizeMAC(rawMAC)
            if mac == "ff:ff:ff:ff:ff:ff" { return nil }
            return ArpEntry(ip: ip, mac: mac, device: device, permanent: line.contains(" permanent"))
        }
    }

    /// "0:5:66:a0:b1:1b" → "00:05:66:a0:b1:1b". 모양이 다르면 nil
    public static func normalizeMAC(_ text: String) -> String? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").lowercased()
    }

    /// ifconfig <장치> 의 "inet 10.50.10.17 netmask 0xffffff00" 들 → 같은 대역인가
    public static func isLocal(_ ip: String, ifconfig: String) -> Bool {
        guard let target = NetworkServiceDraft.ipv4(ip) else { return false }
        for raw in ifconfig.split(whereSeparator: \.isNewline) {
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard parts.first == "inet", parts.count >= 4, let address = NetworkServiceDraft.ipv4(parts[1]),
                  let i = parts.firstIndex(of: "netmask"), i + 1 < parts.count,
                  let maskText = Ethernet.dottedMask(hex: parts[i + 1]), let mask = NetworkServiceDraft.ipv4(maskText) else { continue }
            if address & mask == target & mask { return true }
        }
        return false
    }

    /// ping 뒤 그 대상의 ARP (장치에 묶어 본다). 같은 대역이 아니면 notLocal.
    public static func lookup(_ ip: String, device: String, runner: any CommandRunner) async -> ArpLookup {
        let ifconfig = await runner.run("ifconfig", [device], timeout: 5).stdout
        guard isLocal(ip, ifconfig: ifconfig) else { return .notLocal }
        let result = await runner.run("arp", ["-n", "-i", device, ip], timeout: 5)
        guard let entry = parse(result.stdout).first(where: { $0.ip == ip }) else { return .noEntry }
        return entry.mac.map(ArpLookup.found) ?? .incomplete
    }

    /// 게이트웨이가 그 장치의 선 너머에 있는가 (서비스 카드 상태 표시용 — 막지 않는다): ping 한 번(장치에 묶음)이 되면 있음,
    /// 안 되면 ARP 에 MAC 이 잡혔는지 (ping 을 막는 장비도 ARP 에는 답한다)
    public static func gatewayPresent(_ router: String, device: String, runner: any CommandRunner) async -> Bool {
        let ping = await runner.run("ping", ["-c", "1", "-t", "1", "-b", device, router], timeout: 3)
        if ping.ok { return true }
        let arp = await runner.run("arp", ["-n", "-i", device, router], timeout: 3)
        return parse(arp.stdout).contains { $0.ip == router && $0.mac != nil }
    }

    /// 그 장치의 ARP 표 (자기 주소 제외). 읽기 실패면 nil
    public static func table(device: String, runner: any CommandRunner) async -> [ArpEntry]? {
        let result = await runner.run("arp", ["-an", "-i", device], timeout: 5)
        guard result.ok else { return nil }
        return parse(result.stdout).filter { !$0.permanent && $0.device == device }
    }

    /// 그 서비스 대역만: ip·mask(점 표기)로 정한 대역(예: 10.50.10.17/255.255.255.0 → 10.50.10.0–255)에 드는 이웃.
    /// 같은 NIC 에 서비스가 둘이면 다른 서비스 망의 이웃이 섞인다 (2026-10-15 Intranet 화면에 172.30.1.x). 대역 텍스트는 "10.50.10.0/24"
    public static func inSubnet(_ entries: [ArpEntry], ip: String, mask: String) -> (entries: [ArpEntry], subnet: String)? {
        guard let address = NetworkServiceDraft.ipv4(ip), let maskBits = NetworkServiceDraft.ipv4(mask),
              let prefix = NetworkInfoFetcher.prefixLength(mask: mask) else { return nil }
        let network = address & maskBits
        let kept = entries.filter { NetworkServiceDraft.ipv4($0.ip).map { $0 & maskBits == network } == true }
        let text = NetworkServiceDraft.dotted(network) + "/\(prefix)"
        return (kept, text)
    }

    // MARK: 이웃 찾기 — ARP 표는 최근 통신한 상대만 기억하므로(2026-10-15: 같은 대역의 .24 가 ping 전엔 표에 없었다) 먼저 대역에 ping 을 한 번씩

    /// 대역 안의 주소 전부 (네트워크·브로드캐스트·자기 주소 제외). 꼴이 틀리거나 /24(254 개)보다 넓으면 nil — 표만 읽는다.
    /// /31·/32 는 훑을 이웃이 없어 nil
    public static func sweepTargets(ip: String, mask: String) -> [String]? {
        guard let address = NetworkServiceDraft.ipv4(ip), let maskBits = NetworkServiceDraft.ipv4(mask),
              let prefix = NetworkInfoFetcher.prefixLength(mask: mask), prefix >= 24, prefix <= 30 else { return nil }
        let network = address & maskBits, broadcast = network | ~maskBits
        let hosts = (network + 1..<broadcast).filter { $0 != address }
        return hosts.map(NetworkServiceDraft.dotted)
    }

    /// 주소마다 ping 한 번(장치에 묶음, 1초)을 병렬로 (동시에 concurrency 개) — 응답은 보지 않는다, ARP 표를 채우는 게 목적
    public static func sweep(_ hosts: [String], device: String, runner: any CommandRunner, concurrency: Int = 64) async {
        await withTaskGroup(of: Void.self) { group in
            var next = hosts.makeIterator()
            for _ in 0..<min(concurrency, hosts.count) {
                guard let host = next.next() else { break }
                group.addTask { _ = await runner.run("ping", ["-c", "1", "-t", "1", "-b", device, host], timeout: 3) }
            }
            for await _ in group {
                guard let host = next.next() else { continue }
                group.addTask { _ = await runner.run("ping", ["-c", "1", "-t", "1", "-b", device, host], timeout: 3) }
            }
        }
    }

    /// 관리자 권한으로 읽는 스크립트 (앱 안에서 표가 가려졌을 때) — Touch ID 또는 승인 창
    public static func privilegedTableScript(device: String) -> String {
        LanCommands.privilegedScript(body: "sudo arp -an -i \(shellQuote(device))", prompt: "\(device) ARP 표 읽기")
    }

    /// ARP 캐시 비우기 (모든 장치 — arp 는 대역·장치를 골라 지우지 못한다). 다른 경로는 그대로, 다음 통신 때 다시 채워진다
    public static func clearCacheScript() -> String {
        LanCommands.privilegedScript(body: "sudo arp -a -d", prompt: "ARP 캐시 비우기")
    }
}

/// 진단 카드 ARP 표 한 번 읽은 결과
public struct ArpTableResult: Sendable, Equatable {
    public let device: String
    public let at: Date
    /// nil = 읽는 중 또는 읽기 실패
    public var entries: [ArpEntry]?
    /// 관리자 권한으로 읽었는가
    public var privileged: Bool
    /// 걸러 낸 대역 ("10.50.10.0/24"). nil = 거르지 않음 (VPN 등)
    public var subnet: String?
    /// ping 을 보낸 주소 수 (nil = 표만 읽음 — VPN·너무 넓은 대역)
    public var checked: Int?
    /// 응답한 장비의 제조사·임의 MAC·Windows 이름 (IP → 값, DeviceIdentity)
    public var identities: [String: DeviceIdentity] = [:]

    /// 응답한 장비 — MAC 이 잡힌 것만 (물었는데 답이 없는 incomplete 는 빼고)
    public var found: [ArpEntry]? { entries?.filter { $0.mac != nil } }

    public init(device: String, at: Date = Date(), entries: [ArpEntry]? = nil, privileged: Bool = false, subnet: String? = nil) {
        self.device = device; self.at = at; self.entries = entries; self.privileged = privileged; self.subnet = subnet
    }

    /// [복사] 텍스트
    public var reportText: String {
        var lines = ["ARP \(device)" + (subnet.map { " · \($0)" } ?? "") + (found.map { " · \($0.count)대 응답" } ?? "")
                     + (checked.map { " / \($0)개 확인" } ?? "") + " · \(at.formatted(date: .abbreviated, time: .standard))" + (privileged ? " · 관리자 권한" : "")]
        for entry in found ?? [] { lines.append("\(entry.ip)  \(entry.mac ?? "")" + (identities[entry.ip]?.text.map { "  \($0)" } ?? "")) }
        if found?.isEmpty == true { lines.append("응답한 장비 없음") }
        return lines.joined(separator: "\n")
    }
}
