// NetworkProbe: route·ifconfig·netstat·ping·curl·networkQuality 출력 파서.

import Foundation
import XCTest
@testable import ServersCore

final class NetworkProbeTests: XCTestCase {
    func testParseDefaultRoute() {
        let text = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.100.254
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        let route = NetworkProbe.parseRoute(text)
        XCTAssertEqual(route.interface, "en0"); XCTAssertEqual(route.gateway, "192.168.100.254")
        XCTAssertTrue(NetworkProbe.parseRoute("route: writing to routing socket: not in table").isEmpty)
    }

    func testParseLinkMedia() {
        let wifi = NetworkProbe.parseLinkMedia("\tmedia: autoselect\n\tstatus: active\n")
        XCTAssertEqual(wifi.media, "Autoselect"); XCTAssertEqual(wifi.status, "active")
        let wired = NetworkProbe.parseLinkMedia("\tmedia: autoselect (1000baseT <full-duplex>)\n\tstatus: active\n")
        XCTAssertEqual(wired.media, "1000baseT <full-duplex>")
        let off = NetworkProbe.parseLinkMedia("\tmedia: none\n\tstatus: inactive\n")
        XCTAssertNil(off.media); XCTAssertEqual(off.status, "inactive")
    }

    func testCountersAndRate() {
        let text = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        en0        1500  <Link#14>   26:85:c7:a8:b1:2a 22829155     0 33136576339  1499792     0  525674611     0
        en0        1500  fe80::147d: fe80:e::147d:1b30 22829155     - 33136576339  1499792     -  525674611     -
        """
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = NetworkProbe.parseCounters(text, at: t0)!
        XCTAssertEqual(first.rxBytes, 33_136_576_339); XCTAssertEqual(first.txBytes, 525_674_611)
        XCTAssertNil(NetworkProbe.parseCounters("Name Mtu Network Address\n", at: t0))
        // utun 은 MAC 이 없어 Address 칸이 비고 숫자가 한 칸씩 당겨진다 (2026-10-10 이 Mac 의 실제 출력)
        let utun = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        utun0      1380  <Link#18>                            0     0          0       31     0       2594     0
        utun0      1380  fe80::cfe9: fe80:12::cfe9:59f        0     -          0       31     -       2594     -
        """
        let tunnel = NetworkProbe.parseCounters(utun, at: t0)!
        XCTAssertEqual(tunnel.rxBytes, 0); XCTAssertEqual(tunnel.txBytes, 2594)
        let second = InterfaceCounters(rxBytes: first.rxBytes + 2_048_000, txBytes: first.txBytes + 512_000, at: t0.addingTimeInterval(2))
        let rate = TrafficRate.between(first, second)!
        XCTAssertEqual(rate.rxPerSecond, 1_024_000, accuracy: 1); XCTAssertEqual(rate.txPerSecond, 256_000, accuracy: 1)
        // 디스크·서버 Live 와 같은 10진 단위 (macOS Finder·활동 상태 보기와 같음) — 같은 "KB/s" 가 화면마다 다르지 않게
        XCTAssertEqual(TrafficRate.format(rate.rxPerSecond), "1.0 MB/s")
        XCTAssertEqual(TrafficRate.format(512), "512 B/s")
        XCTAssertEqual(TrafficRate.format(256_000), "256 KB/s")
        // 카운터가 줄었거나(재설정) 간격이 없으면 속도를 내지 않는다
        XCTAssertNil(TrafficRate.between(second, first))
        XCTAssertNil(TrafficRate.between(first, InterfaceCounters(rxBytes: first.rxBytes, txBytes: first.txBytes, at: t0)))
    }

    /// 화면을 떠나 있던 사이의 표본과는 잇지 않는다 (10분 평균이 지금 속도처럼 보이던 것)
    func testTrafficContinuesOnlyWithinTwoIntervals() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let previous = InterfaceCounters(rxBytes: 0, txBytes: 0, at: t0)
        XCTAssertTrue(TrafficRate.continues(from: previous, at: t0.addingTimeInterval(5), interval: 5), "평소 주기")
        XCTAssertTrue(TrafficRate.continues(from: previous, at: t0.addingTimeInterval(11), interval: 5), "한 번 늦은 갱신까지")
        XCTAssertFalse(TrafficRate.continues(from: previous, at: t0.addingTimeInterval(12), interval: 5))
        XCTAssertFalse(TrafficRate.continues(from: previous, at: t0.addingTimeInterval(600), interval: 5), "10분 떠나 있다 돌아옴")
        XCTAssertTrue(TrafficRate.continues(from: previous, at: t0.addingTimeInterval(55), interval: 30), "주기를 길게 잡은 설정")
    }

    func testParsePing() {
        let ok = NetworkProbe.parsePing("""
        --- 10.50.10.254 ping statistics ---
        3 packets transmitted, 3 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 0.042/1.244/2.046/0.902 ms
        """)
        XCTAssertEqual(ok.averageMs!, 1.244, accuracy: 0.001)
        XCTAssertEqual(ok.lossPercent, 0); XCTAssertEqual(ok.jitterMs!, 0.902, accuracy: 0.001)
        XCTAssertEqual(ok.text, "1.2 ms · Jitter 0.9 ms")
        let dead = NetworkProbe.parsePing("""
        --- 10.0.0.9 ping statistics ---
        3 packets transmitted, 0 packets received, 100.0% packet loss
        """)
        XCTAssertNil(dead.averageMs); XCTAssertEqual(dead.lossPercent, 100); XCTAssertEqual(dead.text, "응답 없음")
        let lossy = NetworkProbe.parsePing("""
        3 packets transmitted, 2 packets received, 33.3% packet loss
        round-trip min/avg/max/stddev = 1.0/2.0/3.0/0.5 ms
        """)
        XCTAssertEqual(lossy.lossPercent, 33.3, accuracy: 0.01)
        XCTAssertTrue(lossy.text.contains("손실 33%"), lossy.text)
        // 응답 1개: macOS ping 은 stddev 를 nan 으로 찍는다 → 지터는 nil, 텍스트에 "nan" 이 없어야 한다
        let single = NetworkProbe.parsePing("""
        3 packets transmitted, 1 packets received, 66.7% packet loss
        round-trip min/avg/max/stddev = 0.062/0.062/0.062/nan ms
        """)
        XCTAssertEqual(single.averageMs!, 0.062, accuracy: 0.001)
        XCTAssertNil(single.jitterMs)
        XCTAssertFalse(single.text.contains("nan"), single.text)
    }

    func testParseInternetProbe() {
        let all = NetworkProbe.parseProbe("204 0.010000\n204 0.020000\n204 0.030000\n204 0.040000\n204 0.050000\n", count: 5)
        XCTAssertEqual(all.averageMs!, 30, accuracy: 0.001); XCTAssertEqual(all.lossPercent, 0)
        XCTAssertEqual(all.jitterMs!, 14.142, accuracy: 0.01)
        // 204 가 아닌 응답(포털 가로채기)과 빠진 줄은 손실로 센다
        let partial = NetworkProbe.parseProbe("204 0.010000\n200 0.010000\n000 0.000000\n", count: 5)
        XCTAssertEqual(partial.averageMs!, 10, accuracy: 0.001)
        XCTAssertEqual(partial.lossPercent, 80)
        let none = NetworkProbe.parseProbe("000 0.000000\n", count: 5)
        XCTAssertNil(none.averageMs); XCTAssertEqual(none.lossPercent, 100)
    }

    func testParseSpeedTest() {
        // 2026-11-04 이 Mac en11 실측 (networkQuality -s -M 8 -I en11)
        let result = NetworkProbe.parseSpeedTest("""
        ==== SUMMARY ====
        Uplink capacity: 393.258 Mbps
        Downlink capacity: 441.779 Mbps
        Uplink Responsiveness: High (15.268 milliseconds | 3929 RPM)
        Downlink Responsiveness: High (34.159 milliseconds | 1756 RPM)
        Idle Latency: 6.577 milliseconds | 9122 RPM
        """)
        XCTAssertEqual(result.download, "441.779 Mbps")
        XCTAssertEqual(result.upload, "393.258 Mbps")
        XCTAssertEqual(result.responsiveness, "High (34.159 milliseconds | 1756 RPM)", "둘 중 RPM 이 낮은(나쁜) 쪽")
        XCTAssertTrue(result.text.hasPrefix("↓ 441.779 Mbps"), result.text)
        XCTAssertEqual(NetworkProbe.parseSpeedTest("Test failed").text, "측정 실패")
    }

    /// 순차 측정은 응답성이 방향별 두 줄 — 어느 쪽이 나쁘든 나쁜 쪽, 한쪽만 읽히면 그 값
    func testSpeedTestResponsivenessPicksWorse() {
        func responsiveness(up: String?, down: String?) -> String? {
            let lines = [up.map { "Uplink Responsiveness: \($0)" }, down.map { "Downlink Responsiveness: \($0)" }]
            return NetworkProbe.parseSpeedTest(lines.compactMap { $0 }.joined(separator: "\n")).responsiveness
        }
        let good = "High (15.268 milliseconds | 3929 RPM)"
        let bad = "Medium (90.164 milliseconds | 665 RPM)"
        XCTAssertEqual(responsiveness(up: bad, down: good), bad)
        XCTAssertEqual(responsiveness(up: good, down: bad), bad)
        XCTAssertEqual(responsiveness(up: good, down: nil), good)
        XCTAssertEqual(responsiveness(up: nil, down: good), good)
        XCTAssertNil(responsiveness(up: nil, down: nil))
        // RPM 을 못 읽는 줄은 비교에서 진다 (읽힌 값을 보여 준다)
        XCTAssertEqual(responsiveness(up: "Low", down: bad), bad)
        XCTAssertEqual(responsiveness(up: bad, down: "Low"), bad)
    }

    /// 2026-10-13: 기본 경로가 VPN(utun7)일 때 Wi-Fi 화면에 기본 경로 쪽 공인 IP 가 떴다 → Wi-Fi 화면은 장치를 묶어 묻는다
    func testPublicIPBindsDevice() async {
        let runner = FakeRunner()
        let base = "curl -4 -fsS --connect-timeout 2 --max-time 4"
        runner.scripted["\(base) https://api.ipify.org"] = CommandResult(exitCode: 0, stdout: "192.0.2.143\n")
        runner.scripted["\(base) --interface en0 https://api.ipify.org"] = CommandResult(exitCode: 0, stdout: "198.51.100.23\n")
        let viaRoute = await NetworkProbe.publicIP(runner: runner)
        let viaWiFi = await NetworkProbe.publicIP(device: "en0", runner: runner)
        XCTAssertEqual(viaRoute, "192.0.2.143")
        XCTAssertEqual(viaWiFi, "198.51.100.23")
        // 실패(장치 없음·응답 없음)·빈 값은 nil — 화면은 이전 값 유지 또는 "–"
        runner.scripted["\(base) --interface en5 https://api.ipify.org"] = CommandResult(exitCode: 45, stderr: "curl: (45) bind failed")
        let failed = await NetworkProbe.publicIP(device: "en5", runner: runner)
        XCTAssertNil(failed)
    }

    /// 서버 정보 네트워크 줄: Direct 서버가 실제로 나가는 장치 (VPN 이 경로를 가져가면 utun)
    func testRouteInterfaceToHost() async {
        let runner = FakeRunner()
        runner.scripted["route -n get 192.168.8.103"] = CommandResult(exitCode: 0, stdout: """
               route to: 192.168.8.103
            destination: 192.168.8.0
              interface: utun6
            """)
        runner.scripted["route -n get 10.9.9.9"] = CommandResult(exitCode: 1, stderr: "route: writing to routing socket: not in table")
        let routed = await NetworkProbe.routeInterface(to: "192.168.8.103", runner: runner)
        let missing = await NetworkProbe.routeInterface(to: "10.9.9.9", runner: runner)
        let flag = await NetworkProbe.routeInterface(to: "-x", runner: runner)
        XCTAssertEqual(routed, "utun6")
        XCTAssertNil(missing)
        XCTAssertNil(flag)
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("-x") }, "옵션처럼 보이는 값은 route 에 넘기지 않는다")
        // 이름·빈 값·IPv6 는 route 를 부르지 않는다 — 이름을 넘기면 route 가 DNS 를 물어 망에 나간다 (ip= 에 이름을 적은 서버)
        runner.scripted["route -n get nexus.tail1234.ts.net"] = CommandResult(exitCode: 0, stdout: "  interface: en0\n")
        let before = runner.calls.count
        for host in ["nexus.tail1234.ts.net", "", " ", "fe80::1", "192.168.8"] {
            let device = await NetworkProbe.routeInterface(to: host, runner: runner)
            XCTAssertNil(device, host)
        }
        XCTAssertEqual(runner.calls.count, before, "IPv4 주소가 아니면 명령을 돌리지 않는다")
    }

    /// 응답·속도도 장치로 묶는다. 장치 이름은 셸 스크립트에 들어가므로 영문·숫자만 받는다.
    func testProbeAndSpeedTestBindDevice() async {
        let runner = FakeRunner()
        _ = await NetworkProbe.internetProbe(device: "en0", runner: runner)
        _ = await NetworkProbe.internetProbe(runner: runner)
        _ = await NetworkProbe.speedTest(device: "en11", runner: runner)
        _ = await NetworkProbe.speedTest(runner: runner)
        let scripts = runner.calls.filter { $0.executable == "/bin/sh" }.map { $0.arguments.last ?? "" }
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts[0].contains("--max-time 2 --interface en0 -w"), scripts[0])
        XCTAssertFalse(scripts[1].contains("--interface"), "장치 없이 부르면 기본 경로")
        XCTAssertEqual(runner.calls.filter { $0.executable == "networkQuality" }.map(\.arguments), [["-s", "-M", "3", "-I", "en11"], ["-s", "-M", "3"]])
        // 게이트웨이 응답: 내부망 장치로만 (기본 경로로 새지 않게)
        _ = await NetworkProbe.ping("10.50.10.1", device: "en10", runner: runner)
        XCTAssertEqual(runner.calls.last?.arguments, ["-c", "3", "-i", "0.2", "-W", "1000", "-b", "en10", "10.50.10.1"])

        let before = runner.calls.count
        let bad = await NetworkProbe.internetProbe(device: "en0; rm -rf ~", runner: runner)
        XCTAssertEqual(bad.lossPercent, 100)
        let badIP = await NetworkProbe.publicIP(device: "", runner: runner)
        XCTAssertNil(badIP)
        let badSpeed = await NetworkProbe.speedTest(device: "en0 -x", runner: runner)
        XCTAssertNil(badSpeed)
        let badPing = await NetworkProbe.ping("10.50.10.1", device: "", runner: runner)
        XCTAssertEqual(badPing.lossPercent, 100)
        XCTAssertEqual(runner.calls.count, before, "이상한 장치 이름이면 명령을 아예 돌리지 않는다")
    }
}
