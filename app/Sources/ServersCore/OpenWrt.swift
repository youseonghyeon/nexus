// OpenWrt 공유기(type=openwrt)의 원격 정보: Spec · Network · Firewall · Clients · WireGuard · Services · Ports 스크립트와 파서.
// 리눅스 스크립트는 bash·systemd·ss·lscpu 를 쓰는데 OpenWrt 에는 없다 (busybox ash · procd · ubus · uci). 스크립트는 읽기만 한다.
// 출력 실례: Tests/ServersCoreTests/Fixtures/openwrt-*.txt — 로컬 openwrt/rootfs:x86-64-23.05.5 컨테이너를 procd 로 부팅해 받은 것.
// routes-mt5000 · firewall · switch-mt5000 만 사용자가 준 GL-MT5000 실제 출력이다. 경로·정책 규칙 파서는 IPRouting.swift.

import Foundation

public enum OpenWrt {
    /// RemoteInfo.parseSpec 이 그대로 읽는 "KEY          value" 형식. 모델은 보드 이름(/tmp/sysinfo/model), GL.iNet 펌웨어면 버전을 OS 에 붙인다.
    public static let specScript = #"""
    export LC_ALL=C
    printf '%-12s %s\n' 'HOSTNAME' "$(cat /proc/sys/kernel/hostname)"
    [ -r /etc/openwrt_release ] && . /etc/openwrt_release
    os=${DISTRIB_DESCRIPTION:-OpenWrt}
    [ -r /etc/glversion ] && os="$os · GL.iNet $(cat /etc/glversion)"
    printf '%-12s %s\n' 'OS' "$os"
    printf '%-12s %s\n' 'KERNEL' "$(uname -r)"
    printf '%-12s %s\n' 'ARCH' "${DISTRIB_TARGET:-$(uname -m)}"
    model=$(cat /tmp/sysinfo/model 2>/dev/null); [ -n "$model" ] || model=$({ tr -d '\000' < /proc/device-tree/model; } 2>/dev/null)
    printf '%-12s |%s||\n' 'MODEL' "$model"
    cpu=$(awk -F': *' '/^(model name|Model name|Hardware|cpu model|system type)[ \t]*:/ && $2 != "" { print $2; exit }' /proc/cpuinfo 2>/dev/null)
    threads=$(grep -c '^processor' /proc/cpuinfo)
    if [ -n "$cpu" ]; then printf '%-12s %s (%s threads)\n' 'CPU' "$cpu" "$threads"; else printf '%-12s %s threads\n' 'CPU' "$threads"; fi
    awk 'function h(k) { return k >= 1048576 ? sprintf("%.1fGi", k / 1048576) : sprintf("%dMi", k / 1024) }
      /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%-12s %s total, %s available\n", "MEMORY", h(t), h(a) }' /proc/meminfo
    df -Pk / | awk 'function h(k) { return k >= 1048576 ? sprintf("%.1fGi", k / 1048576) : sprintf("%dMi", k / 1024) }
      NR == 2 { printf "%-12s %s total, %s used, %s available (%s)\n", "ROOT DISK", h($2), h($3), h($4), $5 }'
    printf '%-12s %s\n' 'UPTIME' "$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)"
    """#

    /// 논리 인터페이스(wan·lan·wgserver …)와 장치(포트 링크·바이트) — ubus JSON 그대로.
    /// 경로는 정책 규칙과 전체 테이블까지 받는다 — main 의 default 만 보면 VPN 정책으로 나가는 트래픽을 놓친다. local·broadcast 는 장비 자기 주소라 뺀다.
    public static let networkScript = """
    echo @IFACES; ubus call network.interface dump
    echo @DEVICES; ubus call network.device status
    if command -v ip >/dev/null 2>&1; then
      echo @RULES; ip rule show 2>/dev/null
      echo @ROUTES; ip -4 route show table all 2>/dev/null | grep -vE '^(local|broadcast|multicast) ' | head -n 200
    fi
    if command -v swconfig >/dev/null 2>&1 && [ -r /etc/board.json ]; then
      echo @BOARD; cat /etc/board.json
      echo @SWITCH
      t=; command -v timeout >/dev/null 2>&1 && t='timeout 5'
      for s in $(swconfig list 2>/dev/null | awk '{print $2}'); do
        echo "switch $s"; $t swconfig dev "$s" show 2>/dev/null | grep 'link: port:'
      done
    fi
    echo @END
    """

    /// 방화벽 설정 그대로 (OpenWrtFirewall 이 읽는다). GL.iNet 관리 화면의 포트 포워딩은 firewall 이 아니라 port_forward 에 저장된다 (없는 펌웨어면 빈 구역).
    public static let firewallScript = """
    echo @UCI; uci -q show firewall
    echo @PORTFORWARD; uci -q show port_forward 2>/dev/null
    echo @END
    """

    /// DHCP 임대(dnsmasq) · 고정 할당(uci dhcp host) · 이웃 상태(ip neigh — 없으면 ARP 표) · GL.iNet 별칭(uci gl-client, 없으면 빈 구역).
    /// 임대 만료는 공유기 시계 기준이라 그 시각도 받는다.
    public static let clientsScript = """
    echo @NOW; date +%s
    echo @LEASES; cat /tmp/dhcp.leases 2>/dev/null
    echo @STATIC; uci -q show dhcp
    echo @ARP; cat /proc/net/arp
    if command -v ip >/dev/null 2>&1; then echo @NEIGH; ip neigh show 2>/dev/null; fi
    echo @ALIAS; uci -q show gl-client
    echo @END
    """

    /// wg 덤프. 개인 키(인터페이스 줄 2번째)·사전 공유 키(피어 줄 3번째)는 서버에서 지우고 보낸다 — 앱에 들어오지 않게.
    /// 칸 수가 5·9 가 아닌 줄은 어디가 키인지 몰라 아예 보내지 않는다 (파서도 5·9 칸만 읽는다).
    /// 피어 이름은 uci 의 description(OpenWrt 기본) · name 을 공개 키로 잇는다 (wireguard_server · wireguard 는 GL.iNet 펌웨어의 서버·클라이언트 설정 — 추정, 없으면 조용히 빈다).
    public static let wireguardScript = #"""
    echo @NOW; date +%s
    if command -v wg >/dev/null 2>&1; then
      echo @WG; wg show all dump 2>/dev/null | awk 'BEGIN { FS = OFS = "\t" } NF == 5 { $2 = "-"; print } NF == 9 { if ($3 != "(none)") $3 = "-"; print }'
    else
      echo @NOWG
    fi
    echo @NAMES; uci -q show network | grep -E '\.(public_key|description|name)='; uci -q show wireguard_server 2>/dev/null | grep -E '\.(public_key|description|name)='; uci -q show wireguard 2>/dev/null | grep -E '\.(public_key|description|name)='
    echo @END
    """#

    /// procd 가 아는 서비스(인스턴스·실행 여부)와 /etc/init.d 스크립트별 부팅 시 켜짐(/etc/rc.d/S??이름)
    public static let servicesScript = #"""
    echo @PROCD; ubus call service list
    echo @INIT
    for f in /etc/init.d/*; do
      [ -x "$f" ] || continue; n=${f##*/}; e=0
      for r in /etc/rc.d/S??"$n"; do [ -e "$r" ] && e=1; done
      echo "$n $e"
    done
    echo @END
    """#

    /// busybox netstat — 4번째 칸이 "0.0.0.0:22" · ":::22" (RemoteInfo.parsePorts 가 ss 와 같이 읽는다)
    public static let portsCommand = "netstat -lnt 2>/dev/null | awk 'NR > 2 {print $4}'"

    /// 서비스 이름 (init.d 파일 이름). 원격 명령에 그대로 들어가므로 이 글자만.
    static let serviceNamePattern = #"^[A-Za-z0-9._-]{1,64}$"#

    /// Services 탭에서 서비스를 누르면: 그 이름이 든 최근 시스템 로그 50줄 (logread -e 는 정규식 — 이름 글자는 위 패턴만이라 그대로)
    public static func serviceLogCommand(name: String) -> String? {
        guard name.range(of: serviceNamePattern, options: .regularExpression) != nil else { return nil }
        return "logread -e \(shellQuote(name)) 2>/dev/null | tail -n 50"
    }

    /// "@이름" 줄로 나뉜 구역. @END 가 없으면(중간에 끊김) nil.
    static func sections(_ lines: [String]) -> [String: [String]]? {
        ScriptSections.parse(lines.joined(separator: "\n"), dropEmpty: false)
    }

    static func json(_ lines: [String]?) -> Any? {
        guard let lines, let data = lines.joined(separator: "\n").data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func now(_ s: [String: [String]]) -> Double? {
        s["NOW"]?.first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// "192.168.8.20" → 정렬 키 (IPv4 가 아니면 맨 뒤)
    static func ipSortKey(_ ip: String?) -> [Int] {
        guard let ip else { return [Int.max] }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 ? parts : [Int.max]
    }
}

// MARK: Network

public struct OpenWrtInterface: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// uci 인터페이스 이름 (wan · lan · wgserver …)
    public let name: String
    public let up: Bool
    public let proto: String
    /// 실제 장치 (l3_device, 없으면 device)
    public let device: String?
    public let uptime: TimeInterval?
    /// "192.168.8.1/24" — IPv4 다음 IPv6
    public let addresses: [String]
    public let gateway: String?
    public let dns: [String]
    /// netifd 오류 코드 (NO_DEVICE 등) — 첫 번째만
    public let error: String?
    public let rxBytes: UInt64?
    public let txBytes: UInt64?

    public enum State: Sendable, Equatable { case up, down, unused, failed }
    /// 상태 점 판정: 켜짐 · 꺼짐 · 장치 없음(NO_DEVICE — 안 쓰는 자리, GL.iNet 의 secondwan 등) · 그 밖 netifd 오류
    public var state: State {
        if up { return .up }
        if error == "NO_DEVICE" { return .unused }
        return error == nil ? .down : .failed
    }
}

/// 물리 포트 한 줄 (network.device status 의 ethernet · dsa 장치)
public struct OpenWrtPort: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let carrier: Bool
    /// "1000F" → 1000 Mbps · 전이중
    public let speedMbps: Int?
    public let fullDuplex: Bool?
    public let rxBytes: UInt64?
    public let txBytes: UInt64?
    /// 이 포트를 쓰는 인터페이스 (wan · lan …, 인터페이스 순). 장치 직접 · 그 VLAN(eth0.1) · 브리지 구성원으로 잇는다
    public var interfaces: [String] = []
}

public struct OpenWrtNetwork: Sendable, Equatable {
    public var interfaces: [OpenWrtInterface] = []
    public var ports: [OpenWrtPort] = []
    /// 경로·정책 규칙. ip 가 없거나 경로를 하나도 읽지 못하면 nil (켜진 공유기에는 최소한 LAN 경로가 있다)
    public var routing: OpenWrtRouting?
    /// 결과를 받을 때 한 번 계산해 둔다 (그리기마다 다시 하지 않게)
    public var layout = OpenWrtNetworkLayout()

    /// Network 스크립트 출력 → 인터페이스(loopback 제외, wan 먼저 · lan · 그 밖 이름 순)와 물리 포트. JSON 을 못 읽으면 nil.
    public static func parse(_ lines: [String]) -> OpenWrtNetwork? {
        guard let s = OpenWrt.sections(lines),
              let dump = OpenWrt.json(s["IFACES"]) as? [String: Any], let list = dump["interface"] as? [[String: Any]] else { return nil }
        let devices = OpenWrt.json(s["DEVICES"]) as? [String: Any] ?? [:]
        func stats(_ name: String?) -> (UInt64?, UInt64?) {
            guard let name, let d = devices[name] as? [String: Any], let st = d["statistics"] as? [String: Any] else { return (nil, nil) }
            return ((st["rx_bytes"] as? NSNumber)?.uint64Value, (st["tx_bytes"] as? NSNumber)?.uint64Value)
        }
        var result = OpenWrtNetwork()
        /// 인터페이스 → 쓰는 장치 (l3_device · device — wan6 처럼 둘이 다를 때가 있다)
        var usedDevices: [String: [String]] = [:]
        for item in list {
            guard let name = item["interface"] as? String, name != "loopback" else { continue }
            let device = (item["l3_device"] as? String) ?? (item["device"] as? String)
            usedDevices[name] = [item["l3_device"] as? String, item["device"] as? String].compactMap { $0 }
            func addresses(_ key: String) -> [String] {
                (item[key] as? [[String: Any]] ?? []).compactMap { a in
                    guard let address = a["address"] as? String else { return nil }
                    return (a["mask"] as? NSNumber).map { "\(address)/\($0)" } ?? address
                }
            }
            // 기본 경로(0.0.0.0/0 · ::/0)의 다음 홉
            let gateway = (item["route"] as? [[String: Any]] ?? []).first { r in
                ((r["target"] as? String) == "0.0.0.0" || (r["target"] as? String) == "::") && (r["mask"] as? NSNumber)?.intValue == 0
            }?["nexthop"] as? String
            let error = (item["errors"] as? [[String: Any]])?.first?["code"] as? String
            let (rx, tx) = stats(device)
            result.interfaces.append(OpenWrtInterface(
                name: name, up: item["up"] as? Bool ?? false, proto: item["proto"] as? String ?? "",
                device: device, uptime: (item["uptime"] as? NSNumber)?.doubleValue,
                addresses: addresses("ipv4-address") + addresses("ipv6-address"),
                gateway: gateway, dns: item["dns-server"] as? [String] ?? [], error: error, rxBytes: rx, txBytes: tx))
        }
        func rank(_ name: String) -> Int { name.hasPrefix("wan") ? 0 : (name == "lan" ? 1 : 2) }
        result.interfaces.sort { (rank($0.name), $0.name) < (rank($1.name), $1.name) }
        for (name, value) in devices {
            guard let d = value as? [String: Any] else { continue }
            let devtype = d["devtype"] as? String
            let speed = d["speed"] as? String
            // 브리지·wg·lo 는 speed·devtype 이 없다. 선이 빠진 포트는 speed 가 없어도 devtype 으로 남긴다.
            // VLAN(eth0.1 — 부모 포트의 속도를 그대로 보여 같은 포트가 두 번 나왔다, 2026-10-20 Brume 3)은 포트가 아니다
            guard devtype != "vlan", !name.contains("."),
                  devtype == "ethernet" || devtype == "dsa" || (speed != nil && devtype != "bridge") else { continue }
            // "1000F" · "100H" · 모르면 "-1F" — 끝 글자(이중) 앞이 숫자, 0 이하는 모름
            let mbps = speed.flatMap { Int($0.last == "F" || $0.last == "H" ? String($0.dropLast()) : $0) }.flatMap { $0 > 0 ? $0 : nil }
            let duplex: Bool? = speed.flatMap { $0.last == "F" ? true : ($0.last == "H" ? false : nil) }
            let (rx, tx) = stats(name)
            result.ports.append(OpenWrtPort(name: name, carrier: d["carrier"] as? Bool ?? false, speedMbps: mbps, fullDuplex: duplex,
                                            rxBytes: rx, txBytes: tx))
        }
        result.ports.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // 포트 ← 인터페이스: 장치가 포트이거나 그 VLAN(eth0.1 → eth0), 브리지면 구성원(같은 규칙), 브리지 VLAN(br-lan.1)이면 그 브리지
        func parent(_ name: String) -> String { name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name }
        func ports(of device: String) -> [String] {
            var names = [device, parent(device)]
            for bridge in Set(names) {
                let members = (devices[bridge] as? [String: Any])?["bridge-members"] as? [String] ?? []
                names += members.flatMap { [$0, parent($0)] }
            }
            return names
        }
        for index in result.ports.indices {
            let port = result.ports[index].name
            result.ports[index].interfaces = result.interfaces.map(\.name).filter { iface in
                (usedDevices[iface] ?? []).contains { ports(of: $0).contains(port) }
            }
        }
        // 내부 스위치 뒤의 실제 포트로 바꾼다 (리눅스에는 CPU 로 가는 연결 하나만 보인다)
        let switched = OpenWrtSwitch.parse(board: OpenWrt.json(s["BOARD"]) as? [String: Any], links: s["SWITCH"] ?? [])
        result.ports.removeAll { switched.cpuDevices.contains($0.name) }
        result.ports += switched.ports.map { item in
            var port = item.port
            if let device = item.device {
                port.interfaces = result.interfaces.map(\.name).filter { iface in (usedDevices[iface] ?? []).contains { ports(of: $0).contains(device) } }
            }
            return port
        }
        result.ports.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // 경로의 장치 → 인터페이스 이름. 위 정렬 순이라 wan · wan6 이 같은 장치면 wan
        var interfaceNames: [String: String] = [:]
        for iface in result.interfaces {
            if let device = iface.device, interfaceNames[device] == nil { interfaceNames[device] = iface.name }
        }
        result.routing = OpenWrtRouting.parse(rules: s["RULES"] ?? [], routes: s["ROUTES"] ?? [], interfaceNames: interfaceNames)
        result.layout = OpenWrtNetworkLayout(interfaces: result.interfaces, ports: result.ports, routing: result.routing)
        return result
    }
}

/// swconfig 스위치 칩 뒤의 포트 (2026-11-06 Brume 3: RTL8366UB, 리눅스에는 CPU 로 가는 eth0 하나만 보여 2.5 Gbps 는 내부 연결 속도였다).
/// 어느 번호가 실제 포트인지는 board.json 이 정한다 — 칩이 알리는 다른 번호(이 칩은 18개)는 포트가 아니다. 실제 출력: Fixtures/openwrt-switch-mt5000.txt
enum OpenWrtSwitch {
    /// device: 그 포트의 역할이 쓰는 장치 (eth0.1) — 인터페이스와 잇는다
    struct Item { let port: OpenWrtPort; let device: String? }

    /// 읽지 못한 스위치는 아무것도 내지 않는다 — CPU 장치도 포트 목록에 그대로 남는다
    static func parse(board: [String: Any]?, links: [String]) -> (ports: [Item], cpuDevices: Set<String>) {
        guard let switches = board?["switch"] as? [String: Any] else { return ([], []) }
        let found = linkLines(links)
        var items: [Item] = []
        var cpuDevices: Set<String> = []
        for (name, value) in switches {
            guard let config = value as? [String: Any], let list = config["ports"] as? [[String: Any]], let states = found[name] else { continue }
            var roleDevices: [String: String] = [:]
            for role in config["roles"] as? [[String: Any]] ?? [] {
                if let key = role["role"] as? String, let device = role["device"] as? String { roleDevices[key] = device }
            }
            let parsed: [Item] = list.compactMap { entry in
                guard let number = (entry["num"] as? NSNumber)?.intValue, let role = entry["role"] as? String, let state = states[number] else { return nil }
                let title = switches.count > 1 ? "\(name) port \(number)" : "port \(number)"
                return Item(port: OpenWrtPort(name: title, carrier: state.carrier, speedMbps: state.speedMbps, fullDuplex: state.fullDuplex, rxBytes: nil, txBytes: nil),
                            device: roleDevices[role])
            }
            guard !parsed.isEmpty else { continue }
            items += parsed
            cpuDevices.formUnion(list.compactMap { $0["device"] as? String })
        }
        return (items, cpuDevices)
    }

    private struct LinkState { let carrier: Bool; let speedMbps: Int?; let fullDuplex: Bool? }

    /// "switch switch0" 뒤에 "link: port:0 link:up speed:2500baseT full-duplex" · "link: port:2 link:down" 들
    private static func linkLines(_ lines: [String]) -> [String: [Int: LinkState]] {
        var result: [String: [Int: LinkState]] = [:]
        var current: String?
        for line in lines {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count == 2, tokens[0] == "switch" {
                current = tokens[1]
                continue
            }
            // 맨 앞 "link:" 는 머리말이라 값을 찾을 때 뺀다
            func value(_ key: String) -> String? { tokens.dropFirst().first { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)) } }
            guard let current, tokens.first == "link:", let number = value("port").flatMap({ Int($0) }), let link = value("link") else { continue }
            let speed = value("speed").flatMap { Int($0.prefix { $0.isNumber }) }
            let duplex: Bool? = tokens.contains("full-duplex") ? true : (tokens.contains("half-duplex") ? false : nil)
            result[current, default: [:]][number] = LinkState(carrier: link == "up", speedMbps: speed, fullDuplex: duplex)
        }
        return result
    }
}

/// Network 탭 화면 구성: 경로·포트를 쓰는 인터페이스 밑으로 모은다. 공유기 모양을 가정하지 않고, 어디에도 안 묶이는 것은 따로 남겨 아무것도 사라지지 않는다.
public struct OpenWrtNetworkLayout: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String { interface.id }
        public let interface: OpenWrtInterface
        /// 행 아래에 늘 보이는 경로: 게이트웨이를 타거나 자기 대역이 아닌 것
        public let routes: [OpenWrtRoute]
        /// 펼쳐야 보이는 경로: 인터페이스 주소와 같은 내용인 자기 대역 On-link
        public let subnetRoutes: [OpenWrtRoute]
        public let ports: [OpenWrtPort]

        /// 이름 옆 설명: proto · 장치. GL 의 wgserver 처럼 이름과 같거나 겹치는 값은 뺀다
        public var descriptors: [String] {
            var result: [String] = []
            for value in [interface.proto, interface.device ?? ""] where !value.isEmpty && value != interface.name && !result.contains(value) {
                result.append(value)
            }
            return result
        }

        /// 펼침에 낼 게이트웨이. 경로 줄에 같은 값이 보이면 nil (wan6 처럼 IPv4 경로 표에 없는 값만 남는다)
        public var detailGateway: String? {
            guard let gateway = interface.gateway, !routes.contains(where: { $0.gateway == gateway }) else { return nil }
            return gateway
        }

        public var hasDetail: Bool {
            !interface.addresses.isEmpty || !interface.dns.isEmpty || detailGateway != nil || !subnetRoutes.isEmpty || !ports.isEmpty
        }
    }

    public private(set) var items: [Item] = []
    /// 인터페이스에 묶이지 않는 경로: 다른 테이블 · blackhole 등 · 모르는 장치
    public private(set) var otherRoutes: [OpenWrtRoute] = []
    public private(set) var otherPorts: [OpenWrtPort] = []

    public init() {}

    init(interfaces: [OpenWrtInterface], ports: [OpenWrtPort], routing: OpenWrtRouting?) {
        let names = Set(interfaces.map(\.name))
        let routes = routing?.routes ?? []
        func attached(_ route: OpenWrtRoute) -> Bool {
            route.table == "main" && route.kind == nil && route.interface.map(names.contains) == true
        }
        items = interfaces.map { iface in
            let mine = routes.filter { attached($0) && $0.interface == iface.name }
            // 자기 대역 판정은 리눅스 Network 탭과 같은 것 (IPv4Prefix)
            func isSubnet(_ route: OpenWrtRoute) -> Bool {
                route.gateway == nil && iface.addresses.contains { IPv4Prefix.sameNetwork($0, route.destination) }
            }
            return Item(interface: iface, routes: mine.filter { !isSubnet($0) }, subnetRoutes: mine.filter(isSubnet),
                        ports: ports.filter { $0.interfaces.contains(iface.name) })
        }
        otherRoutes = routes.filter { !attached($0) }
        otherPorts = ports.filter(\.interfaces.isEmpty)
    }
}

// MARK: Clients

public struct OpenWrtClient: Sendable, Equatable, Identifiable {
    public var id: String { mac }
    /// 소문자 aa:bb:cc:dd:ee:ff
    public let mac: String
    public let ip: String?
    /// GL.iNet 별칭(관리 화면에서 붙인 이름) → 장비가 알린 이름(임대) → 고정 할당 이름
    public let name: String?
    /// 남은 임대 시간. nil = 임대 없음, .infinity = 무기한
    public let leaseRemaining: TimeInterval?
    /// uci dhcp host 로 고정 할당된 MAC
    public let isStatic: Bool
    /// 이웃 상태가 방금 확인됨 (REACHABLE · DELAY · PROBE · PERMANENT). ip 가 없는 공유기는 ARP 표의 완성 항목
    public let active: Bool

    /// DHCP 로 받은 유동 주소. 고정 할당이 아니어도 임대가 없으면(장비에 직접 넣은 IP 등) 아니다
    public var isDynamic: Bool { !isStatic && leaseRemaining != nil }
    /// 행에 늘 보일 임대 시간. 고정 할당은 임대가 끝나도 같은 주소라 뺀다 (마우스를 올리면 보인다)
    public var visibleLease: TimeInterval? { isStatic ? nil : leaseRemaining }
}

public enum OpenWrtClients {
    /// Clients 스크립트 출력 → 장비 목록 (IP 순). 임대 · 고정 할당 · LAN 브리지(br-*)의 이웃을 MAC 으로 합친다.
    /// WAN 쪽 이웃(상위 공유기)은 장비가 아니라 뺀다. 구역이 끊겼으면 nil.
    /// 활성은 ip neigh 상태로 본다 — /proc/net/arp 는 STALE 도 완성(0x2)으로 찍고, 리눅스는 항목이 적으면(gc_thresh1 128 미만)
    /// STALE 을 지우지 않아 떠난 장비가 몇 시간씩 활성으로 남았다 (2026-10-20 Brume 3: 빠진 .101 이 초록, GL 화면은 오프라인).
    public static func parse(_ lines: [String]) -> [OpenWrtClient]? {
        guard let s = OpenWrt.sections(lines) else { return nil }
        let now = OpenWrt.now(s)

        struct Entry { var ip: String?; var name: String?; var lease: TimeInterval?; var isStatic = false; var active = false }
        var entries: [String: Entry] = [:]
        var order: [String] = []
        func touch(_ mac: String, _ change: (inout Entry) -> Void) {
            if entries[mac] == nil { entries[mac] = Entry(); order.append(mac) }
            change(&entries[mac]!)
        }

        // dnsmasq: "만료(epoch, 0=무기한) MAC IP 이름(* = 없음) 클라이언트ID"
        for line in s["LEASES"] ?? [] {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, let expiry = Double(f[0]), let mac = Arp.normalizeMAC(String(f[1])) else { continue }
            let remaining: TimeInterval? = expiry == 0 ? .infinity : now.map { max(0, expiry - $0) }
            touch(mac) { e in
                e.ip = String(f[2]); e.lease = remaining
                if f[3] != "*" { e.name = String(f[3]) }
            }
        }

        // uci show dhcp: "dhcp.<섹션>=host" 뒤에 ".mac='aa:…' 'bb:…'" · ".ip='…'" · ".name='…'"
        for f in UCI.sections(s["STATIC"] ?? [], type: "host") {
            for raw in f["mac"] ?? [] {
                guard let mac = Arp.normalizeMAC(raw) else { continue }
                touch(mac) { e in
                    e.isStatic = true
                    if e.ip == nil { e.ip = f["ip"]?.first }
                    if e.name == nil { e.name = f["name"]?.first }
                }
            }
        }

        if let neigh = s["NEIGH"] {
            // ip neigh: "IP dev 장치 lladdr MAC [router] [ref 1 used …] 상태" (busybox 는 ref·used·probes 가 더 붙는다), 주소 없는 FAILED 는 MAC 이 없다
            for line in neigh {
                let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard let ip = t.first, ip.contains("."), !ip.contains(":"),
                      let dev = t.firstIndex(of: "dev").flatMap({ $0 + 1 < t.count ? t[$0 + 1] : nil }), dev.hasPrefix("br-"),
                      let mac = t.firstIndex(of: "lladdr").flatMap({ $0 + 1 < t.count ? Arp.normalizeMAC(t[$0 + 1]) : nil }),
                      mac != "00:00:00:00:00:00", let state = t.last else { continue }
                touch(mac) { e in
                    if ["REACHABLE", "DELAY", "PROBE", "PERMANENT"].contains(state) { e.active = true }
                    if e.ip == nil { e.ip = ip }
                }
            }
        } else {
            // ip 가 없는 공유기: /proc/net/arp "IP  HW종류  플래그  MAC  마스크  장치" — 플래그 0x2(완성)만 (STALE 도 섞인다)
            for line in (s["ARP"] ?? []).dropFirst() {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count >= 6, f[2] != "0x0", f[5].hasPrefix("br-"), let mac = Arp.normalizeMAC(String(f[3])),
                      mac != "00:00:00:00:00:00" else { continue }
                touch(mac) { e in
                    e.active = true
                    if e.ip == nil { e.ip = String(f[0]) }
                }
            }
        }

        // GL.iNet 별칭: "gl-client.@client[0]=client" · ".mac='D8:…'" · ".alias='window-pc'" — 목록에 이미 있는 장비에만 이름으로
        var aliases: [String: String] = [:]
        for f in UCI.sections(s["ALIAS"] ?? [], type: "client") {
            guard let mac = f["mac"]?.first.flatMap(Arp.normalizeMAC), let alias = f["alias"]?.first, !alias.isEmpty else { continue }
            aliases[mac] = alias
        }

        return order.map { mac in
            let e = entries[mac]!
            return OpenWrtClient(mac: mac, ip: e.ip, name: aliases[mac] ?? e.name, leaseRemaining: e.lease, isStatic: e.isStatic, active: e.active)
        }
        .sorted { a, b in
            let ka = OpenWrt.ipSortKey(a.ip), kb = OpenWrt.ipSortKey(b.ip)
            return ka == kb ? a.mac < b.mac : ka.lexicographicallyPrecedes(kb)
        }
    }
}

// MARK: WireGuard

public struct WireGuardPeer: Sendable, Equatable, Identifiable {
    public var id: String { publicKey }
    public let publicKey: String
    /// uci description · name
    public let name: String?
    public let endpoint: String?
    public let allowedIPs: [String]
    /// 마지막 핸드셰이크 뒤 지난 시간. nil = 한 번도 없음
    public let handshakeAgo: TimeInterval?
    public let rxBytes: UInt64
    public let txBytes: UInt64
    public let keepalive: Int?

    /// WireGuard 는 주고받는 동안 2분마다 핸드셰이크를 새로 한다 — 3분 안이면 붙어 있는 것
    public static let activeWindow: TimeInterval = 180
    public var isActive: Bool { handshakeAgo.map { $0 <= Self.activeWindow } ?? false }
}

public struct WireGuardInterface: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let publicKey: String
    public let listenPort: Int?
    public let peers: [WireGuardPeer]
}

public enum WireGuardReport: Sendable, Equatable {
    /// wg 명령이 없다 (wireguard-tools 미설치)
    case notInstalled
    case interfaces([WireGuardInterface])

    /// WireGuard 스크립트 출력 → 인터페이스 이름 순. 구역이 끊겼으면 nil.
    /// wg show all dump: 인터페이스 줄 5칸(이름 개인키 공개키 포트 fwmark), 피어 줄 9칸(이름 공개키 PSK 끝점 허용IP 핸드셰이크 받음 보냄 keepalive).
    /// 칸 구분은 탭인데 앱의 출력 정리가 탭을 공백으로 바꾼다 — 값에 공백이 없어 공백으로 나눈다.
    public static func parse(_ lines: [String]) -> WireGuardReport? {
        guard let s = OpenWrt.sections(lines) else { return nil }
        if s["NOWG"] != nil { return .notInstalled }
        let now = OpenWrt.now(s)

        // network.<섹션>.public_key='…' / .description='…' — 같은 섹션끼리 이어 공개 키 → 이름
        var keys: [String: String] = [:], labels: [String: String] = [:]
        for line in s["NAMES"] ?? [] {
            guard let (path, raw) = UCI.entry(line), path.count == 3, let value = UCI.values(raw).first else { continue }
            let section = path[0] + "." + path[1]
            if path[2] == "public_key" { keys[section] = value }
            else if path[2] == "description" || (path[2] == "name" && labels[section] == nil) { labels[section] = value }
        }
        var names: [String: String] = [:]
        for (section, key) in keys { if let label = labels[section], !label.isEmpty { names[key] = label } }

        var order: [String] = []
        var heads: [String: (key: String, port: Int?)] = [:]
        var peers: [String: [WireGuardPeer]] = [:]
        for line in s["WG"] ?? [] {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if f.count == 5 {
                if heads[f[0]] == nil { order.append(f[0]) }
                heads[f[0]] = (f[2], Int(f[3]).flatMap { $0 > 0 ? $0 : nil })
            } else if f.count == 9 {
                let handshake = Double(f[5]) ?? 0
                let ago: TimeInterval? = handshake > 0 ? now.map { max(0, $0 - handshake) } : nil
                peers[f[0], default: []].append(WireGuardPeer(
                    publicKey: f[1], name: names[f[1]], endpoint: f[3] == "(none)" ? nil : f[3],
                    allowedIPs: f[4] == "(none)" ? [] : f[4].split(separator: ",").map(String.init),
                    handshakeAgo: ago, rxBytes: UInt64(f[6]) ?? 0, txBytes: UInt64(f[7]) ?? 0,
                    keepalive: f[8] == "off" ? nil : Int(f[8])))
            }
        }
        return .interfaces(order.sorted().map { name in
            WireGuardInterface(name: name, publicKey: heads[name]!.key, listenPort: heads[name]!.port, peers: peers[name] ?? [])
        })
    }
}

// MARK: Services

public struct OpenWrtService: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// 부팅 때 켜짐 (/etc/rc.d/S??이름)
    public let enabled: Bool
    /// procd 가 관리하는 서비스 (ubus service list 에 있음). 아니면 한 번 돌고 끝나는 init 스크립트
    public let managed: Bool
    public let instances: Int
    public let running: Int
    /// 멈춘 인스턴스의 종료 코드 (첫 번째)
    public let exitCode: Int?

    /// 켜 둔 procd 서비스인데 인스턴스가 하나도 안 돈다. exit 0 은 할 일을 마치고 끝난 작업(urandom_seed 등)이라 멈춤이 아니다
    public var isStopped: Bool { enabled && managed && instances > 0 && running == 0 && exitCode != 0 }
}

public struct OpenWrtServices: Sendable, Equatable {
    /// 켜 뒀는데 멈춤 (맨 위)
    public var stopped: [OpenWrtService] = []
    public var running: [OpenWrtService] = []
    /// 그 밖: 한 번 도는 스크립트 · 꺼 둔 서비스 · 인스턴스 없는 서비스 (접어 둔다)
    public var other: [OpenWrtService] = []

    public static func parse(_ lines: [String]) -> OpenWrtServices? {
        guard let s = OpenWrt.sections(lines) else { return nil }
        let procd = OpenWrt.json(s["PROCD"]) as? [String: Any] ?? [:]
        var report = OpenWrtServices()
        for line in s["INIT"] ?? [] {
            let f = line.split(separator: " ")
            guard f.count == 2 else { continue }
            let name = String(f[0])
            let instances = (procd[name] as? [String: Any])?["instances"] as? [String: Any] ?? [:]
            let states = instances.keys.sorted().compactMap { instances[$0] as? [String: Any] }   // 종료 코드를 고를 순서가 매번 같게
            let running = states.filter { $0["running"] as? Bool == true }.count
            let exit = states.first { $0["running"] as? Bool != true }?["exit_code"] as? NSNumber
            let service = OpenWrtService(name: name, enabled: f[1] == "1", managed: procd[name] != nil, instances: states.count,
                                         running: running, exitCode: running == 0 ? exit?.intValue : nil)
            if service.isStopped { report.stopped.append(service) }
            else if running > 0 { report.running.append(service) }
            else { report.other.append(service) }
        }
        return report
    }
}
