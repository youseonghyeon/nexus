import Foundation
@testable import ServersCore
import XCTest

final class LocalInfoTests: XCTestCase {
    /// lsof -F pcn: p/c 는 뒤따르는 n 줄에 적용, f 줄은 무시, 같은 주소:포트(IPv4·IPv6 중복)는 하나로.
    func testParseListeningPortsFromLsofFields() {
        let text = """
        p675
        cControlCenter
        f9
        n*:7000
        f10
        n*:7000
        f11
        n*:5000
        p9123
        cssh
        f5
        n127.0.0.1:15432
        f6
        n[::1]:15432
        p9200
        cnode
        f20
        n0.0.0.0:3000
        """
        let ports = LocalCommands.parseListeningPorts(text)
        XCTAssertEqual(ports.map(\.port), [3000, 5000, 7000, 15432, 15432])
        XCTAssertEqual(ports.map(\.address), ["*", "*", "*", "127.0.0.1", "::1"])
        XCTAssertEqual(ports.map(\.command), ["node", "ControlCenter", "ControlCenter", "ssh", "ssh"])
        XCTAssertEqual(ports.first { $0.port == 15432 }?.pid, 9123)
    }

    /// Ports 카드의 "터널 → 서버" 딱지: 포트와 바인드 주소가 모두 같은 줄에만.
    /// 번호만 견주던 때는 다른 프로그램의 같은 포트 줄에도 붙고, 같은 포트의 터널이 둘이면 첫 서버 이름만 나왔다.
    func testTunnelForListeningPortMatchesBindAddress() {
        let web = Server.sample(key: "web", network: .lan, type: .linux, ip: "192.0.2.10", check: .ssh)
        let db = Server.sample(key: "db", network: .lan, type: .linux, ip: "192.0.2.11", check: .ssh)
        let plain = TunnelSpec(server: web, kind: .port(remotePort: 3000), localPort: 3000)
        let named = TunnelSpec(server: db, kind: .port(remotePort: 3000), localPort: 3000, bindAddress: "127.0.0.2", hostName: "db.example")
        func port(_ address: String, _ number: Int = 3000) -> LocalPort { LocalPort(port: number, address: address, command: "x", pid: 1) }

        // 겹치는 포트: 주소로 가른다 (순서와 무관)
        XCTAssertEqual(port("127.0.0.1").tunnel(among: [named, plain])?.server.key, "web")
        XCTAssertEqual(port("127.0.0.2").tunnel(among: [plain, named])?.server.key, "db")
        // 다른 루프백 별칭 · 모든 주소 · IPv6 루프백의 같은 포트는 다른 프로그램이다
        XCTAssertNil(port("127.0.0.3").tunnel(among: [plain, named]))
        XCTAssertNil(port("*").tunnel(among: [plain, named]))
        XCTAssertNil(port("::1").tunnel(among: [plain, named]))
        XCTAssertNil(port("127.0.0.1").tunnel(among: [named]))
        // 주소는 같고 포트가 다르면 아니다
        XCTAssertNil(port("127.0.0.1", 3001).tunnel(among: [plain]))
        // 터널 없음
        XCTAssertNil(port("127.0.0.1").tunnel(among: []))
    }

    func testParseInterfaceAddressesSkipsLoopbackAndIPv6() {
        let text = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \tinet 127.0.0.1 netmask 0xff000000
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet6 fe80::1%en0 prefixlen 64
        \tinet 192.168.100.3 netmask 0xffffff00 broadcast 192.168.100.255
        en10: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 10.50.10.17 netmask 0xffffff00 broadcast 10.50.10.255
        utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
        \tinet 100.101.1.0 --> 100.101.1.0 netmask 0xffffffff
        """
        let pairs = LocalCommands.parseInterfaceAddresses(text)
        XCTAssertEqual(pairs.map(\.device), ["en0", "en10", "utun5"])
        XCTAssertEqual(pairs.map(\.ip), ["192.168.100.3", "10.50.10.17", "100.101.1.0"])
    }

    /// 같은 NIC 에 프리셋이 둘이면 주소 이름은 활성 서비스 (비활성은 보이지 않는다). 서비스가 없는 utun 의 100.x 는 Tailscale.
    func testAddressesPreferEnabledServiceOnSharedNIC() async {
        final class Runner: CommandRunner, @unchecked Sendable {
            func hasExecutable(_ name: String) -> Bool { true }
            func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
                switch executable {
                case "ifconfig": return CommandResult(exitCode: 0, stdout: "en0: flags\n\tinet 192.168.100.3 netmask 0xffffff00\nen10: flags\n\tinet 10.50.10.17 netmask 0xffffff00\nutun5: flags\n\tinet 100.101.1.0 --> 100.101.1.0 netmask 0xffffffff\n")
                case "networksetup": return CommandResult(exitCode: 0, stdout: "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n\n(*) iptime Hub NIC\n(Hardware Port: USB LAN, Device: en10)\n\n(2) Acme Intranet\n(Hardware Port: USB LAN, Device: en10)\n")
                default: return CommandResult(exitCode: 127)
                }
            }
        }
        let list = await LocalInfoFetcher.addresses(runner: Runner())
        XCTAssertEqual(list.map(\.name), ["Wi-Fi", "Acme Intranet", "Tailscale"])
    }

    /// 같은 NIC 에 활성 서비스가 둘이면 주소도 둘 — 각 주소는 -getinfo IP 가 같은 서비스 이름, id 도 따로 (같은 id 면 한 행이 두 번 그려졌다)
    func testAddressesNameEachIPOnSharedNICWithTwoEnabledServices() async {
        final class Runner: CommandRunner, @unchecked Sendable {
            func hasExecutable(_ name: String) -> Bool { true }
            func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
                switch (executable, arguments.first) {
                case ("ifconfig", _): return CommandResult(exitCode: 0, stdout: "en10: flags\n\tinet 10.50.10.17 netmask 0xffffff00\n\tinet 172.30.1.149 netmask 0xffffff00\n")
                case ("networksetup", "-listnetworkserviceorder"):
                    return CommandResult(exitCode: 0, stdout: "(1) iptime Hub NIC\n(Hardware Port: USB LAN, Device: en10)\n\n(2) acme ethernet\n(Hardware Port: USB LAN, Device: en10)\n")
                case ("networksetup", "-getinfo"):
                    let ip = arguments.last == "iptime Hub NIC" ? "172.30.1.149" : "10.50.10.17"
                    return CommandResult(exitCode: 0, stdout: "DHCP Configuration\nIP address: \(ip)\nSubnet mask: 255.255.255.0\n")
                default: return CommandResult(exitCode: 127)
                }
            }
        }
        let list = await LocalInfoFetcher.addresses(runner: Runner())
        XCTAssertEqual(list.map(\.ip), ["10.50.10.17", "172.30.1.149"])
        XCTAssertEqual(list.map(\.name), ["acme ethernet", "iptime Hub NIC"])
        XCTAssertEqual(Set(list.map(\.id)).count, 2)
    }

    /// 이 Mac 에서 zsh 를 돌려 출력을 받는다 (로컬 명령뿐, 서버 접속 없음)
    private func zsh(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", script]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, text)
        return text
    }

    /// 바뀌지 않는 Spec(zsh) + 바뀌는 Spec(앱 안 값)을 이 Mac 에서 실제로 읽어 예전 한 스크립트와 같은 순서·형식으로 파싱되는지 본다.
    func testMacSpecRunsAndParsesLikeLinuxSpec() throws {
        let text = LocalCommands.mergeSpec(static: try zsh(LocalCommands.macSpecStatic).split(separator: "\n").map(String.init),
                                           live: LocalSpecProbe.liveLines()).joined(separator: "\n")
        let items = RemoteInfo.parseSpec(text.split(separator: "\n").map(String.init))
        XCTAssertEqual(items.map(\.key), ["HOSTNAME", "OS", "KERNEL", "ARCH", "CPU", "MEMORY", "ROOT DISK", "UPTIME", "MODEL"], text)
        XCTAssertTrue(items.first { $0.key == "MODEL" }!.value.hasPrefix("Mac"), "system_profiler 모델명 (MacBook·Mac mini …)")
        XCTAssertTrue(items.first { $0.key == "OS" }!.value.hasPrefix("macOS "))
        XCTAssertNotNil(items.first { $0.key == "MEMORY" }?.usage, "메모리 사용률")
        XCTAssertNotNil(items.first { $0.key == "ROOT DISK" }?.usage, "디스크 사용률")
        // 디스크는 컨테이너 기준 (크기 − 여유) — "/" 의 Used(봉인된 시스템 볼륨만)를 쓰면 6% 처럼 작게 나왔다
        let fs = try FileManager.default.attributesOfFileSystem(forPath: "/")
        let size = (fs[.systemSize] as! NSNumber).doubleValue, free = (fs[.systemFreeSize] as! NSNumber).doubleValue
        XCTAssertEqual(items.first { $0.key == "ROOT DISK" }!.usage!, (size - free) / size, accuracy: 0.03, text)
        // 가동 시간은 초로 받아 "N일 N시간" 꼴로 (원격 Spec 과 같은 표기)
        let uptime = items.first { $0.key == "UPTIME" }!.value
        let days = uptime.contains("일") ? Int(uptime.split(separator: "일").first ?? "") ?? -1 : 0
        XCTAssertTrue((0...3650).contains(days), "부팅 시각 계산이 틀리면 수만 일이 나온다: \(uptime)")
        XCTAssertFalse(uptime.contains("days"), uptime)
        XCTAssertTrue(items.first { $0.key == "CPU" }!.value.hasSuffix("스레드)"))
    }

    /// 앱 안에서 읽는 메모리·디스크·가동 시간이 예전 zsh(vm_stat·df -k /·kern.boottime) 와 같은 값인지 이 Mac 에서 맞춰 본다
    func testLiveSpecMatchesOldScript() throws {
        let old = """
        mem_total=$(sysctl -n hw.memsize); page=$(sysctl -n hw.pagesize)
        mem_free=$(vm_stat | awk -v p="$page" '/Pages free|Pages inactive|Pages speculative/ { gsub("\\\\.", "", $NF); s += $NF } END { printf "%.0f", s * p }')
        printf '%-12s %.1fGi total, %.1fGi available\\n' MEMORY $((mem_total / 1073741824.0)) $((mem_free / 1073741824.0))
        df -k / | awk 'NR == 2 { t = $2 / 1048576; a = $4 / 1048576; u = t - a; printf "%-12s %.0fGi total, %.0fGi used, %.0fGi available (%.0f%%)\\n", "ROOT DISK", t, u, a, (t > 0 ? u * 100 / t : 0) }'
        boot=$(sysctl -n kern.boottime | sed -E 's/^\\{ sec = ([0-9]+).*/\\1/'); up=$(( $(date +%s) - boot ))
        printf '%-12s %d\\n' UPTIME $up
        """
        let script = try zsh(old).split(separator: "\n").map(String.init)
        let live = LocalSpecProbe.liveLines()
        XCTAssertEqual(live.count, 3)
        let a = RemoteInfo.parseSpec(script), b = RemoteInfo.parseSpec(live)
        XCTAssertEqual(a.map(\.key), b.map(\.key))
        // 메모리 total 은 같고 available 은 두 읽기 사이에 조금 움직인다
        XCTAssertEqual(script[0].components(separatedBy: ",").first, live[0].components(separatedBy: ",").first, "\(script[0]) / \(live[0])")
        XCTAssertEqual(a[0].usage!, b[0].usage!, accuracy: 0.05, "\(script[0]) / \(live[0])")
        // 디스크 total 은 같고, 여유는 그 사이 쓰기로 1Gi 안쪽만 움직인다
        XCTAssertEqual(script[1].components(separatedBy: ",").first, live[1].components(separatedBy: ",").first, "\(script[1]) / \(live[1])")
        XCTAssertEqual(a[1].usage!, b[1].usage!, accuracy: 0.01, "\(script[1]) / \(live[1])")
        let up = { (line: String) in Int(line.split(separator: " ").last ?? "") ?? -1 }
        XCTAssertEqual(Double(up(script[2])), Double(up(live[2])), accuracy: 2, "\(script[2]) / \(live[2])")
    }

    /// 바뀌는 줄은 printf '%-12s …' 와 같은 글 · MODEL 앞에 끼운다 (MODEL 이 없으면 끝에)
    func testLiveSpecLinesFormatAndMerge() {
        let lines = LocalCommands.liveSpecLines(memoryTotal: 17_179_869_184, memoryAvailable: 3_758_096_384,
                                                diskTotalKB: 488_245_288, diskAvailableKB: 209_715_200, uptime: 93_784)
        XCTAssertEqual(lines, ["MEMORY       16.0Gi total, 3.5Gi available",
                               "ROOT DISK    466Gi total, 266Gi used, 200Gi available (57%)",
                               "UPTIME       93784"])
        XCTAssertEqual(LocalCommands.mergeSpec(static: ["HOSTNAME     a", "CPU          b", "MODEL        |Mac"], live: ["M", "U"]),
                       ["HOSTNAME     a", "CPU          b", "M", "U", "MODEL        |Mac"])
        XCTAssertEqual(LocalCommands.mergeSpec(static: ["HOSTNAME     a"], live: ["M"]), ["HOSTNAME     a", "M"])
    }

    // MARK: this Mac 화면 읽기 주기 (LocalInfoCollector)

    private func count(_ runner: FakeRunner, _ command: String) -> Int {
        runner.calls.filter { ([$0.executable] + $0.arguments).joined(separator: " ").hasPrefix(command) }.count
    }

    /// 바뀌지 않는 Spec 은 한 번, 포트·라우팅 표·방화벽·프록시는 30초에 한 번, 주소는 매번. 새로고침(force)은 전부 다시.
    func testCollectorReadsSlowPartsEvery30SecondsAndForceBypasses() async {
        let runner = FakeRunner()
        runner.scripted["/bin/zsh -c \(LocalCommands.macSpecStatic)"] = CommandResult(exitCode: 0, stdout: "HOSTNAME     test-mac\nMODEL        |Mac (Mac16,1)\n")
        let collector = LocalInfoCollector(liveSpec: { ["UPTIME       60"] })
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var info = await collector.collect(runner: runner, now: t0)
        XCTAssertEqual(info.spec.map(\.key), ["HOSTNAME", "UPTIME", "MODEL"], "바뀌는 줄은 MODEL 앞")
        for at in [5.0, 10, 29] { info = await collector.collect(runner: runner, now: t0 + at) }
        XCTAssertEqual(count(runner, "/bin/zsh"), 1, "Spec 스크립트(system_profiler 포함)는 한 번")
        XCTAssertEqual(count(runner, "lsof"), 1)
        XCTAssertEqual(count(runner, "netstat"), 1)
        XCTAssertEqual(count(runner, FirewallState.tool + " --getglobalstate"), 1, "방화벽(socketfilterfw)도 30초에 한 번")
        XCTAssertEqual(count(runner, "scutil --proxy"), 1)
        XCTAssertEqual(count(runner, "networksetup -listnetworkserviceorder"), 4, "주소는 매번")
        XCTAssertEqual(info.portsAt, t0, "포트는 처음 읽은 시각 그대로")
        XCTAssertEqual(info.fetchedAt, t0 + 29)

        _ = await collector.collect(runner: runner, now: t0 + 30)
        XCTAssertEqual(count(runner, "lsof"), 2, "30초가 지나면 다시")
        XCTAssertEqual(count(runner, "scutil --proxy"), 2)
        XCTAssertEqual(count(runner, "/bin/zsh"), 1, "Spec 은 시간이 지나도 다시 읽지 않는다")

        info = await collector.collect(runner: runner, force: true, now: t0 + 31)
        XCTAssertEqual(count(runner, "/bin/zsh"), 2, "새로고침은 Spec 까지 다시")
        XCTAssertEqual(count(runner, "lsof"), 3)
        XCTAssertEqual(count(runner, "netstat"), 3)
        XCTAssertEqual(count(runner, "scutil --proxy"), 3)
        XCTAssertEqual(info.portsAt, t0 + 31)
    }

    /// 망·VPN·Tailscale 을 켜고 끄면(slowKey 가 바뀌면) 30초를 기다리지 않고 라우팅 표 등을 다시 읽는다. 포트는 그대로 30초.
    func testCollectorRereadsSlowPartsWhenNetworkKeyChanges() async {
        let runner = FakeRunner()
        let collector = LocalInfoCollector(liveSpec: { [] })
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = await collector.collect(runner: runner, slowKey: "wired:en9", now: t0)
        _ = await collector.collect(runner: runner, slowKey: "wired:en9", now: t0 + 5)
        XCTAssertEqual(count(runner, "netstat"), 1)
        _ = await collector.collect(runner: runner, slowKey: "wired:", now: t0 + 6)
        XCTAssertEqual(count(runner, "netstat"), 2, "조건이 바뀌면 바로 다시")
        XCTAssertEqual(count(runner, "scutil --proxy"), 2)
        XCTAssertEqual(count(runner, "lsof"), 1, "포트는 망과 무관 — 30초 그대로")
        _ = await collector.collect(runner: runner, slowKey: "wired:", now: t0 + 10)
        XCTAssertEqual(count(runner, "netstat"), 2, "같은 조건이면 다시 30초")
    }

    /// Spec 스크립트가 빈 출력이면 쥐지 않고 다음에 다시 읽는다 (처음 한 번 실패로 Spec 이 계속 비지 않게)
    func testCollectorRetriesEmptyStaticSpec() async {
        let runner = FakeRunner()   // /bin/zsh 는 127 (빈 출력)
        let collector = LocalInfoCollector(liveSpec: { [] })
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = await collector.collect(runner: runner, now: t0)
        _ = await collector.collect(runner: runner, now: t0 + 5)
        XCTAssertEqual(count(runner, "/bin/zsh"), 2)
        runner.scripted["/bin/zsh -c \(LocalCommands.macSpecStatic)"] = CommandResult(exitCode: 0, stdout: "HOSTNAME     test-mac\n")
        _ = await collector.collect(runner: runner, now: t0 + 10)
        _ = await collector.collect(runner: runner, now: t0 + 15)
        XCTAssertEqual(count(runner, "/bin/zsh"), 3, "읽은 뒤엔 다시 읽지 않는다")
    }

    /// Routes 카드의 utun 줄 "→ en11": 연결된 시스템 VPN 마다 show·status 로 터널(utun7)·확장 번들을 읽어 바깥 장치를 붙인다.
    /// 꺼진 VPN 은 묻지 않는다 (scutil-nc-* · nettop 픽스처는 이 Mac 의 실제 출력)
    func testCollectorFillsTunnelEgressForConnectedVPN() async throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let netstat = CommandResult(exitCode: 0, stdout: "Destination Gateway Flags Netif Expire\ndefault link#26 UCSg utun7\n")
        let runner = FakeRunner()
        runner.scripted["netstat -rn -f inet"] = netstat
        runner.scripted["scutil --nc show \(id)"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-show-wireguard"))
        runner.scripted["scutil --nc status \(id)"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-status-connected"))
        // 시스템 확장 꼴 경로 (번들 ID 가 경로에 있다) — .appex 는 실제 번들을 읽어야 해서 여기선 쓰지 않는다
        runner.scripted["ps -axo pid=,comm="] = CommandResult(exitCode: 0, stdout: "    1 /sbin/launchd\n 1260 /Library/SystemExtensions/AB/com.wireguard.macos.network-extension.systemextension/Contents/MacOS/ext\n")
        runner.scripted["nettop -L 1 -n -m udp -p 1260"] = CommandResult(exitCode: 0, stdout: try fixtureText("nettop-wireguard-udp"))
        runner.scripted["nettop -L 1 -n -m tcp -p 1260"] = CommandResult(exitCode: 0, stdout: "")
        runner.scripted["route -n get -ifscope en11 default"] = CommandResult(exitCode: 0, stdout: "    gateway: 192.168.8.1\n  interface: en11\n")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var vpn = SystemVPN(id: id, name: "MacBook", kind: "WireGuard", enabled: true, state: .connected)
        let info = await LocalInfoCollector(liveSpec: { [] }).collect(runner: runner, vpns: [vpn], now: t0)
        XCTAssertEqual(info.routes?.tunnelEgress, ["utun7": ["en11"]])
        XCTAssertEqual(info.routes.map { $0.detail(for: $0.entries[0]) }, "→ en11", "default 줄(utun7) 끝에 나가는 장치")

        let offRunner = FakeRunner()
        offRunner.scripted["netstat -rn -f inet"] = netstat
        vpn.state = .disconnected
        let off = await LocalInfoCollector(liveSpec: { [] }).collect(runner: offRunner, vpns: [vpn], now: t0)
        XCTAssertEqual(off.routes?.tunnelEgress, [:])
        XCTAssertFalse(offRunner.calls.contains { $0.arguments.contains("show") || $0.executable == "nettop" }, "꺼진 VPN 은 읽지 않는다")
    }
}
