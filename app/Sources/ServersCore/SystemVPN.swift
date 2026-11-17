// 시스템 설정의 VPN (scutil --nc): 목록 읽기 · 켜기/끄기 · 상세(읽기만). 구성(키·주소)은 만지지 않는다 — macOS 에 켜고 끄라고만 한다.
// wg-quick 으로 WireGuard 를 직접 다루던 코드는 문제가 많아 지웠다(2026-10-11). Tailscale 은 사이드바에 자기 행이 있어 뺀다.
// 루트 권한 필요 없음. 실제 출력: Tests/ServersCoreTests/Fixtures/scutil-nc-*.txt
// 공개키·Peer·handshake 같은 WireGuard 고유 값은 WireGuard 앱만 들고 있어 여기서 읽을 수 없다.

import Foundation

public struct SystemVPN: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case connected, connecting, disconnecting, disconnected, invalid
        case other(String)
    }

    public let id: String        // 서비스 UUID — scutil --nc start/stop 에 넘긴다 (이름은 겹칠 수 있다)
    public let name: String
    public let kind: String      // WireGuard · IPSec · L2TP · 앱 번들 끝 이름
    /// 현재 네트워크 위치에서 켜져 있는 서비스인가 (목록의 * 표시). 아니면 start 가 듣지 않는다 (scutil --nc select 가 먼저).
    public let enabled: Bool
    public var state: State

    public init(id: String, name: String, kind: String, enabled: Bool, state: State) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.state = state
    }

    /// 스위치 위치: 꺼짐·Invalid 가 아니면 켜짐 — 연결 중·끊는 중·그 밖의 상태(Reasserting 등)에서 [켜기] 를 보내지 않게
    public var isOn: Bool { state != .disconnected && state != .invalid }
    /// Invalid(앱이 지워졌거나 구성이 깨짐)·현재 위치에서 꺼진 서비스는 켜고 끌 수 없다
    public var canToggle: Bool { state != .invalid && enabled }

    public var stateText: String { Self.text(state) }

    static func text(_ state: State) -> String {
        switch state {
        case .connected: return "연결됨"
        case .connecting: return "연결 중"
        case .disconnecting: return "끊는 중"
        case .disconnected: return "꺼짐"
        case .invalid: return "Invalid"
        case .other(let word): return word
        }
    }
}

/// VPN 하나의 상세 (scutil --nc status · show · statistics, ifconfig). 없는 값은 nil·빈 배열.
public struct SystemVPNDetail: Sendable, Equatable {
    public var server: String?            // show: RemoteAddress (WireGuard 는 Endpoint)
    public var onDemand: Bool?            // show: OnDemandEnabled
    public var connectedAt: Date?         // status: LastStatusChangeTime (연결됨으로 바뀐 시각). 없으면 깨어 있던 시간 − VPN.ConnectTime 으로 거슬러 센다
    public var connectedSeconds: Int?     // 읽은 시각 − connectedAt
    public var interface: String?         // IPv4/IPv6.InterfaceName (utun7)
    public var mtu: Int?                  // ifconfig <인터페이스>
    public var ipv4: [String] = []
    public var ipv6: [String] = []
    public var routes: [String] = []      // AdditionalRoutes → "10.1.0.0/24"
    public var dnsServers: [String] = []
    public var searchDomains: [String] = []
    public var primary: Bool?             // IsPrimaryInterface — 인터넷 기본 경로가 이 VPN 인가
    public var bytesIn: Int64?            // statistics: VPN.BytesIn
    public var bytesOut: Int64?
    public var providerBundleID: String?  // show: NEProviderBundleIdentifier — 바깥 소켓 주인 (VPNEgress)
    public var egress: [VPNEgress] = []   // 암호화한 패킷이 나가는 물리 장치 (연결됐고 확장 프로세스를 찾았을 때만)
    public init() {}
}

/// scutil 의 `<dictionary> { … }` · `<array> { … }` 출력. 배열은 0·1·2 키를 가진 사전으로 둔다.
struct SCDictionary: Equatable {
    var values: [String: String] = [:]
    var children: [String: SCDictionary] = [:]

    static func parse(_ text: String) -> SCDictionary {
        var stack = [SCDictionary()]
        var names: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "}" {
                guard stack.count > 1, let name = names.popLast() else { continue }
                let done = stack.removeLast()
                if name.isEmpty, stack.count == 1 {   // 이름 없는 맨 바깥 "<dictionary> {" (statistics) 는 뿌리로
                    stack[0].values.merge(done.values) { $1 }
                    stack[0].children.merge(done.children) { $1 }
                } else {
                    stack[stack.count - 1].children[name] = done
                }
            } else if line.hasSuffix("{"), let open = line.range(of: "<", options: .backwards) {
                // "IPv4 : <dictionary> {" · "Extended Status <dictionary> {" · "<dictionary> {"
                var name = String(line[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
                if name.hasSuffix(":") { name = String(name.dropLast()).trimmingCharacters(in: .whitespaces) }
                names.append(name)
                stack.append(SCDictionary())
            } else if let colon = line.range(of: " :") {
                let key = String(line[..<colon.lowerBound])
                let value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                stack[stack.count - 1].values[key] = value
            }
        }
        while stack.count > 1, let name = names.popLast() {   // 잘린 출력: 닫히지 않은 사전도 살린다 (이름 없는 맨 바깥은 위와 같이 뿌리로)
            let done = stack.removeLast()
            if name.isEmpty, stack.count == 1 {
                stack[0].values.merge(done.values) { $1 }
                stack[0].children.merge(done.children) { $1 }
            } else {
                stack[stack.count - 1].children[name] = done
            }
        }
        return stack[0]
    }

    func child(_ path: String...) -> SCDictionary? {
        path.reduce(Optional(self)) { $0?.children[$1] }
    }

    /// 배열(0·1·2 키)의 값들 — 순서대로, 빈 값은 뺀다
    var list: [String] {
        values.compactMap { key, value in Int(key).map { ($0, value) } }.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.isEmpty }
    }

    /// 배열(0·1·2 키)의 사전들 — 순서대로
    var items: [SCDictionary] {
        children.compactMap { key, value in Int(key).map { ($0, value) } }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

public enum SystemVPNs {
    /// 목록에서 빼는 VPN 앱 (자기 행이 따로 있다)
    static let hiddenBundlePrefixes = ["io.tailscale."]
    /// 번들 ID → 보이는 종류 이름
    static let knownKinds = ["com.wireguard.macos": "WireGuard"]

    /// `* (Connected)      78CF…02C VPN (com.wireguard.macos) "MacBook"      [VPN:com.wireguard.macos]`
    public static func parse(_ text: String) -> [SystemVPN] {
        let pattern = #"^([* ]) \(([^)]*)\)\s+([0-9A-Fa-f-]{36})\s+.*?"(.*)"\s+\[([^\]]*)\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [SystemVPN] = []
        for line in text.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let group = { (i: Int) in ns.substring(with: m.range(at: i)) }
            let bracket = group(5)   // VPN:com.wireguard.macos · IPSec · PPP:L2TP
            let bundle = bracket.hasPrefix("VPN:") ? String(bracket.dropFirst(4)) : nil
            if let bundle, hiddenBundlePrefixes.contains(where: { bundle.hasPrefix($0) }) { continue }
            out.append(SystemVPN(id: group(3), name: group(4), kind: kind(bracket: bracket, bundle: bundle),
                                 enabled: group(1) == "*", state: state(group(2))))
        }
        return out
    }

    static func kind(bracket: String, bundle: String?) -> String {
        if let bundle { return knownKinds[bundle] ?? bundle.split(separator: ".").last.map(String.init) ?? bundle }
        return bracket.split(separator: ":").last.map(String.init) ?? bracket
    }

    public static func state(_ word: String) -> SystemVPN.State {
        switch word.trimmingCharacters(in: .whitespaces) {
        case "Connected": return .connected
        case "Connecting": return .connecting
        case "Disconnecting": return .disconnecting
        case "Disconnected": return .disconnected
        case "Invalid": return .invalid
        case let other: return .other(other)
        }
    }

    /// 사이드바 행·메뉴 요약: "MacBook 연결됨" · "2개 연결" · "꺼짐"
    public static func summary(_ vpns: [SystemVPN]) -> String {
        let on = vpns.filter { $0.state == .connected }
        if on.count == 1 { return "\(on[0].name) 연결됨" }
        if on.count > 1 { return "\(on.count)개 연결" }
        if let busy = vpns.first(where: { $0.state == .connecting || $0.state == .disconnecting }) { return "\(busy.name) \(busy.stateText)" }
        return "꺼짐"
    }

    /// 사이드바 VPN 행의 버튼: 켜진 게 있으면 끄기(켜진 것 전부), 없으면 켜기 — 켤 수 있는 게 하나면 그것, 여럿이면 고르게.
    public enum RowAction: Sendable, Equatable {
        case turnOff([SystemVPN])
        case turnOn(SystemVPN)
        case choose([SystemVPN])
        /// 켤 수 있는 VPN 이 없다 (전부 비활성·Invalid) — 버튼 비활성
        case unavailable
    }

    public static func rowAction(_ vpns: [SystemVPN]) -> RowAction {
        let on = vpns.filter { $0.isOn && $0.canToggle }
        if !on.isEmpty { return .turnOff(on) }
        let candidates = vpns.filter(\.canToggle)
        switch candidates.count {
        case 0: return .unavailable
        case 1: return .turnOn(candidates[0])
        default: return .choose(candidates)
        }
    }

    /// 목록을 읽는다. 명령이 실패하면 nil (빈 목록과 구분 — 화면이 "없음"으로 바뀌지 않게)
    public static func list(runner: any CommandRunner) async -> [SystemVPN]? {
        let result = await runner.run("scutil", ["--nc", "list"], timeout: 5)
        guard result.ok else { return nil }
        return parse(result.stdout)
    }

    /// 켜기/끄기: start/stop 을 보낸 뒤 상태가 목표(연결됨/꺼짐)가 될 때까지 기다린다. 성공이면 nil, 실패면 화면에 띄울 문구.
    /// scutil 은 요청만 보내고 바로 끝나서(연결 실패도 종료 코드 0) 결과는 상태로 본다.
    /// 켤 때 꺼짐이 settle 초 넘게 이어지면(연결 중을 못 봤어도) 실패로 본다 — 0.5초 안에 끝난 빠른 실패를 timeout 까지 기다리지 않게.
    public static func set(_ vpn: SystemVPN, on: Bool, runner: any CommandRunner,
                           timeout: TimeInterval = 20, interval: TimeInterval = 0.5, settle: TimeInterval = 3) async -> String? {
        let verb = on ? "켜지" : "끄지"
        let sent = await runner.run("scutil", ["--nc", on ? "start" : "stop", vpn.id], timeout: 10)
        guard sent.ok else {
            let detail = (sent.stderr + sent.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(vpn.name) VPN 을 \(verb) 못했습니다" + (detail.isEmpty ? "" : " · \(detail)")
        }
        let target: SystemVPN.State = on ? .connected : .disconnected
        var last: SystemVPN.State?
        var moved = false   // 연결 중·끊는 중을 거쳤는가
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        repeat {
            let status = await runner.run("scutil", ["--nc", "status", vpn.id], timeout: 5)
            let word = status.stdout.split(separator: "\n").first.map(String.init) ?? ""
            last = word.isEmpty ? last : state(word)
            if last == target { return nil }
            if last == .connecting || last == .disconnecting { moved = true }
            // 연결 중을 거쳐 다시 꺼짐, 또는 꺼짐이 settle 초 넘게 그대로면 연결 실패
            if on, last == .disconnected, moved || Date().timeIntervalSince(started) > settle { break }
            if interval > 0 { try? await Task.sleep(for: .seconds(interval)) }
        } while Date() < deadline
        return "\(vpn.name) VPN 을 \(verb) 못했습니다 · 지금 상태 \(last.map(SystemVPN.text) ?? "알 수 없음")"
    }

    // MARK: 상세

    /// 연결을 시작한 시각.
    /// VPN.ConnectTime 은 "연결된 지 몇 초"가 아니라 연결한 순간의 깨어 있던 시간(부팅 뒤 잠든 시간을 뺀 초) 도장이다 — 그대로 길이로 쓰면
    /// 방금 켠 VPN 이 "15시간 39분"으로 나왔다 (2026-11-10 실측: 방금 켠 연결의 ConnectTime 56367, 그때 깨어 있던 시간 56588 → 221초 전.
    /// 같은 순간 LastStatusChangeTime 은 221초 전 시각). 2026-10-15 의 "ConnectTime 17372 인데 LastStatusChangeTime 이 방금"도 같은 일이었다.
    /// 그래서 벽시계로 찍힌 LastStatusChangeTime 을 쓴다 (잠든 시간이 끼어도 "언제부터"가 맞는다). 없거나 미래면 깨어 있던 시간으로 거슬러 센다.
    static func connectedAt(lastStatusChange: String?, connectTime: Double?, now: Date, uptime: TimeInterval?, timeZone: TimeZone) -> Date? {
        if let lastStatusChange {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
            if let at = formatter.date(from: lastStatusChange), at <= now.addingTimeInterval(60) { return min(at, now) }
        }
        guard let connectTime, let uptime, uptime >= connectTime else { return nil }
        return now.addingTimeInterval(-(uptime - connectTime))
    }

    /// 상세를 읽는다 (읽기만). 연결된 VPN 만 주소·경로·통계가 있다.
    /// egressCache 가 있으면 바깥 장치는 망 조건(network)이 같은 동안 그 값을 쓴다 (ps·nettop·route 를 5초마다 돌지 않게)
    public static func detail(_ vpn: SystemVPN, runner: any CommandRunner, egressCache: VPNEgressCache? = nil, network: String = "") async -> SystemVPNDetail {
        // 세 읽기는 서로 기다릴 게 없다 — 함께 돌린다 (VPN 화면이 5초마다 부른다)
        async let showRead = runner.run("scutil", ["--nc", "show", vpn.id], timeout: 5)
        async let statusRead = runner.run("scutil", ["--nc", "status", vpn.id], timeout: 5)
        async let statsRead: CommandResult? = vpn.state == .connected ? runner.run("scutil", ["--nc", "statistics", vpn.id], timeout: 5) : nil
        let (show, status, stats) = await (showRead, statusRead, statsRead)
        var detail = parseDetail(show: show.ok ? show.stdout : "", status: status.ok ? status.stdout : "", statistics: stats?.ok == true ? stats!.stdout : "")
        if let interface = detail.interface {
            let ifconfig = await runner.run("ifconfig", [interface], timeout: 5)
            if ifconfig.ok { detail.mtu = mtu(ifconfig.stdout) }
        }
        if vpn.state == .connected, let bundle = detail.providerBundleID {
            detail.egress = await egressFetch(vpn, bundle: bundle, tunnel: detail.interface, cache: egressCache, network: network, force: false, runner: runner)
        }
        return detail
    }

    /// Routes 카드용: 연결된 VPN 의 (터널 장치, 나가는 장치) — show · status 와 VPNEgress 만 (통계·ifconfig 는 안 읽는다)
    public static func egress(_ vpn: SystemVPN, runner: any CommandRunner, egressCache: VPNEgressCache? = nil, network: String = "",
                              force: Bool = false) async -> (tunnel: String, egress: [VPNEgress])? {
        guard vpn.state == .connected else { return nil }
        let show = await runner.run("scutil", ["--nc", "show", vpn.id], timeout: 5)
        let status = await runner.run("scutil", ["--nc", "status", vpn.id], timeout: 5)
        let detail = parseDetail(show: show.ok ? show.stdout : "", status: status.ok ? status.stdout : "", statistics: "")
        guard let tunnel = detail.interface, let bundle = detail.providerBundleID else { return nil }
        return (tunnel, await egressFetch(vpn, bundle: bundle, tunnel: tunnel, cache: egressCache, network: network, force: force, runner: runner))
    }

    private static func egressFetch(_ vpn: SystemVPN, bundle: String, tunnel: String?, cache: VPNEgressCache?, network: String, force: Bool,
                                    runner: any CommandRunner) async -> [VPNEgress] {
        guard let cache else { return await VPNEgresses.fetch(providerBundleID: bundle, tunnel: tunnel, runner: runner) }
        return await cache.fetch(vpnID: vpn.id, providerBundleID: bundle, tunnel: tunnel, network: network, force: force, runner: runner)
    }

    /// 연결된 VPN 의 인터페이스(utun5)만 — 상태 확인이 5초마다 부른다 (detail 보다 가볍게 status 하나). 못 읽으면 nil.
    public static func interface(_ vpn: SystemVPN, runner: any CommandRunner) async -> String? {
        let status = await runner.run("scutil", ["--nc", "status", vpn.id], timeout: 5)
        return status.ok ? parseDetail(show: "", status: status.stdout, statistics: "").interface : nil
    }

    /// uptime: 이 Mac 이 깨어 있던 시간(ProcessInfo.systemUptime — 잠든 시간 제외). timeZone: LastStatusChangeTime 이 찍힌 시간대(이 Mac 의 것)
    static func parseDetail(show: String, status: String, statistics: String, now: Date = Date(),
                            uptime: TimeInterval? = ProcessInfo.processInfo.systemUptime, timeZone: TimeZone = .current) -> SystemVPNDetail {
        var detail = SystemVPNDetail()
        let config = SCDictionary.parse(show).child("VPN")
        detail.server = config?.values["RemoteAddress"].flatMap { $0.isEmpty ? nil : $0 }
        detail.onDemand = config?.values["OnDemandEnabled"].flatMap(flag)
        detail.providerBundleID = config?.values["NEProviderBundleIdentifier"].flatMap { $0.isEmpty ? nil : $0 }

        let connected = state(status.split(separator: "\n").first.map(String.init) ?? "") == .connected
        guard connected, let extended = SCDictionary.parse(status).child("Extended Status") else { return detail }
        let v4 = extended.child("IPv4"), v6 = extended.child("IPv6")
        detail.interface = v4?.values["InterfaceName"] ?? v6?.values["InterfaceName"]
        detail.ipv4 = v4?.child("Addresses")?.list ?? []
        detail.ipv6 = v6?.child("Addresses")?.list ?? []
        detail.routes = (v4?.child("AdditionalRoutes")?.items ?? []).compactMap { route in
            guard let dest = route.values["DestinationAddress"] else { return nil }
            return route.values["SubnetMask"].flatMap(NetworkInfoFetcher.prefixLength(mask:)).map { "\(dest)/\($0)" } ?? dest
        } + (v6?.child("AdditionalRoutes")?.items ?? []).compactMap { route in
            guard let dest = route.values["DestinationAddress"] else { return nil }
            return route.values["PrefixLength"].map { "\(dest)/\($0)" } ?? dest
        }
        detail.dnsServers = extended.child("DNSServers")?.list ?? []
        detail.searchDomains = extended.child("DNSSearchDomains")?.list ?? []
        detail.primary = extended.values["IsPrimaryInterface"].flatMap(flag)
        detail.connectedAt = connectedAt(lastStatusChange: extended.values["LastStatusChangeTime"],
                                         connectTime: extended.child("VPN")?.values["ConnectTime"].flatMap { Double($0) },
                                         now: now, uptime: uptime, timeZone: timeZone)
        detail.connectedSeconds = detail.connectedAt.map { max(0, Int(now.timeIntervalSince($0).rounded())) }

        let counters = SCDictionary.parse(statistics).child("VPN")
        detail.bytesIn = counters?.values["BytesIn"].flatMap { Int64($0) }
        detail.bytesOut = counters?.values["BytesOut"].flatMap { Int64($0) }
        return detail
    }

    static func flag(_ text: String) -> Bool? {
        switch text.uppercased() {
        case "1", "TRUE", "YES": return true
        case "0", "FALSE", "NO": return false
        default: return nil
        }
    }

    static func mtu(_ ifconfig: String) -> Int? {
        guard let range = ifconfig.range(of: #"mtu (\d+)"#, options: .regularExpression) else { return nil }
        return Int(ifconfig[range].dropFirst(4))
    }

    /// "203.0.113.10:51820" → ("203.0.113.10", "51820") · "[2001:db8::1]:51820" → ("2001:db8::1", "51820") · 포트 없으면 nil
    public static func splitEndpoint(_ endpoint: String) -> (host: String, port: String?) {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            let rest = endpoint[endpoint.index(after: close)...]
            return (host, rest.hasPrefix(":") ? String(rest.dropFirst()) : nil)
        }
        // 콜론이 하나일 때만 host:port (대괄호 없는 IPv6 는 통째로 host)
        let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, Int(parts[1]) != nil else { return (endpoint, nil) }
        return (String(parts[0]), String(parts[1]))
    }

    /// 연결된 시간: "25분 47초" · "3시간 2분" · "2일 4시간"
    public static func duration(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = seconds % 86_400 / 3600, m = seconds % 3600 / 60, s = seconds % 60
        if d > 0 { return "\(d)일 \(h)시간" }
        if h > 0 { return "\(h)시간 \(m)분" }
        if m > 0 { return "\(m)분 \(s)초" }
        return "\(s)초"
    }
}
