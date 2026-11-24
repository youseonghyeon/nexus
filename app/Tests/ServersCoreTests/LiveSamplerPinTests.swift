// Live 탭 표본기(LinuxLiveSampler · WindowsLiveSampler)의 결과를 통째로 고정한다 — 계산을 옮겨도 화면에 가는 값이 그대로인지 본다.
// 실제 출력 픽스처(linux-live · openwrt-live · windows-live) 두 표본의 결과 전체를 글로 적어 지문(SHA-256)으로 견주고,
// 리눅스와 Windows 가 서로 다르게 하는 것(보이는 장치 · 합계에 넣는 장치 · %CPU 식 · 메모리 단위)은 작은 견본으로 값까지 적는다.

import CryptoKit
import Foundation
import XCTest
@testable import ServersCore

final class LiveSamplerPinTests: XCTestCase {
    /// 결과 전체를 한 글로. 사전은 이름순, 디스크 합계만 소수 셋째 자리까지(사전을 도는 순서대로 더해 끝자리가 흔들릴 수 있다)
    private func dump(_ s: LiveSnapshot) -> String {
        func io(_ d: DiskIO) -> String { "\(d.read) \(d.write) \(d.readOps) \(d.writeOps)" }
        func flag(_ b: Bool?) -> String { b.map { "\($0)" } ?? "-" }
        func info(_ d: LiveDiskInfo) -> String { "\(flag(d.rotational)) \(d.size) \(d.model ?? "-") \(flag(d.healthy))" }
        let health = LiveHealth.judge(s)
        var lines = ["system \(s.system) model \(s.model ?? "-") cores \(s.cores) physical \(s.physicalCores.map(String.init) ?? "-") uptime \(s.uptime.map { "\($0)" } ?? "-")",
                     "cpu \(s.cpu.map { "\($0.total) \($0.user) \($0.system) \($0.iowait) \($0.steal) \($0.idle) \($0.cores)" } ?? "-")",
                     "memory \(s.memory.map { "\($0.total) \($0.used) \($0.shared) \($0.buffers) \($0.cache) \($0.free) \($0.available) \($0.swapTotal) \($0.swapUsed)" } ?? "-") \(s.pressure)",
                     "load \(s.load) processes \(s.processCount) running \(s.running) threads \(s.threads)",
                     "disk \(s.disk.map { String(format: "%.3f %.3f %.3f %.3f", $0.read, $0.write, $0.readOps, $0.writeOps) } ?? "-")",
                     "temperature \(s.temperatureMax.map { "\($0)" } ?? "-") \(s.temperatureAverage.map { "\($0)" } ?? "-")",
                     "frequency \(s.frequencyAverage.map { "\($0)" } ?? "-") \(s.frequencyMax.map { "\($0)" } ?? "-") throttle \(s.throttleEvents.map(String.init) ?? "-")",
                     "network \(s.networkTotal.map { "\($0.rx) \($0.tx)" } ?? "-")",
                     "health \(health.level) \(health.text)"]
        lines += s.perDisk.keys.sorted().map { "perDisk \($0) \(io(s.perDisk[$0]!))" }
        lines += s.diskInfo.keys.sorted().map { "diskInfo \($0) \(info(s.diskInfo[$0]!))" }
        lines += s.volumes.map { "volume \($0.device) \($0.fsType) \($0.size) \($0.used) \($0.available) \($0.mountPoint) \($0.percent)" }
        lines += s.raids.map { "raid \($0.name) \($0.level) \($0.active) \($0.members) \($0.failedMembers) \($0.progress ?? "-") \($0.degraded)" }
        lines += s.gpus.map { "gpu \($0.name) \($0.utilization ?? -1) \($0.memoryUsed ?? 0) \($0.memoryTotal ?? 0) \($0.temperature ?? -1) \($0.power ?? -1)" }
        lines += s.interfaces.map { "interface \($0.name) \($0.physical) \($0.state) \($0.speedMbps.map(String.init) ?? "-") \($0.rx) \($0.tx)" }
        lines += s.processes.map { "process \($0.pid) \($0.cpu) \($0.memory) [\($0.state)] \($0.threads) \($0.cpuTime) \($0.command)" }
        return lines.joined(separator: "\n")
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func check(_ snapshot: LiveSnapshot, lines: Int, _ expected: String, _ name: String, line: UInt = #line) {
        let text = dump(snapshot)
        XCTAssertEqual(text.split(separator: "\n").count, lines, name, line: line)
        XCTAssertEqual(digest(text), expected, "\(name) 의 결과가 달라졌다:\n\(text.prefix(3000))", line: line)
    }

    // MARK: 실제 출력

    func testLinuxSnapshotsFromRealOutput() throws {
        var sampler = LinuxLiveSampler()
        let t0 = Date(timeIntervalSince1970: 0)
        let a = sampler.step(try XCTUnwrap(LinuxRaw.parse(try fixtureText("linux-live-1"))), at: t0)
        let b = sampler.step(try XCTUnwrap(LinuxRaw.parse(try fixtureText("linux-live-2"))), at: t0.addingTimeInterval(1))
        check(a, lines: 19, "03e62fe430381c2f12b877632c8eb3678d5d309aac6976fb8e6a9e2859a87af8", "linux 첫 표본")
        check(b, lines: 22, "a0ed764143e59464877e0559a9c04e1797e2558fdc6d5be793ebf2a9c7d8357a", "linux 둘째 표본")
    }

    /// OpenWrt 는 리눅스 스크립트를 그대로 쓴다. 픽스처가 하나라 같은 출력을 두 번 넣는다 (서버 시간 차이 0 → Mac 시각 2초)
    func testOpenWrtSnapshotFromRealOutput() throws {
        let raw = try XCTUnwrap(LinuxRaw.parse(try fixtureText("openwrt-live")))
        var sampler = LinuxLiveSampler()
        let t0 = Date(timeIntervalSince1970: 0)
        check(sampler.step(raw, at: t0), lines: 28, "6e69c596c88e8ccf48a1c2211cde330a9c5aeb3c199a0b416e01ab4f5b92fd90", "openwrt 첫 표본")
        check(sampler.step(raw, at: t0.addingTimeInterval(2)), lines: 33, "1bc41acc635a9b9d3b186763ef2df73bbfe1eebf79a3244bfa98656a8e5819ea", "openwrt 둘째 표본")
    }

    func testWindowsSnapshotsFromRealOutput() throws {
        var sampler = WindowsLiveSampler()
        let a = sampler.step(try XCTUnwrap(WindowsRaw.parse(try fixtureText("windows-live-1"))), at: Date(timeIntervalSince1970: 0))
        let b = sampler.step(try XCTUnwrap(WindowsRaw.parse(try fixtureText("windows-live-2"))), at: Date(timeIntervalSince1970: 3))
        check(a, lines: 339, "dc0d67170d41b62b96165ddb39eb1476fd88009eb2705f7cf3286febc0fdea74", "windows 첫 표본")
        check(b, lines: 338, "1a83ce419220e1fdb683b239e3710b6bfe8c085d98688f9afd095f55295cf3c3", "windows 둘째 표본")
    }

    // MARK: 리눅스와 Windows 가 다르게 하는 것

    /// 리눅스: 보이는 장치(물리 + VPN·본딩)만 싣고 합계는 물리만. 직전 표본에 없던 장치는 건너뛰고, 줄어든 카운터는 0, 같은 이름은 앞의 것과 뺀다
    func testLinuxInterfaceRules() throws {
        func out(_ uptime: String, _ net: [String]) -> String { "@INFO\n@UP\n\(uptime) 1.0\n@NET\n\(net.joined(separator: "\n"))\n@END\n" }
        var sampler = LinuxLiveSampler()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = sampler.step(try XCTUnwrap(LinuxRaw.parse(out("10.0", ["eth0 1 up 1000 1000 1000", "eth0 1 up 1000 7 7", "wg0 0 unknown - 100 100", "br0 0 up - 10 10",
                                                                    "tunl0 1 up - 10 10", "eth1 1 up 2500 500 500"]))), at: t0)
        let s = sampler.step(try XCTUnwrap(LinuxRaw.parse(out("14.0", ["eth0 1 up 1000 5000 3000", "wg0 0 unknown - 900 500", "br0 0 up - 90 90", "tunl0 1 up - 90 90",
                                                                       "eth1 1 up 2500 100 900", "eth2 1 up 100 9 9"]))), at: t0.addingTimeInterval(1))
        XCTAssertEqual(s.interfaces, [LiveInterfaceRate(name: "eth0", physical: true, state: "up", speedMbps: 1000, rx: 1000, tx: 500),
                                      LiveInterfaceRate(name: "wg0", physical: false, state: "unknown", speedMbps: nil, rx: 200, tx: 100),
                                      LiveInterfaceRate(name: "eth1", physical: true, state: "up", speedMbps: 2500, rx: 0, tx: 100)],
                       "br0(가상) · tunl0(물리라고 와도) 은 숨김, eth2 는 다음 표본부터, eth0 은 앞 줄과, eth1 rx 는 줄었으니 0 — 서버 시간 4초")
        XCTAssertEqual(s.networkTotal, LiveTraffic(rx: 1000, tx: 600), "합계는 물리만 (wg0 제외)")
        // 시간 차이가 0 이면 속도를 내지 않는다
        var still = LinuxLiveSampler()
        _ = still.step(try XCTUnwrap(LinuxRaw.parse(out("10.0", ["eth0 1 up 1000 1 1"]))), at: t0)
        let none = still.step(try XCTUnwrap(LinuxRaw.parse(out("10.0", ["eth0 1 up 1000 2 2"]))), at: t0)
        XCTAssertTrue(none.interfaces.isEmpty)
        XCTAssertNil(none.networkTotal)
    }

    /// Windows: 온 어댑터를 전부 싣고 전부 더한다 (이름이 tunl 로 시작해도 · 물리 표시가 없어도)
    func testWindowsInterfaceRules() {
        func raw(_ stamp: UInt64, _ interfaces: [LiveInterface]) -> WindowsRaw {
            var r = WindowsRaw()
            r.networkStamp = stamp
            r.interfaces = interfaces
            return r
        }
        func adapter(_ name: String, _ rx: UInt64, _ tx: UInt64, physical: Bool = true) -> LiveInterface {
            LiveInterface(name: name, physical: physical, state: "up", speedMbps: nil, rxBytes: rx, txBytes: tx)
        }
        var sampler = WindowsLiveSampler()
        _ = sampler.step(raw(10_000_000, [adapter("Intel", 1000, 1000), adapter("Intel", 7, 7), adapter("tunl adapter", 100, 100),
                                          adapter("vEthernet", 10, 10, physical: false), adapter("Realtek", 500, 500)]), at: Date())
        let s = sampler.step(raw(50_000_000, [adapter("Intel", 5000, 3000), adapter("tunl adapter", 900, 500), adapter("vEthernet", 90, 50, physical: false),
                                              adapter("Realtek", 100, 900), adapter("New", 9, 9)]), at: Date())
        XCTAssertEqual(s.interfaces.map(\.name), ["Intel", "tunl adapter", "vEthernet", "Realtek"])
        XCTAssertEqual(s.interfaces.map(\.rx), [1000, 200, 20, 0])
        XCTAssertEqual(s.interfaces.map(\.tx), [500, 100, 10, 100])
        XCTAssertEqual(s.networkTotal, LiveTraffic(rx: 1220, tx: 710), "전부 더한다")
        // 시각이 뒤로 가면 속도를 내지 않는다
        let back = sampler.step(raw(20_000_000, [adapter("Intel", 9000, 9000)]), at: Date())
        XCTAssertTrue(back.interfaces.isEmpty)
        XCTAssertNil(back.networkTotal)
    }

    /// 프로세스 메모리: 리눅스는 RSS 페이지 × PAGESIZE, Windows 는 받은 바이트 그대로. 줄은 CPU → 메모리 → pid(작은 것 먼저) 순
    func testProcessMemoryUnitsAndOrder() throws {
        let stat = "@STAT\ncpu 0 0 0 1000 0 0 0 0\ncpu0 0 0 0 1000 0 0 0 0\n"
        let linux = try XCTUnwrap(LinuxRaw.parse("@INFO\n250\n16384\n\(stat)@PROC\n7\tS\t500\t3\t10\t1\ta\n5\tS\t0\t1\t10\t1\tb\n9\tR\t0\t1\t20\t1\tc\n@END\n"))
        var sampler = LinuxLiveSampler()
        let rows = sampler.step(linux, at: Date()).processes
        XCTAssertEqual(rows.map(\.pid), [9, 5, 7], "CPU 가 같으면 메모리 큰 것, 그것도 같으면 pid 작은 것")
        XCTAssertEqual(rows.map(\.memory), [20 * 16384, 10 * 16384, 10 * 16384])
        XCTAssertEqual(rows.last?.cpuTime, 2, "ticks / CLK_TCK(250)")
        XCTAssertEqual(rows.last?.threads, 3)

        let windows = try XCTUnwrap(WindowsRaw.parse("@PROC\nT\t10000000\n7\t30000000\t4096\t8192\t3\t1\ta#2\n5\t0\t4096\t8192\t1\t1\tb\n9\t0\t9000\t9999\t1\t1\tc\n@END\n"))
        var other = WindowsLiveSampler()
        let winRows = other.step(windows, at: Date()).processes
        XCTAssertEqual(winRows.map(\.pid), [9, 5, 7])
        XCTAssertEqual(winRows.map(\.memory), [9000, 4096, 4096], "전용 작업 집합 바이트 그대로")
        XCTAssertEqual(winRows.last?.cpuTime, 3, "100ns 누적 / 10^7")
        XCTAssertEqual(winRows.last?.command, "a")
    }
}
