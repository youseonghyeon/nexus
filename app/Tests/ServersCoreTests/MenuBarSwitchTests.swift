// 메뉴바 스위치 행: 상태 → 켜짐·아래 줄·누를 수 있는가 · 누르면 메뉴를 닫는가(인증·확인 창).

import XCTest
@testable import ServersCore

final class MenuBarSwitchTests: XCTestCase {
    func testWiFi() {
        XCTAssertEqual(MenuBarSwitch.wifi(powerOn: true, associated: true).subtitle, "연결됨")
        XCTAssertEqual(MenuBarSwitch.wifi(powerOn: true, associated: false).subtitle, "연결 안 됨")
        let off = MenuBarSwitch.wifi(powerOn: false, associated: false)
        XCTAssertFalse(off.isOn)
        XCTAssertEqual(off.subtitle, "꺼짐")
        XCTAssertTrue(off.isEnabled)
        let missing = MenuBarSwitch.wifi(powerOn: nil, associated: false)
        XCTAssertFalse(missing.isEnabled)
        XCTAssertEqual(missing.subtitle, "없음")
    }

    func testTailscaleStates() {
        let on = MenuBarSwitch.tailscale(.running, busy: false, changing: false)
        XCTAssertTrue(on.isOn)
        XCTAssertEqual(on.subtitle, "연결됨")
        XCTAssertTrue(on.isEnabled)
        let off = MenuBarSwitch.tailscale(.stopped("Stopped"), busy: false, changing: false)
        XCTAssertFalse(off.isOn)
        XCTAssertEqual(off.subtitle, "꺼짐")   // 상태 단어만 — "(Stopped)" 같은 상세는 넣지 않는다
        XCTAssertFalse(MenuBarSwitch.tailscale(.missing, busy: false, changing: false).isEnabled)
        XCTAssertTrue(MenuBarSwitch.tailscale(.unknown, busy: false, changing: false).isEnabled)
    }

    func testLanWithoutConfigHasNoRow() {
        XCTAssertNil(MenuBarSwitch.lan(.none, busy: false, changing: false))
        XCTAssertEqual(MenuBarSwitch.lan(.up, busy: false, changing: false)?.subtitle, "켜짐")
        XCTAssertEqual(MenuBarSwitch.lan(.down, busy: false, changing: false)?.isOn, false)
        XCTAssertEqual(MenuBarSwitch.lan(.missing, busy: false, changing: false)?.isEnabled, false)
    }

    /// 다른 켜기·끄기가 도는 동안엔 어느 스위치도 못 누르고, 바꾸는 행만 아래 줄이 바뀐다
    func testBusyDisablesAndChangingShowsText() {
        let busy = MenuBarSwitch.lan(.down, busy: true, changing: false)!
        XCTAssertFalse(busy.isEnabled)
        XCTAssertEqual(busy.subtitle, "꺼짐")
        let changing = MenuBarSwitch.lan(.down, busy: true, changing: true)!
        XCTAssertFalse(changing.isEnabled)
        XCTAssertEqual(changing.subtitle, MenuBarSwitch.changingText)
        // 없는 망은 바꾸는 중이어도 "없음" 그대로
        XCTAssertEqual(MenuBarSwitch.tailscale(.missing, busy: true, changing: true).subtitle, "없음")
    }

    /// 인증(Intranet)과 본창 확인(Tailscale 끄기)은 메뉴를 닫고, 나머지는 열어 둔 채 스위치만 바뀐다
    func testWhichTogglesCloseTheMenu() {
        XCTAssertTrue(MenuBarSwitch.lan(.down, busy: false, changing: false)!.closesMenuOnToggle)
        XCTAssertTrue(MenuBarSwitch.lan(.up, busy: false, changing: false)!.closesMenuOnToggle)

        let tailscaleOn = MenuBarSwitch.tailscale(.running, busy: false, changing: false)
        XCTAssertTrue(tailscaleOn.closesMenuOnToggle)
        XCTAssertTrue(tailscaleOn.confirmsInWindow)
        let tailscaleOff = MenuBarSwitch.tailscale(.stopped("Stopped"), busy: false, changing: false)
        XCTAssertFalse(tailscaleOff.closesMenuOnToggle)
        XCTAssertFalse(tailscaleOff.confirmsInWindow)

        XCTAssertFalse(MenuBarSwitch.wifi(powerOn: true, associated: true).closesMenuOnToggle)
    }

    /// Tailscale 행은 tailscale 서버가 없어도 tailscale 이 설치돼 있으면 보이고, 둘 다 없을 때만 숨는다.
    /// 앱을 켠 직후 확인 전엔 숨긴다 — 확인해서 있을 때만 나타난다 (2026-11-01)
    func testTailscaleRowWithoutTailscaleServers() throws {
        let direct = try ServerConfigParser.parse("[a]\ngroup=g\ntype=linux\nport=22\nip=1.2.3.4\nuser=u\nnetwork=direct\n")
        XCTAssertFalse(direct.showsTailscale(StatusSnapshot().tailscale, checked: StatusSnapshot().tailscaleChecked), "켠 직후(확인 전)엔 숨김")
        XCTAssertTrue(direct.showsTailscale(.stopped("Stopped"), checked: true))
        XCTAssertTrue(direct.showsTailscale(.unknown, checked: true), "확인 뒤 .unknown 은 명령이 있다는 뜻")
        XCTAssertFalse(direct.showsTailscale(.missing, checked: true))
        let tailscale = try ServerConfigParser.parse("[a]\ngroup=g\ntype=linux\nport=22\nip=100.1.1.1\nuser=u\nnetwork=tailscale\n")
        XCTAssertTrue(tailscale.showsTailscale(.missing, checked: true))   // 서버가 쓰면 명령이 없어도 행은 남는다(비활성)
        XCTAssertTrue(tailscale.showsTailscale(.unknown, checked: false))
    }

    /// 확인을 한 번 돌면 checked — 명령이 없어도(.missing) 확인은 끝난 것
    func testCollectLocalMarksTailscaleChecked() async throws {
        let config = try ServerConfigParser.parse("[a]\ngroup=g\ntype=linux\nport=22\nip=1.2.3.4\nuser=u\nnetwork=direct\n")
        let runner = FakeRunner()
        var snapshot = StatusSnapshot()
        await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).collectLocal(into: &snapshot)
        XCTAssertTrue(snapshot.tailscaleChecked)
    }
}
