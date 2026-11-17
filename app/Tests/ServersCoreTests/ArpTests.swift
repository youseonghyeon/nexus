// ARP: arp -an 출력 읽기(2026-10-15 사용자 Mac 모양) · MAC 두 자리 맞춤 · 같은 대역 판정 · ping 뒤 조회.

import Foundation
@testable import ServersCore
import XCTest

final class ArpTests: XCTestCase {
    private let table = """
        ? (10.50.10.254) at 0:5:66:a0:b1:1b on en10 ifscope [ethernet]
        ? (10.50.10.9) at (incomplete) on en10 ifscope [ethernet]
        ? (192.168.100.3) at 26:85:c7:a8:b1:2a on en0 ifscope permanent [ethernet]
        ? (192.168.100.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        ? (192.168.139.3) at ae:7:75:a4:b2:64 on bridge100 ifscope permanent [bridge]
        10.0.0.9 (10.0.0.9) -- no entry
        """

    func testParse() {
        let entries = Arp.parse(table)
        XCTAssertEqual(entries.map(\.ip), ["10.50.10.254", "10.50.10.9", "192.168.100.3", "192.168.139.3"], "멀티캐스트·브로드캐스트·no entry 는 뺀다")
        XCTAssertEqual(entries[0], ArpEntry(ip: "10.50.10.254", mac: "00:05:66:a0:b1:1b", device: "en10"))
        XCTAssertNil(entries[1].mac, "incomplete")
        XCTAssertTrue(entries[2].permanent)
        XCTAssertEqual(Arp.normalizeMAC("AE:7:75:A4:B2:64"), "ae:07:75:a4:b2:64")
        XCTAssertNil(Arp.normalizeMAC("0:5:66"))
    }

    func testIsLocal() {
        let ifconfig = "en10: flags=8863<UP>\n\tinet 172.30.1.149 netmask 0xffffff00 broadcast 172.30.1.255\n\tinet 10.50.10.17 netmask 0xffffff00 broadcast 10.50.10.255\n"
        XCTAssertTrue(Arp.isLocal("10.50.10.254", ifconfig: ifconfig), "같은 장치의 두 번째 주소 대역도")
        XCTAssertTrue(Arp.isLocal("172.30.1.1", ifconfig: ifconfig))
        XCTAssertFalse(Arp.isLocal("192.168.112.11", ifconfig: ifconfig))
        XCTAssertFalse(Arp.isLocal("x", ifconfig: ifconfig))
    }

    func testLookupAndTable() async {
        let runner = FakeRunner()
        runner.scripted["ifconfig en10"] = CommandResult(exitCode: 0, stdout: "en10: flags=8863<UP>\n\tinet 10.50.10.17 netmask 0xffffff00 broadcast 10.50.10.255\n")
        runner.scripted["arp -n -i en10 10.50.10.254"] = CommandResult(exitCode: 0, stdout: "? (10.50.10.254) at 0:5:66:a0:b1:1b on en10 ifscope [ethernet]\n")
        runner.scripted["arp -n -i en10 10.50.10.9"] = CommandResult(exitCode: 0, stdout: "? (10.50.10.9) at (incomplete) on en10 ifscope [ethernet]\n")
        runner.scripted["arp -n -i en10 10.50.10.8"] = CommandResult(exitCode: 1, stdout: "10.50.10.8 (10.50.10.8) -- no entry\n")
        let found = await Arp.lookup("10.50.10.254", device: "en10", runner: runner)
        XCTAssertEqual(found, .found(mac: "00:05:66:a0:b1:1b"))
        let incomplete = await Arp.lookup("10.50.10.9", device: "en10", runner: runner)
        XCTAssertEqual(incomplete, .incomplete)
        let none = await Arp.lookup("10.50.10.8", device: "en10", runner: runner)
        XCTAssertEqual(none, .noEntry)
        let remote = await Arp.lookup("192.168.112.11", device: "en10", runner: runner)
        XCTAssertEqual(remote, .notLocal)

        runner.scripted["arp -an -i en10"] = CommandResult(exitCode: 0, stdout: table)
        let entries = await Arp.table(device: "en10", runner: runner)
        XCTAssertEqual(entries?.map(\.ip), ["10.50.10.254", "10.50.10.9"], "그 장치만, 자기 주소(permanent) 제외")
        XCTAssertTrue(Arp.privilegedTableScript(device: "en10").contains("sudo arp -an -i 'en10'"))
        XCTAssertTrue(Arp.clearCacheScript().contains("sudo arp -a -d"), "ARP 캐시만 — route flush 아님")
        XCTAssertFalse(Arp.clearCacheScript().contains("route"))
    }

    func testReportTexts() {
        var ping = PingTestResult(target: "10.50.10.254", device: "en10")
        ping.summary = PingSummary(averageMs: nil, lossPercent: 100, jitterMs: nil)
        ping.arp = .found(mac: "00:05:66:a0:b1:1b")
        XCTAssertTrue(ping.reportText.contains("ARP: 응답 있음 · 00:05:66:a0:b1:1b"), "ping 은 막혀도 장비는 있다")
        let table = ArpTableResult(device: "en10", entries: [ArpEntry(ip: "10.50.10.254", mac: "00:05:66:a0:b1:1b", device: "en10")])
        XCTAssertTrue(table.reportText.hasSuffix("10.50.10.254  00:05:66:a0:b1:1b"))
        // 답이 없는 주소(incomplete)는 결과·복사에서 빠진다
        let mixed = ArpTableResult(device: "en0", entries: [ArpEntry(ip: "192.168.0.1", mac: "58:86:94:aa:b1:17", device: "en0"),
                                                             ArpEntry(ip: "192.168.0.2", mac: nil, device: "en0")])
        XCTAssertEqual(mixed.found?.map(\.ip), ["192.168.0.1"])
        XCTAssertFalse(mixed.reportText.contains("192.168.0.2"))
    }

    /// 게이트웨이 확인: ping 되면 있음, 안 되면 ARP MAC 으로 (ping 막는 장비), 둘 다 없으면 없음
    func testGatewayPresent() async {
        let runner = FakeRunner()
        runner.scripted["ping -c 1 -t 1 -b en10 10.50.10.254"] = CommandResult(exitCode: 0)
        let byPing = await Arp.gatewayPresent("10.50.10.254", device: "en10", runner: runner)
        XCTAssertTrue(byPing)
        runner.scripted["ping -c 1 -t 1 -b en10 10.50.10.254"] = CommandResult(exitCode: 2)
        runner.scripted["arp -n -i en10 10.50.10.254"] = CommandResult(exitCode: 0, stdout: "? (10.50.10.254) at 0:5:66:a0:b1:1b on en10 ifscope [ethernet]\n")
        let byArp = await Arp.gatewayPresent("10.50.10.254", device: "en10", runner: runner)
        XCTAssertTrue(byArp)
        runner.scripted["arp -n -i en10 10.50.10.254"] = CommandResult(exitCode: 0, stdout: "? (10.50.10.254) at (incomplete) on en10 ifscope [ethernet]\n")
        let none = await Arp.gatewayPresent("10.50.10.254", device: "en10", runner: runner)
        XCTAssertFalse(none, "인터넷 선이면 내부망 게이트웨이가 없다")
    }

    /// 그 서비스 대역만: 10.50.10.17/24 → 10.50.10.0–255 (같은 NIC 의 172.30.1.x 이웃은 뺀다)
    func testInSubnet() {
        let entries = [ArpEntry(ip: "10.50.10.254", mac: nil, device: "en10"),
                       ArpEntry(ip: "172.30.1.165", mac: "d8:77:66:ae:b1:32", device: "en10"),
                       ArpEntry(ip: "172.30.1.254", mac: "00:05:66:a1:b1:ef", device: "en10"),
                       ArpEntry(ip: "10.50.11.1", mac: "00:00:00:00:00:01", device: "en10")]
        let intranet = Arp.inSubnet(entries, ip: "10.50.10.17", mask: "255.255.255.0")
        XCTAssertEqual(intranet?.entries.map(\.ip), ["10.50.10.254"])
        XCTAssertEqual(intranet?.subnet, "10.50.10.0/24")
        XCTAssertEqual(Arp.inSubnet(entries, ip: "10.50.10.17", mask: "255.255.0.0")?.entries.map(\.ip), ["10.50.10.254", "10.50.11.1"], "/16 이면 10.50.11.x 도")
        XCTAssertEqual(Arp.inSubnet(entries, ip: "172.30.1.149", mask: "255.255.255.0")?.entries.count, 2)
        XCTAssertNil(Arp.inSubnet(entries, ip: "x", mask: "255.255.255.0"))
    }

    /// 이웃 보기의 대역 확인: /24 는 자기 주소 빼고 253개, /24 까지만, 주소마다 ping 한 번을 병렬로 (장치에 묶음)
    func testSweep() async {
        let hosts = Arp.sweepTargets(ip: "192.168.0.241", mask: "255.255.255.0")
        XCTAssertEqual(hosts?.count, 253)
        XCTAssertEqual(hosts?.first, "192.168.0.1")
        XCTAssertEqual(hosts?.last, "192.168.0.254")
        XCTAssertFalse(hosts?.contains("192.168.0.241") == true)
        XCTAssertNil(Arp.sweepTargets(ip: "10.50.8.17", mask: "255.255.252.0"), "/24 보다 넓으면 표만 읽는다")
        XCTAssertNil(Arp.sweepTargets(ip: "10.50.10.17", mask: "255.255.0.0"))
        // 좁은 쪽 경계: /30 은 상대 하나, /31·/32 는 훑을 이웃이 없다
        XCTAssertEqual(Arp.sweepTargets(ip: "10.0.0.5", mask: "255.255.255.252"), ["10.0.0.6"])
        XCTAssertNil(Arp.sweepTargets(ip: "10.0.0.5", mask: "255.255.255.254"))
        XCTAssertNil(Arp.sweepTargets(ip: "10.0.0.5", mask: "255.255.255.255"))
        let runner = FakeRunner()
        let few = Arp.sweepTargets(ip: "10.0.0.5", mask: "255.255.255.248")!
        await Arp.sweep(few, device: "en10", runner: runner, concurrency: 2)
        let pings = runner.calls.filter { $0.executable == "ping" }
        XCTAssertEqual(pings.count, 5)
        XCTAssertTrue(pings.allSatisfy { $0.arguments.prefix(6) == ["-c", "1", "-t", "1", "-b", "en10"] })
        XCTAssertEqual(Set(pings.compactMap(\.arguments.last)), Set(few))
    }
}
