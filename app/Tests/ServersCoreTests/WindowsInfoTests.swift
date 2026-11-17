// Windows 서버의 Live · Network · Ports · Spec (WindowsLive · WindowsNetwork · RemoteInfo).
// Fixtures/windows-*.txt 는 앱이 보내는 스크립트를 실제 Windows 11(26100 · PowerShell 5.1)에서 돌린 출력이다 (2026-11-10, 사용자가 돌려 전달).
// live 는 3초 간격 두 번 (@INFO 의 물리 코어 수 줄 "8" 은 뒤에 더한 것 — 그 장비 i7-11700 의 값을 손으로 넣었다). network 의 MAC · 링크로컬 주소만 가짜 값으로 바꿨다. 실제 서버에는 접속하지 않는다.

import Foundation
import XCTest
@testable import ServersCore

final class WindowsInfoTests: XCTestCase {

    // MARK: Live

    func testLiveParsesRealOutput() throws {
        let raw = try XCTUnwrap(WindowsRaw.parse(try fixtureText("windows-live-1")))
        XCTAssertEqual(raw.uptime, 774)
        XCTAssertEqual(raw.model, "11th Gen Intel(R) Core(TM) i7-11700 @ 2.50GHz")
        XCTAssertEqual(raw.memoryTotal, 33_433_208)
        XCTAssertEqual(raw.memoryAvailable, 19_808_904)
        XCTAssertEqual(raw.pageTotal, 4864)
        XCTAssertEqual(raw.cores.count, 16)
        XCTAssertEqual(raw.physicalCores, 8)
        // 코어 0 의 원시 값: idle 6924843750 · user 250781250 · privileged 567031250
        XCTAssertEqual(raw.cores[0].values[0], 250_781_250)
        XCTAssertEqual(raw.cores[0].values[2], 567_031_250)
        XCTAssertEqual(raw.cores[0].values[3], 6_924_843_750)
        XCTAssertNotNil(raw.cpu)
        XCTAssertFalse(raw.processes.contains { $0.pid == 0 }, "Idle 은 프로세스가 아니다")
        XCTAssertFalse(raw.processes.contains { $0.command.contains("#") }, "같은 이름에 붙는 #번호는 뗀다")
        XCTAssertTrue(raw.processes.contains { $0.command == "svchost" })
        XCTAssertEqual(Set(raw.disks.keys), ["C:", "D:"], "_Total 은 뺀다, 이름은 드라이브 글자")
        XCTAssertEqual(raw.diskInfo["C:"], LinuxDiskInfo(rotational: false, size: 500_107_862_016, model: "Samsung SSD 870 EVO 500GB", healthy: true))
        XCTAssertEqual(raw.diskInfo["D:"]?.rotational, true)
        XCTAssertEqual(raw.volumes.map(\.mountPoint), ["C:", "D:"])
        XCTAssertEqual(raw.volumes[0].percent, 93)
        XCTAssertEqual(raw.interfaces.map(\.name), ["Realtek Gaming 2.5GbE Family Controller"])
        XCTAssertEqual(raw.interfaces[0].speedMbps, 2500)
        XCTAssertEqual(raw.gpus, [LiveGPU(name: "NVIDIA GeForce RTX 3070 Ti", utilization: 3, memoryUsed: 1843 * 1_048_576, memoryTotal: 8192 * 1_048_576,
                                         temperature: 35, power: 19.41)])
    }

    func testLiveComputesDeltasBetweenRealSamples() throws {
        let first = try XCTUnwrap(WindowsRaw.parse(try fixtureText("windows-live-1")))
        let second = try XCTUnwrap(WindowsRaw.parse(try fixtureText("windows-live-2")))
        var sampler = WindowsLiveSampler()
        let a = sampler.step(first, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(a.system, .windows)
        XCTAssertEqual(a.coresText, "8코어 16스레드")
        XCTAssertNil(a.cpu, "첫 표본은 기준값만")
        XCTAssertNil(a.disk)
        XCTAssertTrue(a.interfaces.isEmpty)
        XCTAssertTrue(a.processes.allSatisfy { $0.cpu == 0 })
        // 메모리: 전체 − 사용 가능
        let memory = try XCTUnwrap(a.memory)
        XCTAssertEqual(memory.total, 33_433_208 * 1024)
        XCTAssertEqual(memory.used, (33_433_208 - 19_808_904) * 1024)
        XCTAssertEqual(memory.swapTotal, 4864 * 1_048_576)
        XCTAssertEqual(a.pressure, .normal)

        let b = sampler.step(second, at: Date(timeIntervalSince1970: 3))
        // _Total: Δidle 30380860 · Δuser 2304687 · Δprivileged 1083984 → 바쁨 3388671 / 33769531 = 10.03%
        let cpu = try XCTUnwrap(b.cpu)
        XCTAssertEqual(cpu.total, 10.03, accuracy: 0.01)
        XCTAssertEqual(cpu.user, 6.82, accuracy: 0.01)
        XCTAssertEqual(cpu.system, 3.21, accuracy: 0.01)
        XCTAssertEqual(cpu.cores.count, 16)
        XCTAssertTrue(cpu.cores.allSatisfy { (0...100).contains($0) })
        // C: 읽기: (12216169472 − 12173206528) / 3.3760663초
        let seconds = Double(134_387_914_782_366_629 - 134_387_914_748_605_966) / 1e7
        XCTAssertEqual(b.perDisk["C:"]?.read ?? 0, Double(12_216_169_472 - 12_173_206_528) / seconds, accuracy: 1)
        XCTAssertEqual(b.perDisk["D:"]?.read, 0)
        // 네트워크: (87934552 − 87920699) / 3.376초
        let net = try XCTUnwrap(b.interfaces.first)
        XCTAssertEqual(net.rx, Double(87_934_552 - 87_920_699) / 3.376, accuracy: 1)
        XCTAssertEqual(b.networkTotal?.rx, net.rx)
        XCTAssertTrue(b.processes.contains { $0.cpu > 0 }, "두 번째 표본부터 프로세스 CPU 가 나온다")
        XCTAssertTrue(b.processes.allSatisfy { $0.cpu >= 0 && $0.cpu <= 1600 })
        XCTAssertEqual(LinuxHealth.judge(b).text, "공간 부족", "C: 93%")
    }

    func testLiveEdgeCases() {
        XCTAssertNil(WindowsRaw.parse("@INFO\r\n774\t1\t1\t1\t1\r\n"), "@END 가 없으면 끊긴 출력")
        // 값이 비거나 구역이 없어도 죽지 않는다 (WMI 클래스가 없는 Windows · nvidia-smi 없음)
        let empty = WindowsRaw.parse("@INFO\r\n@CPU\r\n@PROC\r\n@GPU\r\n@END\r\n")
        XCTAssertEqual(empty, WindowsRaw())
        var sampler = WindowsLiveSampler()
        let snapshot = sampler.step(WindowsRaw(), at: Date())
        XCTAssertNil(snapshot.memory)
        XCTAssertNil(snapshot.cpu)
        XCTAssertNil(snapshot.coresText, "코어를 못 읽었으면 적지 않는다")
        // 하이퍼스레딩이 없으면(물리 = 논리) · 물리 코어를 모르면(리눅스 · 옛 출력) "코어 N개"
        var plain = LinuxLiveSnapshot(at: Date())
        plain.cores = 8
        XCTAssertEqual(plain.coresText, "코어 8개")
        plain.physicalCores = 8
        XCTAssertEqual(plain.coresText, "코어 8개")
        plain.physicalCores = 4
        XCTAssertEqual(plain.coresText, "4코어 8스레드")
        XCTAssertNil(WindowsRaw.parse("@INFO\n1\t1\t1\t1\t1\nCPU X\n0\n@END")?.physicalCores, "0 은 못 읽은 것")
        // 숫자순 — 글자순이면 코어 10 이 2 앞에 온다. 프로세서 그룹이 여럿("0,3" · "1,0")이면 그룹 · 번호순
        let text = ["@CPU", "10\t40\t0\t0\t9", "2\t30\t0\t0\t9", "1,0\t20\t0\t0\t9", "0,3\t10\t0\t0\t9", "_Total\t1\t1\t1\t9", "@END"].joined(separator: "\n")
        XCTAssertEqual(WindowsRaw.parse(text)?.cores.map { $0.values[3] }, [10, 20, 30, 40], "0,3 → 1,0 → 2 → 10")
        // 드라이브 글자가 없는 디스크 · 글자가 둘인 디스크, 상태 이상
        let disks = ["@DISK", "1\t2\t3\t4\t9\t2", "1\t2\t3\t4\t9\t0 C: D:", "@BLK", "2\t0\t17\t100\t2\tNVMe X", "0\t4\t11\t100\t1\tSSD Y", "@END"].joined(separator: "\n")
        let raw = WindowsRaw.parse(disks)
        XCTAssertEqual(raw.map { Set($0.disks.keys) }, ["Disk 2", "C: D:"])
        XCTAssertEqual(raw?.diskInfo["Disk 2"]?.healthy, false)
        XCTAssertNil(raw?.diskInfo["Disk 2"]?.rotational, "MediaType 0 = 모름")
        XCTAssertEqual(raw?.diskInfo["C: D:"]?.healthy, false)
        var s = LinuxLiveSnapshot(at: Date())
        s.diskInfo = raw?.diskInfo ?? [:]
        XCTAssertEqual(LinuxHealth.judge(s).level, .bad)
        XCTAssertEqual(LinuxHealth.judge(s).text, "디스크 이상 · SSD Y")
        // nvidia-smi 가 값을 못 읽으면 "[N/A]"
        XCTAssertEqual(LiveGPU.parse("[N/A], 100, 200, [N/A], [N/A], Tesla T4"),
                       LiveGPU(name: "Tesla T4", utilization: nil, memoryUsed: 100 * 1_048_576, memoryTotal: 200 * 1_048_576, temperature: nil, power: nil))
        XCTAssertNil(LiveGPU.parse("NVIDIA-SMI has failed"))
    }

    /// 카운터가 뒤로 가거나(재부팅) pid 가 다른 프로세스에 다시 쓰이면 그 구간 값은 0
    func testLiveCounterResetAndPidReuse() {
        func raw(stamp: UInt64, ticks: UInt64, start: UInt64) -> WindowsRaw {
            var r = WindowsRaw()
            r.processStamp = stamp
            r.processes = [LinuxProcessSample(pid: 100, state: "", ticks: ticks, threads: 1, rssPages: 10, startTime: start, command: "a")]
            return r
        }
        var sampler = WindowsLiveSampler()
        _ = sampler.step(raw(stamp: 10_000_000, ticks: 0, start: 1), at: Date())
        // 1초 동안 CPU 0.5초 → 50%
        XCTAssertEqual(sampler.step(raw(stamp: 20_000_000, ticks: 5_000_000, start: 1), at: Date()).processes[0].cpu, 50)
        // 같은 pid, 만든 시각이 다르다 → 다른 프로세스
        XCTAssertEqual(sampler.step(raw(stamp: 30_000_000, ticks: 9_000_000, start: 2), at: Date()).processes[0].cpu, 0)
        // 시각이 뒤로 갔다
        XCTAssertEqual(sampler.step(raw(stamp: 5_000_000, ticks: 9_500_000, start: 2), at: Date()).processes[0].cpu, 0)
    }

    // MARK: Network

    func testNetworkParsesRealOutput() throws {
        let lines = RemoteCommands.cleanOutput(try fixtureText("windows-network"), type: .windows)
        guard case .linuxNetwork(let parsed) = ParsedRemoteInfo.parse(.network, lines: lines, type: .windows) else { return XCTFail("windows network 는 .linuxNetwork") }
        let network = try XCTUnwrap(parsed)
        XCTAssertEqual(network.interfaces.map(\.name), ["이더넷", "vEthernet (Default Switch)", "vEthernet (WSL (Hyper-V firewall))", "Bluetooth 네트워크 연결"])
        let ethernet = network.interfaces[0]
        XCTAssertTrue(ethernet.up)
        XCTAssertNil(ethernet.kind)
        XCTAssertEqual(ethernet.addresses, ["192.168.8.102/24"], "링크로컬 IPv6 는 뺀다")
        XCTAssertEqual(ethernet.mac, "02:00:00:aa:bb:01")
        XCTAssertEqual(ethernet.descriptors, ["Realtek Gaming 2.5GbE Family Controller · 2.5 Gbps"])
        XCTAssertFalse(ethernet.isFolded)
        let hyperV = network.interfaces[1]
        XCTAssertEqual(hyperV.descriptors, ["virtual", "Hyper-V Virtual Ethernet Adapter"], "가상 어댑터는 속도를 적지 않는다")
        XCTAssertTrue(hyperV.isFolded)
        XCTAssertFalse(network.interfaces[3].up, "Disconnected")
        XCTAssertEqual(network.foldedTitle, "가상 어댑터")
        XCTAssertEqual(network.layout.visibleItems.map(\.id), ["이더넷"])
        XCTAssertEqual(network.layout.foldedItems.count, 3)
        // 경로: 대역 셋 + 기본 경로. /32 · 멀티캐스트 · 루프백 줄은 뺀다
        let routing = try XCTUnwrap(network.routing)
        XCTAssertEqual(routing.routes.map(\.destination), ["192.168.8.0/24", "172.25.80.0/20", "172.20.80.0/20", "default"])
        XCTAssertEqual(routing.defaultRoutes.map(\.gateway), ["192.168.8.1"])
        XCTAssertEqual(routing.defaultRoutes.first?.device, "이더넷")
        XCTAssertEqual(routing.defaultRoutes.first?.metric, 20, "RouteMetric 0 + InterfaceMetric 20")
        XCTAssertNil(routing.routes[0].gateway, "0.0.0.0 = On-link")
        XCTAssertTrue(routing.policyRules.isEmpty)
        XCTAssertEqual(network.dns, ["192.168.8.1"])
        // 이더넷 행 아래엔 기본 경로만, 자기 대역은 펼쳤을 때
        XCTAssertEqual(network.layout.items[0].routes.map(\.destination), ["default"])
        XCTAssertEqual(network.layout.items[0].subnetRoutes.map(\.destination), ["192.168.8.0/24"])
        XCTAssertTrue(network.layout.otherRoutes.isEmpty)
        // 경로 그림: 가상 어댑터를 빼면 이더넷 한 갈래
        let graph = RouteGraph(routing: routing, details: [:], excluding: Set(network.interfaces.filter(\.isFolded).map(\.name)))
        XCTAssertEqual(graph.lanes.map(\.device), ["이더넷"])
        XCTAssertTrue(RouteGraph.supportsLookup(routing))
    }

    func testNetworkEdgeCases() {
        XCTAssertNil(WindowsNetwork.parse(["@ADAPTER", "19|Up|1000000000|AA-BB|False|True|Ethernet|Intel"]), "@END 없음")
        XCTAssertNil(WindowsNetwork.parse(["@ADAPTER", "@END"]), "어댑터가 없으면 원문으로")
        // 경로 구역이 통째로 비면 "경로를 읽지 못했습니다", 어댑터 이름에 | 가 없다는 가정이 깨져도 죽지 않는다
        let noRoutes = WindowsNetwork.parse(["@ADAPTER", "19|Up|1000000000||False|True|Ethernet|Intel I225", "@IP", "@ROUTE", "@DNS", "@END"])
        XCTAssertNil(noRoutes?.routing)
        XCTAssertNil(noRoutes?.interfaces.first?.mac)
        XCTAssertEqual(noRoutes?.interfaces.first?.descriptors, ["Intel I225 · 1 Gbps"])
        // 기본 경로가 없는 Windows: 경로는 있으나 defaultRoutes 가 빈다 (화면의 "기본 경로 없음")
        let noDefault = WindowsNetwork.parse(["@ADAPTER", "19|Up|0||False|True|Ethernet|", "@ROUTE", "10.0.0.0/8|0.0.0.0|19|256|25|Ethernet", "@END"])
        XCTAssertEqual(noDefault?.routing?.routes.count, 1)
        XCTAssertEqual(noDefault?.routing?.defaultRoutes.isEmpty, true)
        XCTAssertEqual(noDefault?.interfaces.first?.descriptors, [], "설명도 속도도 없으면 빈 문자열을 남기지 않는다")
    }

    // MARK: Ports

    func testPortsParseRealOutputWithProcessNames() throws {
        let lines = RemoteCommands.cleanOutput(try fixtureText("windows-ports"), type: .windows)
        let ports = RemoteInfo.parsePorts(lines)
        XCTAssertEqual(ports.map(\.port), [22, 139, 445, 2222, 2656, 4433, 8916, 10051, 20101, 33307], "pid 0(Idle) 뿐인 8018 은 뺀다")
        XCTAssertEqual(ports.first { $0.port == 22 }?.process, "sshd")
        XCTAssertEqual(ports.first { $0.port == 22 }?.label, "ssh")
        XCTAssertEqual(ports.first { $0.port == 445 }?.addresses, ["*"])
        XCTAssertEqual(ports.first { $0.port == 10051 }?.addresses, ["::1"])
        XCTAssertEqual(ports.first { $0.port == 10051 }?.process, "wslrelay")
        XCTAssertEqual(ports.first { $0.port == 139 }?.tunnelAddress, "192.168.8.102")
    }

    func testPortsEdgeCases() {
        // 같은 포트를 두 프로세스가(v4 · v6 따로) — 이름을 둘 다, 같은 이름은 한 번
        let ports = RemoteInfo.parsePorts(["0.0.0.0:80|10|nginx", ":::80|11|httpd", "127.0.0.1:80|10|nginx", "0.0.0.0:81|12|"])
        XCTAssertEqual(ports.map(\.process), ["nginx, httpd", nil], "이름을 못 읽은 프로세스는 nil")
        // 리눅스(ss) 줄은 그대로 — 프로세스 없음
        XCTAssertEqual(RemoteInfo.parsePorts(["0.0.0.0:22", "[::]:22"]).map(\.process), [nil])
    }

    // MARK: Spec

    /// 스크립트가 내는 줄 형식 그대로 (값은 2026-11-10 win 실측): 드라이브마다 게이지, 물리 디스크 · GPU 는 값 가공
    func testSpecDrivesAndGPU() {
        let items = RemoteInfo.parseSpec([
            "HOSTNAME     DESKTOP-1",
            "DISK C       465G total, 430G used, 35G available (93%)",
            "DISK D       932G total, 715G used, 216G available (77%)",
            "DRIVE A      WDC WD10EZEX-00WN4A0|3|11|1000204886016|0",
            "DRIVE B      Samsung SSD 870 EVO 500GB|4|11|500107862016|0",
            "GPU A        NVIDIA GeForce RTX 3070 Ti|8589934592",
            "REBOOT       no",
        ])
        XCTAssertEqual(items.map(\.key), ["HOSTNAME", "DISK C", "DISK D", "DRIVE A", "DRIVE B", "GPU A", "REBOOT"])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "id 가 겹치면 화면 줄이 섞인다")
        XCTAssertEqual(items[1].label, "C:")
        XCTAssertEqual(items[1].usage, 0.93)
        XCTAssertEqual(items[2].usage, 0.77)
        XCTAssertEqual(items[3].value, "WDC WD10EZEX-00WN4A0 · HDD · SATA · 1 TB")
        XCTAssertEqual(items[3].label, "디스크")
        XCTAssertFalse(items[3].warning)
        XCTAssertEqual(items[4].value, "Samsung SSD 870 EVO 500GB · SSD · SATA · 500 GB")
        XCTAssertEqual(items[5].value, "NVIDIA GeForce RTX 3070 Ti · 8 GB")
        XCTAssertEqual(items[5].label, "GPU")
        XCTAssertNil(items[3].usage)
    }

    func testSpecDriveAndGPUEdgeCases() {
        // 상태가 정상이 아니면 경고색, 모르는 종류 · 버스는 뺀다
        XCTAssertEqual(RemoteInfo.formatDrive("KINGSTON SNV2S|4|17|2000398934016|1")?.value, "KINGSTON SNV2S · SSD · NVMe · 2 TB · 상태 경고")
        XCTAssertEqual(RemoteInfo.formatDrive("KINGSTON SNV2S|4|17|2000398934016|2")?.warning, true)
        XCTAssertEqual(RemoteInfo.formatDrive("Msft Virtual Disk|0|6|136365211648|0")?.value, "Msft Virtual Disk · 136 GB")
        XCTAssertEqual(RemoteInfo.formatDrive("X|4|17|1500301910016|0")?.value, "X · SSD · NVMe · 1.5 TB")
        XCTAssertNil(RemoteInfo.formatDrive("||||"), "이름이 없으면 줄을 숨긴다")
        XCTAssertNil(RemoteInfo.formatDrive("이름만"))
        // 내장 그래픽은 VRAM 값이 없다
        XCTAssertEqual(RemoteInfo.formatGPU("Intel(R) UHD Graphics 750|")?.value, "Intel(R) UHD Graphics 750")
        XCTAssertNil(RemoteInfo.formatGPU("|8589934592"))
        // 예전 줄(ROOT DISK)도 그대로 읽는다 — 리눅스
        XCTAssertEqual(RemoteInfo.parseSpec(["ROOT DISK    931G total, 412G used, 519G available (44%)"]).first?.usage, 0.44)
    }

    // MARK: 명령

    func testWindowsQueriesAndScripts() {
        for query in [RemoteCommands.Query.live, .network, .spec, .ports, .services] {
            let q = RemoteCommands.query(query, for: .windows)
            XCTAssertEqual(q?.command.hasPrefix("powershell.exe "), true, "\(query)")
            XCTAssertNil(q?.stdin, "\(query)")
        }
        for query in [RemoteCommands.Query.firewall, .clients, .wireguard, .schedule] {
            XCTAssertNil(RemoteCommands.query(query, for: .windows), "\(query)")
        }
        // Live 는 서버에서 기다리지 않는다 — 가공된 카운터 · 대기를 쓰면 0.3~6초가 든다
        XCTAssertFalse(WindowsLive.script.contains("PerfFormattedData"))
        XCTAssertFalse(WindowsLive.script.contains("Start-Sleep"))
        XCTAssertFalse(WindowsLive.script.contains("LoadPercentage"))
        XCTAssertTrue(WindowsLive.script.hasSuffix("\"@END\""))
        XCTAssertTrue(WindowsNetwork.script.hasSuffix("\"@END\""))
    }
}
