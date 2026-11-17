// 인터넷 서비스 판정 (scutil PrimaryService): 같은 장치(en10)에 서비스가 둘이어도 인터넷 서비스 하나만 "끄면 끊김".
// scutil 출력은 2026-10-15 이 Mac 의 모양 (서비스 ID·이름은 예시).

import Foundation
@testable import ServersCore
import XCTest

/// scutil 입력(stdin)에 따라 답하는 가짜. 나머지는 실패.
private final class ScutilRunner: CommandRunner, @unchecked Sendable {
    var replies: [String: CommandResult]
    init(_ replies: [String: CommandResult]) { self.replies = replies }
    func hasExecutable(_ name: String) -> Bool { true }
    func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
        guard executable == "scutil" else { return CommandResult(exitCode: 1) }
        return replies[stdin ?? arguments.joined(separator: " ")] ?? CommandResult(exitCode: 1)
    }
    func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval,
             abortOnLine: (@Sendable (String) -> Bool)?) async -> CommandResult {
        await run(executable, arguments, stdin: stdin, environment: environment, timeout: timeout)
    }
}

final class PrimaryServiceTests: XCTestCase {
    private let globalQuery = "show State:/Network/Global/IPv4\nquit\n"
    private func setupQuery(_ id: String) -> String { "show Setup:/Network/Service/\(id)\nquit\n" }
    private let ethernetID = "8A0E3C1B-1111-4C2D-9E10-ABCDEF012345"

    private func global(_ id: String?) -> CommandResult {
        CommandResult(exitCode: 0, stdout: "<dictionary> {\n  PrimaryInterface : en10\n" + (id.map { "  PrimaryService : \($0)\n" } ?? "") + "  Router : 172.30.1.254\n}\n")
    }

    func testWiredPrimaryService() async {
        let runner = ScutilRunner([globalQuery: global(ethernetID),
                                   setupQuery(ethernetID): CommandResult(exitCode: 0, stdout: "<dictionary> {\n  UserDefinedName : iptime Hub NIC\n}\n")])
        let primary = await NetworkProbe.primaryService(runner: runner)
        XCTAssertEqual(primary, .service("iptime Hub NIC"))
        // 같은 en10 의 내부망 서비스는 인터넷 서비스가 아니다 — 장치가 같아도(deviceMatch) 막지 않는다
        XCTAssertFalse(PrimaryService.carriesInternet("acme ethernet", primary: primary, services: services, deviceMatch: true))
        XCTAssertTrue(PrimaryService.carriesInternet("iptime Hub NIC", primary: primary, services: services, deviceMatch: true))
    }

    /// 서비스 순서대로: en10 에 인터넷(DHCP)과 내부망(수동) 둘, Wi-Fi
    private let services = [
        LanServiceEntry(name: "iptime Hub NIC", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: true),
        LanServiceEntry(name: "Wi-Fi", hardwarePort: "Wi-Fi", device: "en0", enabled: true),
        LanServiceEntry(name: "acme ethernet", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: true),
    ]
    private let nwi = "Network information\n\nIPv4 network interface information\n   utun7 : flags      : 0x7 (IPv4,IPv6,DNS)\n\nNetwork interfaces: utun7 en10 en0\n"

    /// VPN(WireGuard) 이 기본 경로: 그 아래 회선(en10)에서 순서가 가장 앞인 켜진 서비스가 인터넷 — 끄면 VPN 까지 끊긴다.
    /// 같은 en10 의 내부망 서비스는 아니다 (2026-10-15 리뷰: .other 를 "유선 전부 아님"으로 봐서 iptime Hub NIC 를 확인 없이 끌 수 있었다)
    func testVPNPrimaryUsesUnderlyingDevice() async {
        let vpnID = "2BD9E60F-C64C-4025-BD83-78F77C54008D"
        let runner = ScutilRunner([globalQuery: global(vpnID), setupQuery(vpnID): CommandResult(exitCode: 0, stdout: "  No such key\n"),
                                   "--nwi": CommandResult(exitCode: 0, stdout: nwi)])
        let primary = await NetworkProbe.primaryService(runner: runner)
        XCTAssertEqual(primary, .other(underlying: "en10"))
        XCTAssertTrue(PrimaryService.carriesInternet("iptime Hub NIC", primary: primary, services: services, deviceMatch: false))
        XCTAssertFalse(PrimaryService.carriesInternet("acme ethernet", primary: primary, services: services, deviceMatch: true))
        XCTAssertFalse(PrimaryService.carriesInternet("Wi-Fi", primary: primary, services: services, deviceMatch: false))
        // 앞 서비스가 꺼져 있으면 그다음 켜진 서비스
        var off = services; off[0] = LanServiceEntry(name: "iptime Hub NIC", hardwarePort: nil, device: "en10", enabled: false)
        XCTAssertTrue(PrimaryService.carriesInternet("acme ethernet", primary: primary, services: off, deviceMatch: false))
        // --nwi 를 못 읽으면 nil (장치 기준)
        let noNwi = await NetworkProbe.primaryService(runner: ScutilRunner([globalQuery: global(vpnID), setupQuery(vpnID): CommandResult(exitCode: 0, stdout: "  No such key\n")]))
        XCTAssertNil(noNwi)
        XCTAssertNil(NetworkProbe.underlyingDevice("Network interfaces: utun7 ipsec0"))
    }

    /// 기본 경로가 없으면 .other, 못 읽으면 nil → 예전 장치 기준으로 조심스럽게
    func testNoRouteAndReadFailure() async {
        let none = await NetworkProbe.primaryService(runner: ScutilRunner([globalQuery: global(nil)]))
        XCTAssertEqual(none, .other(underlying: nil))
        let failed = await NetworkProbe.primaryService(runner: ScutilRunner([:]))
        XCTAssertNil(failed)
        XCTAssertFalse(PrimaryService.carriesInternet("iptime Hub NIC", primary: none, services: services, deviceMatch: true), "기본 경로 없음")
        XCTAssertTrue(PrimaryService.carriesInternet("acme ethernet", primary: nil, services: services, deviceMatch: true))
        XCTAssertFalse(PrimaryService.carriesInternet("acme ethernet", primary: nil, services: services, deviceMatch: false))
        // ID 꼴이 아니면 두 번째 질의를 만들지 않는다
        let odd = await NetworkProbe.primaryService(runner: ScutilRunner([globalQuery: global("x\nshow Setup:")]))
        XCTAssertNil(odd)
    }
}
