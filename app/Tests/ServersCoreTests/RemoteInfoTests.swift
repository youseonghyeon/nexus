// RemoteInfo: spec/services/ports 출력 파싱.

import Foundation
import XCTest
@testable import ServersCore

final class RemoteInfoTests: XCTestCase {
    func testSpec() {
        let lines = [
            "HOSTNAME     nexus", "OS           Ubuntu 22.04.4 LTS", "KERNEL       6.8.0-45-generic", "ARCH         x86_64",
            "CPU          8 threads", "MEMORY       15Gi total, 3.5Gi available",
            "ROOT DISK    460G total, 254G used, 187G available (55%)", "UPTIME       3 days, 4 hours, 12 minutes",
        ]
        let items = RemoteInfo.parseSpec(lines)
        XCTAssertEqual(items.map(\.key), ["HOSTNAME", "OS", "KERNEL", "ARCH", "CPU", "MEMORY", "ROOT DISK", "UPTIME"])
        XCTAssertEqual(items[0].value, "nexus"); XCTAssertEqual(items[0].label, "호스트")
        XCTAssertEqual(items[6].usage, 0.55)
        XCTAssertEqual(items[5].usage!, 1 - 3.5 / 15, accuracy: 0.01)
        XCTAssertEqual(items[7].label, "가동 시간")
        XCTAssertEqual(RemoteInfo.memoryUsage("7.7Gi total, 512Mi available")!, 1 - 0.5 / 7.7, accuracy: 0.01)
        XCTAssertNil(RemoteInfo.memoryUsage("garbage"))
        XCTAssertTrue(RemoteInfo.parseSpec(["not a spec line", ""]).isEmpty)
    }

    /// 2026-10-05 Spec 에 더한 줄: 원시 값 → 한국어·경고
    func testSpecExtras() {
        func one(_ line: String) -> SpecItem? { RemoteInfo.parseSpec([line]).first }
        XCTAssertEqual(one("MODEL        Dell Inc.|OptiPlex 7090|none")?.value, "Dell Inc. OptiPlex 7090")
        XCTAssertEqual(one("MODEL        LENOVO|ThinkCentre M70q||")?.value, "LENOVO ThinkCentre M70q", "Lenovo 는 스크립트가 product_version 으로 바꿔 보낸다")
        XCTAssertEqual(one("MODEL        |Raspberry Pi 4 Model B Rev 1.4|none")?.value, "Raspberry Pi 4 Model B Rev 1.4", "DMI 없는 보드")
        XCTAssertEqual(one("MODEL        QEMU|Standard PC (Q35 + ICH9, 2009)|kvm")?.value, "KVM 가상 머신 · QEMU Standard PC (Q35 + ICH9, 2009)")
        XCTAssertEqual(one("MODEL        To Be Filled By O.E.M.|To Be Filled By O.E.M.|none").map(\.value), nil, "채움 글뿐이면 줄을 숨긴다")
        XCTAssertEqual(one("MODEL        To be filled by O.E.M.|To be filled by O.E.M.|none|").map(\.value), nil, "대소문자 무시")
        XCTAssertEqual(one("MODEL        ||systemd-nspawn|c")?.value, "systemd-nspawn 컨테이너", "컨테이너 표시(c)를 따른다")
        XCTAssertEqual(one("MODEL        ||rkt|c")?.value, "rkt 컨테이너", "모르는 이름도 컨테이너면 컨테이너")
        XCTAssertEqual(one("MODEL        ||acrn|")?.value, "acrn 가상 머신")
        XCTAssertEqual(one("MODEL        Microsoft Corporation|Virtual Machine|microsoft")?.value, "Hyper-V 가상 머신 · Microsoft Corporation Virtual Machine")
        XCTAssertEqual(one("MODEL        ||docker")?.value, "Docker 컨테이너", "예전 3칸 출력")
        XCTAssertEqual(one("MODEL        ASUS|ROG STRIX B550-F|")?.value, "ASUS ROG STRIX B550-F", "Windows 는 가상화 칸이 비어 있다")
        XCTAssertEqual(one("REBOOT       yes")?.value, "필요")
        XCTAssertEqual(one("REBOOT       yes")?.warning, true)
        XCTAssertEqual(one("REBOOT       no")?.warning, false)
        XCTAssertEqual(one("UPDATES      12;3")?.value, "12개 (보안 3)")
        XCTAssertEqual(one("UPDATES      12;3")?.warning, true)
        XCTAssertEqual(one("UPDATES      5;0")?.warning, false)
        XCTAssertEqual(one("UPDATES      0;0")?.value, "최신")
        XCTAssertNil(one("UPDATES      E: something broke"), "apt-check 오류면 숨긴다")
        XCTAssertEqual(one("UPTIME       2170000")?.value, "25일 2시간")
        XCTAssertEqual(one("UPTIME       3 days, 4 hours, 12 minutes")?.value, "3 days, 4 hours, 12 minutes", "예전 꼴은 그대로")
        XCTAssertEqual(one("CPU          Intel(R) Xeon(R) Silver 4210R CPU @ 2.40GHz (8 threads)")?.value, "Intel(R) Xeon(R) Silver 4210R CPU @ 2.40GHz (8스레드)")
        XCTAssertEqual(one("CPU          8 threads")?.value, "8스레드")
    }

    func testPorts() {
        let items = RemoteInfo.parsePorts(["0.0.0.0:22", "[::]:22", "*:6443", "127.0.0.1:631", "0.0.0.0:445", ":::135", "garbage", ""])
        // v4/v6 의 같은 와일드카드 포트(0.0.0.0:22, [::]:22)는 한 줄로 합쳐진다
        XCTAssertEqual(items.map(\.port), [22, 135, 445, 631, 6443])
        XCTAssertEqual(items[0].addresses, ["*"]); XCTAssertEqual(items[0].label, "ssh")
        XCTAssertEqual(items[3].addresses, ["127.0.0.1"]); XCTAssertEqual(items[3].label, "cups")
        XCTAssertEqual(items[4].label, "k3s api")
        XCTAssertNil(RemoteInfo.parsePorts(["0.0.0.0:49152"]).first?.label)
    }

    /// UDP 포트 — 실제 출력: Fixtures/ss-ports-udp.txt (ubuntu:24.04 컨테이너에서 RemoteCommands.linuxPorts 그대로, 2026-11-24:
    /// TCP 53·8080·127.0.0.1:5432 · UDP 53·51820·127.0.0.1:9125)
    func testPortsWithUDP() throws {
        let items = RemoteInfo.parsePorts(try fixtureText("ss-ports-udp").split(separator: "\n").map(String.init))
        XCTAssertEqual(items.map(\.id), ["53", "5432", "8080", "53/udp", "9125/udp", "51820/udp"], "TCP 를 번호순으로 다 적은 뒤 UDP — 같은 번호(53)도 따로")
        XCTAssertEqual(items.map(\.udp), [false, false, false, true, true, true])
        XCTAssertEqual(items.map(\.label), ["dns", "postgres", "http-alt", "dns", nil, "wireguard"], "UDP 는 UDP 이름표로 (51820 은 UDP 뿐)")
        XCTAssertEqual(items.map(\.open), [true, false, true, true, false, true], "모든 주소로 듣는 것만 open (화면에서 딱지)")
        XCTAssertEqual(items.map(\.tunnelAddress), ["*", "127.0.0.1", "*", nil, nil, nil], "UDP 는 ssh 터널로 닿지 못한다")

        // UDP 를 쓰는 곳마다: 브라우저 시작 페이지는 TCP 만 (같은 번호의 UDP 가 타일·그 밖 자리를 먹지 않는다), 물어볼 대상에도 없다
        let sections = BrowserStartPage.sections(ports: items, probes: [:], probed: true)
        XCTAssertEqual(Set(sections.web.map(\.port) + sections.bare.map(\.port) + sections.other.map(\.port)), [53, 5432, 8080])
        XCTAssertEqual(sections.web.count + sections.bare.count + sections.other.count, 3, "53 이 두 번 나오지 않는다")
        XCTAssertEqual(BrowserStartPage.probeTargets(ports: items).map(\.port), [8080], "53·5432 는 비웹으로 아는 번호, UDP 는 묻지 않는다")
        XCTAssertFalse(WebProbe.isCandidate(PortItem(port: 9000, udp: true, addresses: ["*"], label: nil, tunnelAddress: "*")))
        // 변경 이력은 TCP 만 견준다 (UDP 는 잠깐 열리는 포트가 많다) — UDP 만 달라져서는 사건이 없다
        XCTAssertEqual(ServerHistory.observe(.ports(items), type: .linux)?.ports, ["53": "dns", "5432": "postgres", "8080": "http-alt"])
        let before = ServerHistory.record(ServerHistory.observe(.ports(items), type: .linux)!, serverKey: "s", in: HistoryState())
        let fewer = ServerHistory.observe(.ports(items.filter { $0.id != "51820/udp" }), type: .linux)!
        XCTAssertEqual(ServerHistory.record(fewer, serverKey: "s", in: before.state).events, [])
        XCTAssertNil(ServerHistory.observe(.ports(items.filter(\.udp)), type: .linux), "TCP 가 하나도 없으면 못 읽은 것으로 본다")
        // 옛 형식(UDP 줄 없음) · Windows 꼴은 그대로
        XCTAssertEqual(RemoteInfo.parsePorts(["0.0.0.0:22", "[::]:22"]).map(\.id), ["22"])
        XCTAssertEqual(RemoteInfo.parsePorts(["0.0.0.0:22|6788|sshd"]).map(\.udp), [false])
        XCTAssertTrue(RemoteCommands.linuxPorts.contains("ss -lnuH"))
        XCTAssertFalse(RemoteCommands.linuxPorts.contains("sudo"))
    }

    /// 장치에 묶인 소켓 (ss 의 %장치) — 실제 출력: Fixtures/ss-ports-bound.txt (ubuntu:24.04 컨테이너, SO_BINDTODEVICE lo)
    func testPortsBoundToDevice() throws {
        let lines = try fixtureText("ss-ports-bound").split(separator: "\n").map(String.init)
        let items = RemoteInfo.parsePorts(lines)
        XCTAssertEqual(items.map(\.port), [22, 10004, 10005, 10006], "포트마다 한 줄")
        let byPort = Dictionary(uniqueKeysWithValues: items.map { ($0.port, $0) })
        XCTAssertEqual(byPort[22]?.addresses, ["*"]); XCTAssertEqual(byPort[22]?.devices, [])
        XCTAssertEqual(byPort[10004]?.addresses, ["127.0.0.1", "::1"], "IPv4 먼저")
        XCTAssertEqual(byPort[10004]?.devices, ["lo"])
        XCTAssertEqual(byPort[10004]?.primaryAddress, "127.0.0.1")
        XCTAssertEqual(byPort[10005]?.addresses, ["*"], "0.0.0.0%lo 도 모든 주소")
        XCTAssertEqual(byPort[10006]?.addresses, ["*"], "[::]%lo 도 모든 주소")

        // 사용자 화면의 모양 (nexus, 2026-10-14): tailscale0 에 묶인 v4·v6 → 한 줄, 터널은 IPv4
        let ts = RemoteInfo.parsePorts(["100.101.0.1%tailscale0:10004", "[fd7a:115c:a1e0::1111:2222]%tailscale0:10004"])
        XCTAssertEqual(ts.count, 1)
        XCTAssertEqual(ts[0].addresses, ["100.101.0.1", "fd7a:115c:a1e0::1111:2222"])
        XCTAssertEqual(ts[0].devices, ["tailscale0"])
        XCTAssertEqual(ts[0].addressText, "100.101.0.1 · fd7a:115c:a1e0::1111:2222")
        XCTAssertEqual(ts[0].tunnelAddress, "100.101.0.1")
        XCTAssertEqual(TunnelTarget.fromListenAddress(ts[0].tunnelAddress!), "100.101.0.1")

        // 터널 주소: 열린 와일드카드(장치 없음·lo)는 서버 자신, 다른 장치에 묶인 와일드카드뿐이면 없음(버튼 비활성)
        XCTAssertEqual(byPort[22]?.tunnelAddress, "*")
        XCTAssertEqual(byPort[10005]?.tunnelAddress, "*", "0.0.0.0%lo 는 루프백으로 닿는다")
        XCTAssertEqual(byPort[10004]?.tunnelAddress, "127.0.0.1")
        XCTAssertNil(RemoteInfo.parsePorts(["0.0.0.0%eth0:8080"]).first?.tunnelAddress, "eth0 에 묶인 와일드카드는 127.0.0.1 연결을 거부한다")
        XCTAssertNil(RemoteInfo.parsePorts(["0.0.0.0%eth0:8080", "[::]%eth0:8080"]).first?.tunnelAddress)
        XCTAssertEqual(RemoteInfo.parsePorts(["0.0.0.0%eth0:8080", "10.0.0.5%eth0:8080"]).first?.tunnelAddress, "10.0.0.5", "특정 주소가 있으면 그걸로")
        XCTAssertEqual(RemoteInfo.parsePorts(["0.0.0.0%eth0:8080", "0.0.0.0:8080"]).first?.tunnelAddress, "*", "묶이지 않은 와일드카드가 있으면 서버 자신")
        // IPv4-mapped 는 IPv4 로, 링크로컬은 터널 주소 후보에서 뺀다 (fable 리뷰 컨테이너 실측 2026-10-14)
        let mapped = RemoteInfo.parsePorts(["[::ffff:127.0.0.1]:9000", "127.0.0.1:9000"])
        XCTAssertEqual(mapped.first?.addresses, ["127.0.0.1"])
        XCTAssertEqual(mapped.first?.tunnelAddress, "127.0.0.1")
        XCTAssertNil(RemoteInfo.parsePorts(["[fe80::1]%eth0:9001"]).first?.tunnelAddress)
        XCTAssertEqual(RemoteInfo.parsePorts(["[fe80::1]%eth0:9002", "10.0.0.5%eth0:9002"]).first?.tunnelAddress, "10.0.0.5")
    }
}
