// 리눅스 원격 정보(Network · Schedule) 출력의 구조화. 스크립트는 LinuxInfoScripts, 실제 출력은 Tests/ServersCoreTests/Fixtures/linux-*.txt (ubuntu:24.04 컨테이너).
// 읽기만 한다 — 조치(재시작·kill 등)는 넣지 않기로 했다 (2026-11-07).

import Foundation

// MARK: Network

public struct LinuxNetInterface: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// operstate UP, 또는 UNKNOWN 이어도 UP 플래그가 있는 것 (tun · wireguard 는 UNKNOWN 으로 찍힌다)
    public let up: Bool
    /// 이름·link_type 에서 짐작한 종류: bridge · veth · wireguard · tunnel. 보통 이더넷은 nil
    public let kind: String?
    /// 브리지에 묶인 포트면 그 브리지
    public let master: String?
    public let mac: String?
    public let mtu: Int?
    /// "192.168.8.103/24" — IPv4 다음 IPv6 (링크로컬 fe80:: 은 뺀다)
    public let addresses: [String]
    public let rxBytes: UInt64?
    public let txBytes: UInt64?
    /// 이름 옆에 더 적을 것 (Windows: 어댑터 설명 · 링크 속도). 리눅스는 nil
    public var detail: String? = nil

    public var ipv4: [String] { addresses.filter { !$0.contains(":") } }

    /// 이름 옆 설명: 종류 · 브리지
    public var descriptors: [String] { [kind, master.map { "in \($0)" }, detail.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 } }
    /// 평소엔 접어 두는 것: 컨테이너 배선(veth · 브리지). 주소 없는 실제 NIC(안 꽂힌 이더넷 · Wi-Fi)는 회색 점으로 본 목록에 둔다 (2026-11-07)
    /// Windows 는 가상 어댑터(Hyper-V · WSL 스위치)가 같은 자리다
    public var isFolded: Bool { kind == "veth" || kind == "bridge" || kind == "virtual" }
}

public struct LinuxNetworkLayout: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String { interface.id }
        public let interface: LinuxNetInterface
        /// 행 아래에 늘 보이는 경로: 게이트웨이를 타거나 자기 대역이 아닌 것
        public let routes: [OpenWrtRoute]
        /// 펼쳐야 보이는 경로: 인터페이스 주소와 같은 내용인 자기 대역 On-link
        public let subnetRoutes: [OpenWrtRoute]
        public var hasDetail: Bool { !interface.addresses.isEmpty || interface.mac != nil || !subnetRoutes.isEmpty }
    }
    public var items: [Item] = []
    /// 인터페이스에 묶이지 않는 경로 (다른 테이블 · 목록에 없는 장치 · blackhole 등)
    public var otherRoutes: [OpenWrtRoute] = []

    public var visibleItems: [Item] { items.filter { !$0.interface.isFolded } }
    public var foldedItems: [Item] { items.filter { $0.interface.isFolded } }
}

public struct LinuxNetwork: Sendable, Equatable {
    /// loopback 제외. IPv4 주소가 있는 것 먼저, 그 안에서는 ip 가 찍은 순서
    public var interfaces: [LinuxNetInterface] = []
    /// ip 가 없거나 경로를 하나도 읽지 못하면 nil
    public var routing: OpenWrtRouting?
    /// resolvectl dns 의 서버 (없으면 /etc/resolv.conf 의 nameserver)
    public var dns: [String] = []
    public var searchDomains: [String] = []
    public var layout = LinuxNetworkLayout()
    /// 접어 두는 묶음의 이름 (Windows 는 "가상 어댑터")
    public var foldedTitle = "컨테이너 네트워크"

    /// Network 스크립트 출력. @ADDR 의 JSON(ip -j -s addr)을 못 읽으면 nil — 화면은 원문을 보여 준다
    public static func parse(_ lines: [String]) -> LinuxNetwork? {
        guard let s = ScriptSections.parse(lines.joined(separator: "\n"), dropEmpty: false),
              let list = OpenWrt.json(s["ADDR"]) as? [[String: Any]] else { return nil }
        var result = LinuxNetwork()
        var parsed: [LinuxNetInterface] = []
        for item in list {
            guard let name = item["ifname"] as? String, name != "lo" else { continue }
            let flags = item["flags"] as? [String] ?? []
            let operstate = item["operstate"] as? String ?? ""
            let up = operstate == "UP" || (operstate != "DOWN" && flags.contains("UP") && flags.contains("LOWER_UP"))
            let linkType = item["link_type"] as? String ?? ""
            var addresses: [String] = []
            for info in item["addr_info"] as? [[String: Any]] ?? [] {
                guard let family = info["family"] as? String, let local = info["local"] as? String else { continue }
                if family == "inet6", (info["scope"] as? String) == "link" { continue }
                let text = (info["prefixlen"] as? NSNumber).map { "\(local)/\($0)" } ?? local
                if family == "inet" { addresses.insert(text, at: addresses.filter { !$0.contains(":") }.count) } else { addresses.append(text) }
            }
            let stats = item["stats64"] as? [String: Any]
            func bytes(_ key: String) -> UInt64? { ((stats?[key] as? [String: Any])?["bytes"] as? NSNumber)?.uint64Value }
            let mac = (item["address"] as? String).flatMap { $0.isEmpty || $0 == "00:00:00:00:00:00" ? nil : $0 }
            parsed.append(LinuxNetInterface(name: name, up: up, kind: kind(name: name, linkType: linkType), master: item["master"] as? String,
                                         mac: mac, mtu: (item["mtu"] as? NSNumber)?.intValue, addresses: addresses, rxBytes: bytes("rx"), txBytes: bytes("tx")))
        }
        result.interfaces = parsed.filter { !$0.ipv4.isEmpty } + parsed.filter { $0.ipv4.isEmpty }
        result.routing = OpenWrtRouting.parse(rules: s["RULES"] ?? [], routes: s["ROUTES"] ?? [], interfaceNames: [:])
        (result.dns, result.searchDomains) = dns(servers: s["DNS"] ?? [], domains: s["DOMAIN"] ?? [], resolv: s["RESOLV"] ?? [])
        result.layout = layout(result.interfaces, routing: result.routing)
        return result
    }

    /// 이름·link_type 으로 짐작한 종류 (ip -j addr 에는 linkinfo 가 없다)
    static func kind(name: String, linkType: String) -> String? {
        if name.hasPrefix("veth") { return "veth" }
        if name.hasPrefix("br-") || name.hasPrefix("br") && name.dropFirst(2).allSatisfy(\.isNumber) || name.hasPrefix("docker") || name.hasPrefix("virbr") || name.hasPrefix("cni") || name.hasPrefix("flannel") { return "bridge" }
        if name.hasPrefix("wg") { return "wireguard" }
        if name.hasPrefix("tun") || name.hasPrefix("tap") || name.hasPrefix("tailscale") || name.hasPrefix("utun") || linkType == "none" { return "tunnel" }
        return nil
    }

    /// `resolvectl dns` · `resolvectl domain` 줄("Global: 1.1.1.1" · "Link 2 (eth0): 192.168.8.1 fd00::1") 이 있으면 그것, 없으면 resolv.conf 의 nameserver · search.
    /// 링크마다 한 줄이라 status 와 달리 긴 목록이 다음 줄로 넘어가지 않는다. 값은 첫 "): " 또는 "Global:" 뒤 (IPv6 의 ':' 와 안 헷갈리게)
    static func dns(servers serverLines: [String], domains domainLines: [String], resolv: [String]) -> (servers: [String], domains: [String]) {
        var servers: [String] = [], domains: [String] = []
        func add(_ values: [String], to list: inout [String]) { for v in values where !v.isEmpty && !list.contains(v) { list.append(v) } }
        func values(_ line: String) -> [String] {
            let t = line.trimmingCharacters(in: .whitespaces)
            let rest: Substring
            if t.hasPrefix("Global:") { rest = t.dropFirst(7) }
            else if let r = t.range(of: "): ") { rest = t[r.upperBound...] }
            else if t.hasSuffix("):") { rest = "" }
            else { return [] }
            return rest.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        for line in serverLines { add(values(line), to: &servers) }
        for line in domainLines { add(values(line).filter { $0 != "~." }, to: &domains) }   // "~." 는 라우팅 전용 표시
        if servers.isEmpty {
            for line in resolv {
                let tokens = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).map(String.init)
                guard let key = tokens.first, !key.hasPrefix("#") else { continue }
                if key == "nameserver" { add(Array(tokens.dropFirst()), to: &servers) }
                if key == "search" || key == "domain" { add(Array(tokens.dropFirst()), to: &domains) }
            }
        }
        return (servers, domains)
    }

    static func layout(_ interfaces: [LinuxNetInterface], routing: OpenWrtRouting?) -> LinuxNetworkLayout {
        var layout = LinuxNetworkLayout()
        let routes = routing?.routes ?? []
        let names = Set(interfaces.map(\.name))
        for iface in interfaces {
            let mine = routes.filter { $0.table == "main" && $0.device == iface.name && $0.kind == nil }
            let subnet = mine.filter { route in route.gateway == nil && iface.ipv4.contains { IPv4Prefix.sameNetwork($0, route.destination) } }
            layout.items.append(.init(interface: iface, routes: mine.filter { !subnet.contains($0) }, subnetRoutes: subnet))
        }
        layout.otherRoutes = routes.filter { !($0.table == "main" && $0.kind == nil && $0.device.map(names.contains) == true) }
        return layout
    }
}

// MARK: Schedule (systemd 타이머 · cron)

public struct SystemdTimer: Sendable, Equatable, Identifiable {
    public var id: String { unit }
    /// "apt-daily.timer"
    public let unit: String
    /// "apt-daily.service"
    public let activates: String
    /// 다음·지난 실행. nil = 없음 (한 번도 안 돌았거나 다음 예정이 없음)
    public let next: Date?
    public let last: Date?

    /// 이름: ".timer" 를 뗀 것
    public var name: String { unit.hasSuffix(".timer") ? String(unit.dropLast(6)) : unit }
    /// 돌리는 서비스가 이름과 다를 때만 보인다 (apt-daily.timer → apt-daily.service 는 뺀다)
    public var activatesIfDifferent: String? {
        let base = activates.hasSuffix(".service") ? String(activates.dropLast(8)) : activates
        return base == name ? nil : activates
    }
}

public struct CronEntry: Sendable, Equatable, Identifiable {
    public let id: String
    /// "0 3 * * *" · "@reboot"
    public let schedule: String
    /// 시스템 crontab(/etc/crontab · cron.d)의 실행 사용자. 내 crontab 은 nil (화면이 접속 계정을 넣는다)
    public let user: String?
    public let command: String
    /// "crontab" · "/etc/crontab" · "/etc/cron.d/weekly-report"
    public let source: String

    /// 사람이 읽는 주기 (CronSchedule.describe). 못 읽는 꼴이면 nil — 화면은 원문만
    public var description: String? { CronSchedule.describe(schedule) }
}

public struct PeriodicJobs: Sendable, Equatable, Identifiable {
    public var id: String { period }
    /// hourly · daily · weekly · monthly
    public let period: String
    public let jobs: [String]
}

public struct ScheduleReport: Sendable, Equatable {
    /// 서버 시각 (date +%s) — 타이머의 "n분 뒤" 는 이 기준
    public let now: Date
    /// nil = systemd 가 없거나 목록을 못 읽음. 다음 실행이 가까운 순, 예정 없는 것은 뒤
    public let timers: [SystemdTimer]?
    /// 내 crontab → /etc/crontab → /etc/cron.d/* (파일 순서). 다른 사용자의 crontab 은 root 만 읽을 수 있어 넣지 않는다 (sudo 를 쓰지 않기로, 2026-11-07)
    public let cron: [CronEntry]
    /// /etc/cron.{hourly,daily,weekly,monthly} 의 작업 이름 (빈 것은 뺀다)
    public let periodic: [PeriodicJobs]

    /// 각 출처의 항목 (화면 묶음). 출처는 등장 순서
    public var cronBySource: [(source: String, entries: [CronEntry])] {
        var order: [String] = []
        for entry in cron where !order.contains(entry.source) { order.append(entry.source) }
        return order.map { source in (source, cron.filter { $0.source == source }) }
    }

    public static func parse(_ lines: [String]) -> ScheduleReport? {
        guard let s = ScriptSections.parse(lines.joined(separator: "\n"), dropEmpty: false), let now = OpenWrt.now(s) else { return nil }
        var timers: [SystemdTimer]?
        // 스크립트는 json 을 못 받거나 systemd 가 없으면 @NOTIMERS 를 찍는다 (구역 머리 규칙: @ 뒤 대문자만). 옛 systemd 가 표를 찍으면 JSON 이 아니라 nil
        if s["NOTIMERS"] == nil, let list = OpenWrt.json(s["TIMERS"]) as? [[String: Any]] {
            func date(_ value: Any?) -> Date? {
                guard let usec = (value as? NSNumber)?.doubleValue, usec > 0 else { return nil }
                return Date(timeIntervalSince1970: usec / 1_000_000)
            }
            timers = list.compactMap { item in
                guard let unit = item["unit"] as? String else { return nil }
                return SystemdTimer(unit: unit, activates: item["activates"] as? String ?? "", next: date(item["next"]), last: date(item["last"]))
            }
            .sorted { a, b in
                switch (a.next, b.next) {
                case let (x?, y?): return x != y ? x < y : a.unit < b.unit
                case (nil, nil): return a.unit < b.unit
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        }
        var cron: [CronEntry] = []
        cron += entries(s["CRONTAB"] ?? [], source: "crontab", systemFormat: false)
        cron += entries(s["ETC"] ?? [], source: "/etc/crontab", systemFormat: true)
        for (path, body) in grouped(s["CROND"] ?? []) { cron += entries(body, source: path, systemFormat: true) }
        let periodic = grouped(s["PERIODIC"] ?? []).compactMap { period, names -> PeriodicJobs? in
            let jobs = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix(".") }
            return jobs.isEmpty ? nil : PeriodicJobs(period: period, jobs: jobs)
        }
        return ScheduleReport(now: Date(timeIntervalSince1970: now), timers: timers, cron: cron, periodic: periodic)
    }

    /// "== 이름" 머리로 나뉜 묶음 (등장 순서)
    static func grouped(_ lines: [String]) -> [(String, [String])] {
        var result: [(String, [String])] = []
        for line in lines {
            if line.hasPrefix("== ") { result.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])) }
            else if !result.isEmpty { result[result.count - 1].1.append(line) }
        }
        return result
    }

    /// crontab 본문 → 항목. 주석·빈 줄·변수(SHELL=…)는 뺀다. systemFormat 이면 주기 다음이 사용자.
    static func entries(_ lines: [String], source: String, systemFormat: Bool) -> [CronEntry] {
        var result: [CronEntry] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) == nil else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let scheduleCount = line.hasPrefix("@") ? 1 : 5
            let userIndex = scheduleCount, commandIndex = systemFormat ? scheduleCount + 1 : scheduleCount
            guard tokens.count > commandIndex else { continue }
            let schedule = tokens[..<scheduleCount].joined(separator: " ")
            let runAs: String? = systemFormat ? tokens[userIndex] : nil
            result.append(CronEntry(id: "\(source)||\(index)", schedule: schedule, user: runAs,
                                    command: tokens[commandIndex...].joined(separator: " "), source: source))
        }
        return result
    }
}

/// cron 주기 → 한국어 한 마디. 숫자 하나짜리 칸만 풀고, 목록·범위가 섞이면 nil (원문을 보인다).
public enum CronSchedule {
    static let days = ["일", "월", "화", "수", "목", "금", "토"]

    public static func describe(_ schedule: String) -> String? {
        switch schedule {
        case "@reboot": return "부팅 때"
        case "@hourly": return "매시 00분"
        case "@daily", "@midnight": return "매일 00:00"
        case "@weekly": return "매주 일 00:00"
        case "@monthly": return "매월 1일 00:00"
        case "@yearly", "@annually": return "매년 1월 1일 00:00"
        default: break
        }
        let f = schedule.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5 else { return nil }
        let (m, h, dom, mon, dow) = (f[0], f[1], f[2], f[3], f[4])
        func every(_ field: String) -> Int? { field.hasPrefix("*/") ? Int(field.dropFirst(2)) : nil }
        func time() -> String? {
            guard let mm = Int(m), let hh = Int(h), (0...59).contains(mm), (0...23).contains(hh) else { return nil }
            return String(format: "%02d:%02d", hh, mm)
        }
        if dom == "*", mon == "*", dow == "*" {
            if m == "*", h == "*" { return "매분" }
            if let t = time() { return "매일 \(t)" }
            if let n = every(m), h == "*" { return n == 1 ? "매분" : "\(n)분마다" }
            if let mm = Int(m), (0...59).contains(mm), h == "*" { return "매시 \(String(format: "%02d", mm))분" }
            if let n = every(h), let mm = Int(m), (0...59).contains(mm) { return n == 1 ? "매시 \(String(format: "%02d", mm))분" : "\(n)시간마다 \(String(format: "%02d", mm))분" }
            return nil
        }
        if dom == "*", mon == "*", let d = Int(dow), (0...7).contains(d), let t = time() { return "매주 \(days[d % 7]) \(t)" }
        if dow == "*", mon == "*", let d = Int(dom), (1...31).contains(d), let t = time() { return "매월 \(d)일 \(t)" }
        if dow == "*", let d = Int(dom), let mo = Int(mon), (1...31).contains(d), (1...12).contains(mo), let t = time() { return "매년 \(mo)월 \(d)일 \(t)" }
        return nil
    }
}
