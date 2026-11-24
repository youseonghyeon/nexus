// 화면에서 옮긴 작은 판정 · 문구 (MonitorText.swift, 2026-11-24): VPN 색 · System 화면의 스왑 · 페이징 · 배터리 · 온도 줄 ·
// Disk 화면 부제 · 사이드바의 접은 그룹 · Ports 표의 복사 주소. 기댓값은 옮기기 전 뷰의 분기를 읽어 적은 것. 빈 상태를 꼭 넣는다.

import Foundation
@testable import ServersCore
import XCTest

final class MonitorTextTests: XCTestCase {
    // MARK: VPN

    private func vpn(_ id: String, _ state: SystemVPN.State) -> SystemVPN {
        SystemVPN(id: id, name: "Acme VPN \(id)", kind: "WireGuard", enabled: true, state: state)
    }

    func testVPNLevelTable() {
        let rows: [(SystemVPN.State, StatusLevel)] = [
            (.connected, .good), (.connecting, .warn), (.disconnecting, .warn),
            (.disconnected, .muted), (.invalid, .muted), (.other("Reasserting"), .muted),
        ]
        for (state, level) in rows { XCTAssertEqual(vpn("a", state).level, level, "\(state)") }
    }

    func testVPNOverallLevelTable() {
        XCTAssertEqual(SystemVPN.overallLevel([]), .muted)   // VPN 이 하나도 없다 (빈 상태)
        XCTAssertEqual(SystemVPN.overallLevel([vpn("a", .disconnected), vpn("b", .invalid)]), .muted)
        XCTAssertEqual(SystemVPN.overallLevel([vpn("a", .disconnected), vpn("b", .connecting)]), .warn)
        XCTAssertEqual(SystemVPN.overallLevel([vpn("a", .disconnecting)]), .warn)
        XCTAssertEqual(SystemVPN.overallLevel([vpn("a", .connecting), vpn("b", .connected)]), .good)   // 연결이 하나라도 있으면 초록
        XCTAssertEqual(SystemVPN.overallLevel([vpn("a", .other("Reasserting"))]), .muted)
    }

    // MARK: System 화면

    func testSwapText() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(SwapUsage.text(nil), "–")
        XCTAssertEqual(SwapUsage.text(SwapUsage(total: 0, used: 0, encrypted: true)), "사용 안 함")   // 스왑 파일이 없으면 암호화 표기도 없다
        XCTAssertEqual(SwapUsage.text(SwapUsage(total: 2 * gb, used: gb, encrypted: false)), "\(SystemFormat.bytes(gb)) / \(SystemFormat.bytes(2 * gb))")
        XCTAssertEqual(SwapUsage.text(SwapUsage(total: 2 * gb, used: 0, encrypted: true)), "\(SystemFormat.bytes(0)) / \(SystemFormat.bytes(2 * gb)) · 암호화")
    }

    func testPagingText() {
        XCTAssertEqual(PagingRates.text(nil), "측정 중…")
        let rates = PagingRates(pageins: 12.4, pageouts: 0, swapins: 3.5, swapouts: 0.4, compressions: 1500.6, decompressions: 7)
        // 순서: In · Out · Compress · Decompress · Swap In · Swap Out, /s 는 끝에 한 번, 소수는 반올림
        XCTAssertEqual(PagingRates.text(rates), "In 12 · Out 0 · Compress 1501 · Decompress 7 · Swap In 4 · Swap Out 0 /s")
    }

    func testBatteryHealthText() {
        XCTAssertEqual(BatteryHealth(maxCapacityPercent: 100, cycleCount: 184, designCycles: 1000).text, "최대 용량 100% · 충전 사이클 184 / 1000")
        XCTAssertEqual(BatteryHealth(maxCapacityPercent: 79, cycleCount: 900, designCycles: nil).text, "최대 용량 79% · 충전 사이클 900 · 교체 권장")
        XCTAssertEqual(BatteryHealth(maxCapacityPercent: 80, cycleCount: nil, designCycles: 1000).text, "최대 용량 80%")   // 사이클을 모르면 설계 값도 뺀다, 80 은 권장 아님
        XCTAssertEqual(BatteryHealth(maxCapacityPercent: nil, cycleCount: 12, designCycles: nil).text, "충전 사이클 12")
        XCTAssertEqual(BatteryHealth(maxCapacityPercent: nil, cycleCount: nil, designCycles: nil).text, "")   // 아무 값도 없다
    }

    func testTemperatureText() {
        let full = TemperatureSummary(cpuMax: 50, cpuAverage: 45, performanceMax: 48.4, efficiencyMax: 40.5, gpuMax: 44, sensors: 26)
        XCTAssertEqual(TemperatureSummary.text(nil, unavailable: false), "측정 중…")
        XCTAssertEqual(TemperatureSummary.text(nil, unavailable: true), "온도 센서를 읽지 못했습니다")
        XCTAssertEqual(TemperatureSummary.text(full, unavailable: true), "온도 센서를 읽지 못했습니다")   // 못 읽는 기기면 남은 값을 보지 않는다
        XCTAssertEqual(TemperatureSummary.text(full, unavailable: false), "성능 코어 48° · 효율 코어 41° · GPU 44° · 센서 26개")
        let intel = TemperatureSummary(cpuMax: 61, cpuAverage: 55, performanceMax: nil, efficiencyMax: nil, gpuMax: 58.6, sensors: 4)
        XCTAssertEqual(TemperatureSummary.text(intel, unavailable: false), "GPU 59° · 센서 4개")   // 코어 묶음이 없는 기기 (CPU 값은 이 줄에 쓰지 않는다)
        let none = TemperatureSummary(cpuMax: nil, cpuAverage: nil, performanceMax: nil, efficiencyMax: nil, gpuMax: nil, sensors: 0)
        XCTAssertEqual(TemperatureSummary.text(none, unavailable: false), "센서 0개")
    }

    // MARK: Disk 화면

    private func disk(name: String = "ACME SSD 0512", internal isInternal: Bool = true, solidState: Bool? = true, bus: String? = "Apple Fabric") -> PhysicalDisk {
        PhysicalDisk(id: "disk0", name: name, size: 500_000_000_000, isInternal: isInternal, solidState: solidState, bus: bus, smart: nil,
                     removable: false, lifeUsed: nil)
    }

    func testDiskKindTable() {
        // (내장, SSD 여부, 버스) → 종류
        let rows: [(Bool, Bool?, String?, String)] = [
            (true, true, "Apple Fabric", "내장 SSD"), (true, false, "SATA", "내장 HDD"), (true, nil, nil, "내장"),
            (false, true, "USB", "외장 SSD"), (false, false, "USB", "외장 HDD"), (false, nil, "USB", "외장"),
            (true, true, "Disk Image", "이미지 SSD"), (false, nil, "Disk Image", "이미지"),   // 이미지는 내장 · 외장보다 먼저
        ]
        for (isInternal, solid, bus, text) in rows {
            XCTAssertEqual(disk(internal: isInternal, solidState: solid, bus: bus).kindText, text, "\(isInternal) \(String(describing: solid)) \(String(describing: bus))")
        }
    }

    func testDiskSubtitle() {
        let size = DiskFormat.bytes(UInt64(500_000_000_000))
        XCTAssertEqual(PhysicalDisk.subtitle(boot: nil, rootContainer: nil), "이 Mac 의 디스크")
        XCTAssertEqual(PhysicalDisk.subtitle(boot: nil, rootContainer: "disk3"), "이 Mac 의 디스크")   // 시동 디스크를 모르면 컨테이너도 안 적는다
        XCTAssertEqual(PhysicalDisk.subtitle(boot: disk(), rootContainer: "disk3"), "ACME SSD 0512 · \(size) · 내장 SSD · Apple Fabric · disk0 → disk3")
        XCTAssertEqual(PhysicalDisk.subtitle(boot: disk(), rootContainer: nil), "ACME SSD 0512 · \(size) · 내장 SSD · Apple Fabric")
        XCTAssertEqual(PhysicalDisk.subtitle(boot: disk(internal: false, solidState: nil, bus: nil), rootContainer: nil), "ACME SSD 0512 · \(size) · 외장")
    }

    // MARK: 사이드바의 접은 그룹

    func testCollapsedGroups() {
        XCTAssertEqual(CollapsedGroups.names(""), [])
        XCTAssertEqual(CollapsedGroups.names("Acme\nLab"), ["Acme", "Lab"])
        XCTAssertFalse(CollapsedGroups.contains("", "Acme"))
        XCTAssertTrue(CollapsedGroups.contains("Acme\nLab", "Lab"))
        XCTAssertFalse(CollapsedGroups.contains("Acme Lab", "Acme"))   // 줄 단위로만 견준다 (부분 일치 아님)
        XCTAssertFalse(CollapsedGroups.contains("Acme", ""))

        // 접기 · 펴기를 차례로 (저장 글이 어떻게 바뀌는지)
        var stored = ""
        stored = CollapsedGroups.setting(stored, "Acme", expanded: false); XCTAssertEqual(stored, "Acme")
        stored = CollapsedGroups.setting(stored, "Lab", expanded: false); XCTAssertEqual(stored, "Acme\nLab")
        stored = CollapsedGroups.setting(stored, "Acme", expanded: false); XCTAssertEqual(stored, "Lab\nAcme")   // 다시 접으면 맨 뒤로 (겹쳐 쌓이지 않는다)
        stored = CollapsedGroups.setting(stored, "Home", expanded: true); XCTAssertEqual(stored, "Lab\nAcme")    // 접은 적 없는 그룹을 펴도 그대로
        stored = CollapsedGroups.setting(stored, "Lab", expanded: true); XCTAssertEqual(stored, "Acme")
        stored = CollapsedGroups.setting(stored, "Acme", expanded: true); XCTAssertEqual(stored, "")
        XCTAssertEqual(CollapsedGroups.setting("Acme\n\nLab\n", "Home", expanded: false), "Acme\nLab\nHome")   // 빈 줄은 버린다
    }

    // MARK: Ports 표의 복사 주소

    func testPortCopyAddress() {
        func item(_ addresses: [String], port: Int = 8080) -> PortItem {
            PortItem(port: port, udp: false, addresses: addresses, devices: [], label: nil, process: nil, tunnelAddress: nil)
        }
        XCTAssertEqual(item(["192.0.2.10"]).copyAddress, "192.0.2.10:8080")
        XCTAssertEqual(item(["127.0.0.1", "::1"]).copyAddress, "127.0.0.1:8080")   // 첫 주소(IPv4 먼저)
        XCTAssertEqual(item(["::1"]).copyAddress, "[::1]:8080")                    // IPv6 는 대괄호
        XCTAssertEqual(item(["2001:db8::10"], port: 443).copyAddress, "[2001:db8::10]:443")
        XCTAssertEqual(item(["*"]).copyAddress, "*:8080")
        XCTAssertEqual(item([]).copyAddress, "*:8080")                             // 주소를 모르면 모든 주소로
    }
}
