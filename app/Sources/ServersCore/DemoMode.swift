// 데모 모드 (`--demo`): README 스크린샷용. 가상의 서버 목록과 정해진 응답만으로 화면을 채운다.
// 실제 상태에 닿지 않는 것이 전부다 — 상태 폴더는 임시 폴더(AppSupport), 금고 키는 메모리(MemoryKeyStore),
// 명령은 프로세스를 하나도 띄우지 않는 DemoRunner, 서버 확인은 DemoRunner.tcpProbe. 값은 모두 가상(문서용 대역·가짜 이름)이다.
// 탭·터널·전송은 러너를 거치지 않고 프로세스를 직접 띄우므로 데모에서 열지 않는다 (AGENTS.md 검증 절).

import Foundation

public enum DemoMode {
    public static func requested(arguments: [String]) -> Bool { arguments.contains("--demo") }

    /// 이 프로세스가 데모인가 (시작 인자를 한 번만 본다)
    public static let active = requested(arguments: CommandLine.arguments)

    /// 데모의 상태 폴더 — 프로세스마다 새 임시 폴더. 실제 `~/Library/Application Support/Servers` 를 읽지도 쓰지도 않는다.
    public static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nexus-demo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// 임시 폴더에 가상의 서버 목록을 쓰고 그 경로를 돌려준다 (한 번만)
    public static let confPath: String = {
        let url = directory.appendingPathComponent("servers.conf")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? conf.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }()

    public static let lanService = "Office LAN"

    public static let conf = """
    [network:lan]
    service=\(lanService)

    [web]
    group=work
    network=lan
    type=linux
    ip=10.20.1.11
    user=deploy
    port=22
    role=Reverse proxy
    env=DEV, DMZ

    [was]
    group=work
    network=lan
    type=linux
    ip=10.20.2.11
    user=deploy
    port=22
    role=WAS server
    env=DEV, Docker

    [db]
    group=work
    network=lan
    type=linux
    ip=10.20.3.11
    user=deploy
    port=22
    role=Database

    [jenkins]
    group=work
    network=lan
    type=linux
    ip=10.20.4.11
    user=deploy
    port=22
    role=CI/CD
    env=PROD, Jenkins

    [router]
    group=home
    network=direct
    type=openwrt
    ip=192.168.0.1
    user=root
    port=22
    role=Gateway

    [homelab]
    group=home
    network=tailscale
    type=linux
    ip=100.101.0.1
    user=alice
    port=22
    role=Home server
    env=HOST, K3S

    [desktop]
    group=home
    network=direct
    type=windows
    ip=192.168.0.20
    user=alice
    port=22
    role=Windows PC
    env=PC
    wol_mac=00:11:22:33:44:55
    wol_via=router:br-lan
    """
}

/// 메모리에만 두는 금고 키 (데모 — 로그인 키체인을 건드리지 않는다)
public final class MemoryKeyStore: VaultKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init() {}
    public func read() throws -> Data? { lock.withLock { data } }
    public func write(_ data: Data) throws { lock.withLock { self.data = data } }
}

/// 정해진 응답만 돌려주는 러너. 프로세스를 띄우는 코드가 없다 — 모르는 명령은 127.
public struct DemoRunner: CommandRunner {
    let config: ServerConfig?

    public init(conf: String = DemoMode.conf) {
        config = try? ServerConfigParser.parse(conf)
    }

    /// 꺼진 것으로 보일 서버 (나머지는 응답)
    static let offKeys: Set<String> = ["desktop"]

    /// 서버 확인(check=tcp)의 가짜: 목록의 서버 주소면 꺼진 것만 빼고 성공. 소켓을 열지 않는다.
    public var tcpProbe: TCPProbeFunction {
        let up = Set((config?.servers ?? []).filter { !Self.offKeys.contains($0.key) }.map(\.ip))
        return { host, _, _, _ in
            // 응답 시간이 0ms 로 찍히지 않게 주소마다 조금씩 다르게 기다린다
            try? await Task.sleep(for: .milliseconds(6 + host.utf8.reduce(0) { $0 + Int($1) } % 23))
            return up.contains(host)
        }
    }

    public func hasExecutable(_ name: String) -> Bool { name == "tailscale" }

    public func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
        switch (executable, arguments.first) {
        case ("networksetup", "-listnetworkserviceorder"): return ok(Self.serviceOrder)
        case ("networksetup", "-listallhardwareports"): return ok(Self.hardwarePorts)
        case ("networksetup", "-getinfo"): return Self.serviceInfo[arguments.last ?? ""].map(ok) ?? CommandResult(exitCode: 1)
        case ("ifconfig", nil): return ok(Self.interfaces.map(\.text).joined())
        case ("ifconfig", let device?): return Self.interfaces.first { $0.device == device }.map { ok($0.text) } ?? CommandResult(exitCode: 1)
        case ("ipconfig", "getifaddr"): return Self.addresses[arguments.last ?? ""].map { ok($0 + "\n") } ?? CommandResult(exitCode: 1)
        case ("tailscale", "status"): return ok(Self.tailscaleStatus)
        case ("scutil", "--nc"): return arguments == ["--nc", "list"] ? ok("Available network connection services in the current set (*=enabled):\n") : CommandResult(exitCode: 1)
        case ("route", _) where arguments == ["-n", "get", "default"]: return ok(Self.defaultRoute)
        case ("ping", _): return ok("1 packets transmitted, 1 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 1.204/1.204/1.204/0.000 ms\n")
        case ("netstat", "-ibn"): return arguments.last.map { ok(Self.counters(device: $0)) } ?? CommandResult(exitCode: 1)
        case ("system_profiler", _) where arguments == ["-json", "SPBluetoothDataType"]: return ok(Self.bluetooth)
        case ("ssh", _): return ssh(arguments, stdin: stdin)
        default: return CommandResult(exitCode: 127)
        }
    }

    private func ok(_ text: String) -> CommandResult { CommandResult(exitCode: 0, stdout: text) }

    /// 원격 조회: 마지막 인자(명령)와 stdin 이 그 서버 종류의 조회 명령과 같으면 그 조회의 응답. 꺼진 서버·모르는 명령은 실패.
    private func ssh(_ arguments: [String], stdin: String?) -> CommandResult {
        guard arguments.count >= 2, let server = config?.servers.first(where: { arguments.contains($0.target) }),
              !Self.offKeys.contains(server.key) else { return CommandResult(exitCode: 255, stderr: "ssh: connect to host: Operation timed out") }
        let command = arguments[arguments.count - 1]
        if command == "true" || command == "exit" { return ok("") }
        // Diagnose 탭 (ServerDiagnose.script) — 도구마다 가상의 결과 하나
        if command == "sh -s", server.type == .linux, let stdin, let reply = Self.diagnoseReply(stdin) { return ok(reply) }
        for query in RemoteCommands.Query.allCases {
            guard let q = RemoteCommands.query(query, for: server.type), q.command == command, q.stdin == stdin else { continue }
            return Self.reply(query, server: server).map(ok) ?? CommandResult(exitCode: 1)
        }
        return CommandResult(exitCode: 1)
    }

    /// 서버 시점 진단 스크립트의 가짜 출력 (문서용 대역). 스크립트가 아니면 nil
    static func diagnoseReply(_ script: String) -> String? {
        guard script.contains("@RC") else { return nil }
        if script.contains("ping -c") {
            return "5 packets transmitted, 5 received, 0% packet loss, time 804ms\nrtt min/avg/max/mdev = 0.412/0.538/0.701/0.097 ms\n@RC 0\n"
        }
        if script.contains("/dev/tcp/") { return "@RC 0\n@MS 3\n" }
        if script.contains("curl ") {
            return "exit=0\ncode=200\nscheme=HTTPS\nip=192.0.2.40\nport=443\ndns=0.004\nconnect=0.011\ntls=0.038\nfirst=0.121\ntotal=0.134\nredirect=\nerror=\n@RC 0\n"
        }
        if script.contains("getent ahosts") {
            return "192.0.2.40      STREAM db.example.internal\n192.0.2.40      DGRAM  \n192.0.2.40      RAW    \n2001:db8::40    STREAM \n@RC 0\n@MS 2\n"
        }
        return nil
    }

    static func reply(_ query: RemoteCommands.Query, server: Server) -> String? {
        guard server.type == .linux else { return nil }
        switch query {
        case .spec: return linuxSpec(server)
        case .services: return linuxServices
        case .ports: return "0.0.0.0:22\n0.0.0.0:80\n0.0.0.0:443\n127.0.0.1:5432\n127.0.0.1:9090\n[::]:22\n[::]:80\n[::]:443\n"
        default: return nil
        }
    }

    // MARK: 이 Mac (가상의 값)

    static let serviceOrder = """
    An asterisk (*) denotes that a network service is disabled.
    (1) Ethernet
    (Hardware Port: Thunderbolt Ethernet Slot 1, Device: en5)

    (2) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (3) \(DemoMode.lanService)
    (Hardware Port: USB 10/100/1000 LAN, Device: en7)

    """

    static let hardwarePorts = """

    Hardware Port: Thunderbolt Ethernet Slot 1
    Device: en5
    Ethernet Address: 02:00:5e:10:00:05

    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: 02:00:5e:10:00:00

    Hardware Port: USB 10/100/1000 LAN
    Device: en7
    Ethernet Address: 02:00:5e:10:00:07

    """

    static let addresses = ["en0": "192.168.0.24", "en5": "192.168.0.31", "en7": "10.20.0.50"]

    static let serviceInfo: [String: String] = [
        "Ethernet": "DHCP Configuration\nIP address: 192.168.0.31\nSubnet mask: 255.255.255.0\nRouter: 192.168.0.1\nClient ID: \nIPv6: Automatic\nIPv6 IP address: none\nIPv6 Router: none\nEthernet Address: 02:00:5e:10:00:05\n",
        "Wi-Fi": "DHCP Configuration\nIP address: 192.168.0.24\nSubnet mask: 255.255.255.0\nRouter: 192.168.0.1\nClient ID: \nIPv6: Automatic\nIPv6 IP address: none\nIPv6 Router: none\nWi-Fi ID: 02:00:5e:10:00:00\n",
        DemoMode.lanService: "Manual Configuration\nIP address: 10.20.0.50\nSubnet mask: 255.255.255.0\nRouter: 10.20.0.1\nIPv6: Automatic\nIPv6 IP address: none\nIPv6 Router: none\nEthernet Address: 02:00:5e:10:00:07\n",
    ]

    static let interfaces: [(device: String, text: String)] = [
        ("lo0", "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000\n"),
        ("en0", "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tether 02:00:5e:10:00:00\n\tinet 192.168.0.24 netmask 0xffffff00 broadcast 192.168.0.255\n\tmedia: autoselect\n\tstatus: active\n"),
        ("en5", "en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tether 02:00:5e:10:00:05\n\tinet 192.168.0.31 netmask 0xffffff00 broadcast 192.168.0.255\n\tmedia: autoselect (2500Base-T <full-duplex>)\n\tstatus: active\n"),
        ("en7", "en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tether 02:00:5e:10:00:07\n\tinet 10.20.0.50 netmask 0xffffff00 broadcast 10.20.0.255\n\tmedia: autoselect (1000baseT <full-duplex>)\n\tstatus: active\n"),
    ]

    static let defaultRoute = """
       route to: default
    destination: default
           mask: default
        gateway: 192.168.0.1
      interface: en5
          flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>

    """

    static let tailscaleStatus = #"""
    {"BackendState":"Running","Self":{"HostName":"macbook","DNSName":"macbook.example.ts.net.","TailscaleIPs":["100.101.0.2"],"Online":true},"Peer":{"p0":{"HostName":"homelab","DNSName":"homelab.example.ts.net.","TailscaleIPs":["100.101.0.1"],"Online":true}}}
    """#

    /// 받기·보내기 속도가 나오게 시각에 따라 늘어나는 바이트 수 (받기 약 1.8 MB/s · 보내기 약 240 KB/s)
    static func counters(device: String, now: Date = Date()) -> String {
        let t = now.timeIntervalSince1970
        let rx = UInt64(t * 1_800_000), tx = UInt64(t * 240_000)
        return "Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll\n"
            + "\(device) 1500 <Link#15> 02:00:5e:10:00:07 \(rx / 1200) 0 \(rx) \(tx / 900) 0 \(tx) 0\n"
    }

    static let bluetooth = #"""
    {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on","controller_address":"02:00:5E:10:0B:01","controller_chipset":"BCM_4388","controller_transport":"PCIe"},
    "device_connected":[{"Magic Keyboard":{"device_address":"02:00:5E:10:0B:02","device_minorType":"Keyboard","device_batteryLevelMain":"82%"}},
    {"MX Master 3S":{"device_address":"02:00:5E:10:0B:03","device_minorType":"Mouse","device_batteryLevelMain":"64%"}},
    {"AirPods Pro":{"device_address":"02:00:5E:10:0B:04","device_minorType":"Headphones","device_batteryLevelLeft":"91%","device_batteryLevelRight":"90%","device_batteryLevelCase":"77%"}}]}]}
    """#

    // MARK: 서버 (가상의 값)

    static func linuxSpec(_ server: Server) -> String {
        let home = server.key == "homelab"
        return """
        HOSTNAME     \(server.key)
        OS           Ubuntu 24.04.3 LTS
        KERNEL       6.8.0-87-generic
        ARCH         x86_64
        MODEL        \(home ? "Beelink|SER8||" : "QEMU|Standard PC (Q35 + ICH9, 2009)|kvm|")
        CPU          \(home ? "AMD Ryzen 7 8845HS (16 threads)" : "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz (4 threads)")
        REBOOT       no
        UPDATES      3;1
        UPDATE       openssl/noble-updates,noble-security 3.0.13-0ubuntu3.6 amd64 [upgradable from: 3.0.13-0ubuntu3.5]
        UPDATE       libssl3t64/noble-updates,noble-security 3.0.13-0ubuntu3.6 amd64 [upgradable from: 3.0.13-0ubuntu3.5]
        UPDATE       curl/noble-updates 8.5.0-2ubuntu10.7 amd64 [upgradable from: 8.5.0-2ubuntu10.6]
        INSTALLS     openssl libssl3t64 curl
        MEMORY       \(home ? "30Gi total, 21Gi available" : "7.8Gi total, 5.1Gi available")
        ROOT DISK    \(home ? "916G total, 302G used, 568G available (35%)" : "97G total, 41G used, 52G available (45%)")
        UPTIME       \(home ? 3_715_200 : 1_209_600)

        """
    }

    static let linuxServices: String = {
        let units: [(id: String, text: String, memory: Int, restarts: Int)] = [
            ("nginx.service", "A high performance web server and a reverse proxy server", 18_676_480, 0),
            ("docker.service", "Docker Application Container Engine", 96_468_992, 0),
            ("ssh.service", "OpenBSD Secure Shell server", 5_216_576, 0),
            ("cron.service", "Regular background program processing daemon", 528_384, 0),
            ("systemd-journald.service", "Journal Service", 28_216_576, 0),
            ("systemd-resolved.service", "Network Name Resolution", 7_215_936, 0),
        ]
        let blocks = units.map { unit in
            """
            Result=success
            NRestarts=\(unit.restarts)
            MemoryCurrent=\(unit.memory)
            Id=\(unit.id)
            Description=\(unit.text)
            ActiveState=active
            SubState=running
            StateChangeTimestampMonotonic=89188216
            ActiveEnterTimestampMonotonic=89188216
            """
        }.joined(separator: "\n\n")
        return """
        UPTIME=1209600.12
        ## UNITS
        \(blocks)
        ## CONTAINERS
        SOURCE|docker|ok
        C|web|Up 3 days (healthy)|nginx:1.27|0.0.0.0:80->80/tcp, [::]:80->80/tcp, 0.0.0.0:443->443/tcp, [::]:443->443/tcp|shop
        C|api|Up 3 days (healthy)|app/api:2.4|127.0.0.1:8080->8080/tcp|shop
        C|worker|Up 5 hours|app/worker:2.4||shop
        C|db|Up 2 weeks (healthy)|postgres:16|127.0.0.1:5432->5432/tcp|
        ## END

        """
    }()
}
