// 원격 조회(spec · 업데이트 목록 · ports) 출력을 구조화한다 (services 는 ServicesReport). 입력은 RemoteCommands 의 스크립트 출력(정리된 줄).

import Foundation

public struct SpecItem: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    public let value: String
    /// 0...1 사용률 (메모리·디스크처럼 비율이 있는 항목만)
    public let usage: Double?
    public let label: String
    /// 손봐야 할 값 (재부팅 필요 · 보안 업데이트) — 경고색
    public var warning = false
}

/// apt 가 올릴 수 있는 패키지 하나 (Spec 의 UPDATE 줄 — 업데이트 줄을 누르면 목록)
public struct UpdateItem: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// "noble-updates,noble-security" — 보안 저장소가 끼어 있으면 보안 업데이트
    public let suites: String
    public let version: String
    public let installed: String
    /// 지금 `apt upgrade` 로는 안 올라간다 — 순차 배포(phased) 차례 전이거나 hold (INSTALLS 줄에 없는 패키지). 줄이 없으면(모의 실행 실패) 전부 false
    public var deferred = false
    public var security: Bool { suites.contains("-security") }
}

/// 리스닝 포트 한 줄 — 같은 포트의 IPv4·IPv6·장치별 소켓은 한 줄로 묶는다 (2026-10-14: 포트마다 두 줄씩, 주소가 "…%tailscale0" 로 두 줄에 걸쳐 지저분했다)
public struct PortItem: Sendable, Equatable, Identifiable {
    public var id: String { udp ? "\(port)/udp" : "\(port)" }
    public let port: Int
    /// UDP 포트 (리눅스만 읽는다). 같은 번호의 TCP 와는 다른 줄이다 — 터널·브라우저·변경 이력은 TCP 만 본다.
    public let udp: Bool
    /// 대기 주소들 ("*" = 모든 주소). 순서: * → IPv4 → IPv6. ss 의 %장치 는 뗀 값
    public let addresses: [String]
    /// 묶인 장치 (ss 의 "100.101.0.1%tailscale0" 의 tailscale0) — 없으면 빈 배열
    public let devices: [String]
    public let label: String?
    /// 그 포트를 연 프로세스 이름 (Windows 만 — 리눅스의 ss 는 root 가 아니면 남의 프로세스를 못 본다)
    public let process: String?
    /// [Tunnel…] 이 채울 주소 (TunnelTarget.fromListenAddress 로 넘김). nil = 터널로 닿을 주소를 모름 → 버튼 비활성.
    /// 장치에 묶인 와일드카드(0.0.0.0%eth0)는 그 장치로 들어온 연결만 받아 127.0.0.1 로는 거부된다 (2026-10-14 컨테이너 재현).
    /// 장치에 묶인 특정 IP(100.101.0.1%tailscale0)는 서버 자신이 그 IP 로 접속해도 받는다 (같은 재현).
    public let tunnelAddress: String?

    public init(port: Int, udp: Bool = false, addresses: [String], devices: [String] = [], label: String?, process: String? = nil, tunnelAddress: String?) {
        self.port = port; self.udp = udp; self.addresses = addresses; self.devices = devices; self.label = label; self.process = process
        self.tunnelAddress = tunnelAddress
    }

    /// 모든 주소로 듣는다 — 바깥에서 닿는 포트 (화면에서 딱지. Services 의 docker 포트 딱지와 같은 뜻)
    public var open: Bool { addresses.contains("*") }

    /// 화면 한 줄: "*" · "100.101.0.1 · fd7a:115c:a1e0::1111:2222"
    public var addressText: String { addresses.joined(separator: " · ") }
    /// 터널·복사에 쓸 주소 하나: 모든 주소면 "*", 아니면 IPv4 우선
    public var primaryAddress: String { addresses.first ?? "*" }
}

public enum RemoteInfo {
    // MARK: Spec

    static let specLabels: [String: String] = [
        "HOSTNAME": "호스트", "OS": "OS", "KERNEL": "Kernel", "ARCH": "Arch", "CPU": "CPU",
        "MEMORY": "메모리", "ROOT DISK": "루트 디스크", "UPTIME": "가동 시간",
        "MODEL": "모델", "REBOOT": "재부팅", "UPDATES": "업데이트",
    ]

    /// systemd-detect-virt 이름 → 표시 이름
    static let virtNames: [String: String] = [
        "kvm": "KVM", "qemu": "QEMU", "vmware": "VMware", "microsoft": "Hyper-V", "oracle": "VirtualBox", "xen": "Xen",
        "amazon": "AWS Nitro", "parallels": "Parallels", "apple": "Apple 가상화", "bochs": "Bochs",
        "lxc": "LXC", "lxc-libvirt": "LXC", "docker": "Docker", "podman": "Podman", "openvz": "OpenVZ", "systemd-nspawn": "systemd-nspawn", "wsl": "WSL",
    ]
    /// 보드 제조사가 비워 둔 자리 채움 글
    static let placeholderModels: Set<String> = ["to be filled by o.e.m.", "system product name", "default string", "system manufacturer", "not specified", "none"]
    static func isPlaceholder(_ text: String) -> Bool { placeholderModels.contains(text.lowercased()) }

    /// 스크립트가 보낸 원시 값 → 화면 값과 경고. nil 이면 줄을 숨긴다.
    ///   MODEL   "제조사|제품|가상화|c(컨테이너)" → "Dell OptiPlex 7090" · "KVM 가상 머신 · Standard PC" · "LXC 컨테이너"
    ///   REBOOT  yes/no → "필요"(경고) · "필요 없음"
    ///   UPDATES "전체;보안" (apt-check) → "12개 (보안 3)"(보안이 있으면 경고) · "3개 · 보류 3"(목록에는 있지만 지금은 안 올라가는 수) · "최신"
    ///   UPTIME  초 → "25일 3시간" (예전 글 꼴이면 그대로)
    ///   CPU     "… (8 threads)" → "… (8스레드)"
    static func formatSpec(_ key: String, _ value: String, deferredUpdates: Int = 0) -> (value: String, warning: Bool)? {
        switch key {
        case "MODEL":
            let parts = value.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let vendor = parts.first.flatMap { isPlaceholder($0) ? nil : $0 } ?? ""
            let product = parts.count > 1 && !isPlaceholder(parts[1]) ? parts[1] : ""
            let virt = parts.count > 2 ? parts[2] : ""
            // systemd-detect-virt -c 가 맞으면 컨테이너 (모르는 이름도 "가상 머신" 으로 잘못 부르지 않게). 예전 3칸 출력은 이름표로
            let container = parts.count > 3 ? parts[3] == "c" : ["lxc", "lxc-libvirt", "docker", "podman", "openvz", "systemd-nspawn"].contains(virt)
            // 제품 이름에 제조사 첫 낱말이 이미 있으면 겹쳐 쓰지 않는다 ("LENOVO" + "ThinkCentre" 는 붙이고, "Raspberry Pi 4" 는 그대로)
            let brand = vendor.split(separator: " ").first.map { $0.lowercased() } ?? ""
            let machine = product.isEmpty ? vendor : (brand.isEmpty || product.lowercased().contains(brand) ? product : "\(vendor) \(product)")
            if !virt.isEmpty, virt != "none" {
                let name = virtNames[virt] ?? virt
                let kind = virt == "wsl" ? name : (container ? "\(name) 컨테이너" : "\(name) 가상 머신")
                return (machine.isEmpty ? kind : "\(kind) · \(machine)", false)
            }
            return machine.isEmpty ? nil : (machine, false)
        case "REBOOT":
            return value == "yes" ? ("필요", true) : ("필요 없음", false)
        case "UPDATES":
            let counts = value.split(separator: ";").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard counts.count == 2 else { return nil }   // apt-check 가 오류를 냈으면 숨긴다
            if counts[0] == 0 { return ("최신", false) }
            // 보안은 전체 수 바로 뒤 괄호에 — 가운뎃점으로 나란히 두면("5개 · 보안 1 · 보류 2") 다 더한 8개처럼 읽혔다 (2026-11-18 사용자 지적).
            // 보류는 괄호 없이 가운뎃점으로 ("3개 (보류 2)" 는 딱딱했다 — 2026-11-17)
            let total = "\(counts[0])개" + (counts[1] > 0 ? " (보안 \(counts[1]))" : "")
            return (deferredUpdates > 0 ? "\(total) · 보류 \(deferredUpdates)" : total, counts[1] > 0)
        case "UPTIME":
            guard let seconds = Double(value) else { return (value, false) }
            return (DurationFormat.compact(seconds), false)
        case "CPU":
            return (value.replacingOccurrences(of: #"\((\d+) threads\)$"#, with: "($1스레드)", options: .regularExpression)
                         .replacingOccurrences(of: #"^(\d+) threads$"#, with: "$1스레드", options: .regularExpression), false)
        default:
            if key.hasPrefix("DRIVE ") { return formatDrive(value) }
            if key.hasPrefix("GPU ") { return formatGPU(value) }
            return (value, false)
        }
    }

    /// Windows 물리 디스크 "모델|MediaType|BusType|바이트|HealthStatus" → "Samsung SSD 870 EVO 500GB · SSD · SATA · 500 GB" (상태가 정상이 아니면 경고)
    static func formatDrive(_ value: String) -> (value: String, warning: Bool)? {
        let f = value.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count == 5, !f[0].isEmpty else { return nil }
        let media = ["3": "HDD", "4": "SSD", "5": "SCM"][f[1]]
        let bus = ["7": "USB", "8": "RAID", "10": "SAS", "11": "SATA", "12": "SD", "17": "NVMe"][f[2]]
        // 디스크 용량은 제조사 표기대로 10진 (500107862016 → 500 GB)
        let size = UInt64(f[3]).flatMap { $0 > 0 ? ($0 >= 1_000_000_000_000 ? String(format: "%.1f TB", Double($0) / 1e12).replacingOccurrences(of: ".0 ", with: " ")
                                                                               : "\(Int((Double($0) / 1e9).rounded())) GB") : nil }
        let health = ["1": "상태 경고", "2": "상태 이상"][f[4]]
        return ([f[0], media, bus, size, health].compactMap { $0 }.joined(separator: " · "), health != nil)
    }

    /// Windows GPU "이름|VRAM 바이트" → "NVIDIA GeForce RTX 3070 Ti · 8 GB" (내장 그래픽은 VRAM 값이 없다)
    static func formatGPU(_ value: String) -> (value: String, warning: Bool)? {
        let f = value.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = f.first, !name.isEmpty else { return nil }
        let memory = f.count > 1 ? UInt64(f[1]).flatMap { $0 >= 1 << 30 ? "\(Int((Double($0) / Double(1 << 30)).rounded())) GB" : nil } : nil
        return ([name, memory].compactMap { $0 }.joined(separator: " · "), false)
    }

    /// 화면 라벨. Windows 의 여러 줄짜리 키: "DISK C" → "C:" · "DRIVE A" → "디스크" · "GPU A" → "GPU"
    static func specLabel(_ key: String) -> String {
        if let label = specLabels[key] { return label }
        if key.hasPrefix("DISK "), key.count == 6 { return "\(key.dropFirst(5)):" }
        if key.hasPrefix("DRIVE ") { return "디스크" }
        if key.hasPrefix("GPU ") { return "GPU" }
        return key.capitalized
    }

    /// "KEY          value" 줄 → 항목. 메모리는 total/available 로, 디스크는 (NN%) 로 사용률을 낸다.
    public static func parseSpec(_ lines: [String]) -> [SpecItem] {
        let deferred = parseUpdates(lines).filter(\.deferred).count
        return lines.compactMap { line in
            guard let match = line.range(of: #"^([A-Z][A-Z ]*?)\s{2,}(.+)$"#, options: .regularExpression) else { return nil }
            let text = String(line[match])
            let parts = text.split(separator: "  ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if key == "UPDATE" || key == "INSTALLS" { return nil }   // 패키지 목록 줄 (parseUpdates)
            guard let (value, warning) = formatSpec(key, parts[1].trimmingCharacters(in: .whitespaces), deferredUpdates: deferred) else { return nil }
            var usage: Double?
            if key == "MEMORY" { usage = memoryUsage(value) }
            if key == "ROOT DISK" || key.hasPrefix("DISK "), let pct = value.range(of: #"\((\d+)%\)"#, options: .regularExpression) {
                let digits = value[pct].filter(\.isNumber)
                if let n = Double(digits) { usage = min(1, max(0, n / 100)) }
            }
            return SpecItem(key: key, value: value, usage: usage, label: specLabel(key), warning: warning)
        }
    }

    /// "15Gi total, 3.5Gi available" → 1 - available/total
    static func memoryUsage(_ value: String) -> Double? {
        func size(_ s: Substring) -> Double? {
            guard let m = s.range(of: #"([0-9.]+)\s*([KMGTP]?)(i?B?)"#, options: .regularExpression) else { return nil }
            let token = String(s[m])
            let digits = token.prefix { $0.isNumber || $0 == "." }
            guard let n = Double(digits) else { return nil }
            let unit = token.dropFirst(digits.count).first.map { String($0).uppercased() } ?? ""
            let scale: [String: Double] = ["K": 1, "M": 1024, "G": 1024 * 1024, "T": 1024 * 1024 * 1024, "P": 1024 * 1024 * 1024 * 1024]
            return n * (scale[unit] ?? 1.0 / 1024)
        }
        let parts = value.split(separator: ",")
        guard let totalPart = parts.first(where: { $0.contains("total") }), let availPart = parts.first(where: { $0.contains("available") }),
              let total = size(totalPart), let avail = size(availPart), total > 0 else { return nil }
        return min(1, max(0, 1 - avail / total))
    }

    /// "UPDATE       apt/noble-updates,noble-security 2.8.4ubuntu0.1 arm64 [upgradable from: 2.8.3]" (apt list --upgradable 꼴) → 패키지.
    /// "INSTALLS     perl-base libc6" (apt-get -s dist-upgrade 의 Inst 이름들) 줄이 있으면 거기 없는 패키지는 보류.
    /// 순서: 지금 올라가는 것 먼저(그 안에서 보안 먼저), 보류는 뒤로, 이름순
    public static func parseUpdates(_ lines: [String]) -> [UpdateItem] {
        let pattern = #"^UPDATE\s+(\S+)/(\S+)\s+(\S+)\s+\S+\s+\[upgradable from: ([^\]]+)\]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        // 줄이 없으면 nil (모의 실행을 못 했다 — 보류를 가리지 않는다). 이름이 하나도 없는 줄은 "전부 보류"
        let installs: Set<Substring>? = lines.first { $0 == "INSTALLS" || $0.hasPrefix("INSTALLS ") }
            .map { Set($0.dropFirst("INSTALLS".count).split(separator: " ")) }
        let items = lines.compactMap { line -> UpdateItem? in
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let name = ns.substring(with: m.range(at: 1))
            return UpdateItem(name: name, suites: ns.substring(with: m.range(at: 2)),
                              version: ns.substring(with: m.range(at: 3)), installed: ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces),
                              deferred: installs.map { !$0.contains(Substring(name)) } ?? false)
        }
        return items.sorted { ($0.deferred ? 1 : 0, $0.security ? 0 : 1, $0.name) < ($1.deferred ? 1 : 0, $1.security ? 0 : 1, $1.name) }
    }

    // MARK: Ports

    public static let knownPorts: [Int: String] = [
        22: "ssh", 53: "dns", 80: "http", 443: "https", 135: "rpc", 139: "netbios", 445: "smb", 631: "cups",
        2379: "etcd", 2380: "etcd peer", 3000: "http-alt", 3306: "mysql", 3389: "rdp", 5432: "postgres", 5900: "vnc",
        5985: "winrm", 5986: "winrm tls", 6379: "redis", 6443: "k3s api", 8080: "http-alt", 8443: "https-alt",
        9090: "http-alt", 9100: "node-exporter", 10250: "kubelet", 27017: "mongodb", 41641: "tailscale",
    ]

    /// UDP 로 알려진 번호 (TCP 이름표와 따로 — 53 은 둘 다 dns 지만 123·51820 은 UDP 뿐)
    public static let knownUDPPorts: [Int: String] = [
        53: "dns", 67: "dhcp", 68: "dhcp", 123: "ntp", 137: "netbios", 138: "netbios", 161: "snmp", 323: "chrony", 500: "ipsec",
        514: "syslog", 1900: "ssdp", 3478: "stun", 4500: "ipsec nat-t", 5353: "mdns", 8472: "vxlan", 41641: "tailscale", 51820: "wireguard",
    ]

    /// "0.0.0.0:22", "*:6443", "[::]:22", ":::135", "100.101.0.1%tailscale0:10004", "[::1]%lo:10004", Windows "0.0.0.0:22|6788|sshd" → 포트별 한 줄. 포트 순으로 정렬.
    /// 와일드카드(v4/v6, 장치에 묶인 것 포함)는 "*". 실제 ss 출력: Tests/…/Fixtures/ss-ports-bound.txt (ubuntu:24.04 컨테이너, 2026-10-14).
    /// 끝이 "/udp" 인 줄은 UDP 포트 — TCP 를 번호순으로 다 적은 뒤 UDP 를 번호순으로 (같은 번호여도 따로).
    public static func parsePorts(_ lines: [String]) -> [PortItem] {
        let udpLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasSuffix("/udp") }
        let tcp = parsePorts(lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasSuffix("/udp") }, udp: false)
        return tcp + parsePorts(udpLines.map { String($0.dropLast(4)) }, udp: true)
    }

    private static func parsePorts(_ lines: [String], udp: Bool) -> [PortItem] {
        var addresses: [Int: [String]] = [:], devices: [Int: [String]] = [:], processes: [Int: [String]] = [:]
        // 루프백으로 닿는 모든 주소 대기가 있는가 (장치 없음 또는 lo 에 묶임)
        var openWildcard: Set<Int> = []
        for raw in lines {
            // Windows 는 "주소:포트|pid|프로세스". pid 0 은 닫힌 프로세스가 남긴 자리(받는 프로세스가 없다 — 2026-11-10 win 실측 "Idle")라 뺀다
            let columns = raw.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if columns.count >= 2, columns[1] == "0" { continue }
            let line = columns.first ?? ""
            let process = columns.count >= 3 && !columns[2].isEmpty ? columns[2] : nil
            guard let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) else { continue }
            let full = String(line[..<colon])
            let parts = full.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            var address = parts[0].replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            // IPv4-mapped("::ffff:127.0.0.1")는 IPv4 로 접는다 (컨테이너 실측 — 표시도 터널도 IPv4 가 맞다)
            if address.lowercased().hasPrefix("::ffff:"), address.dropFirst(7).contains(".") { address = String(address.dropFirst(7)) }
            if address.isEmpty || address == "*" || address == "::" || address == "0.0.0.0" {
                address = "*"
                if parts.count == 1 || parts[1].isEmpty || parts[1] == "lo" { openWildcard.insert(port) }
            }
            if !(addresses[port] ?? []).contains(address) { addresses[port, default: []].append(address) }
            if let process, !(processes[port] ?? []).contains(process) { processes[port, default: []].append(process) }
            if parts.count == 2, !parts[1].isEmpty, !(devices[port] ?? []).contains(parts[1]) { devices[port, default: []].append(parts[1]) }
        }
        // * → IPv4 → IPv6 (같은 갈래 안에서는 사전순)
        func rank(_ a: String) -> Int { a == "*" ? 0 : (a.contains(":") ? 2 : 1) }
        return addresses.keys.sorted().map { port in
            let sorted = addresses[port]!.sorted { (rank($0), $0) < (rank($1), $1) }
            // 터널 주소: 열린 와일드카드 → "*"(서버 자신), 아니면 특정 주소(IPv4 먼저), 장치에 묶인 와일드카드뿐이면 없음
            // 링크로컬(fe80::)은 scope 없이는 서버에서 연결이 안 되므로 터널 주소로 쓰지 않는다
            // UDP 는 ssh 터널(TCP)로 닿지 못한다 — 터널 주소 없음
            let tunnel = udp ? nil : (openWildcard.contains(port) ? "*" : sorted.first { $0 != "*" && !$0.lowercased().hasPrefix("fe80:") })
            return PortItem(port: port, udp: udp, addresses: sorted, devices: devices[port] ?? [], label: udp ? knownUDPPorts[port] : knownPorts[port],
                            process: processes[port]?.joined(separator: ", "), tunnelAddress: tunnel)
        }
    }
}
