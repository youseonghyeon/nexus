// PowerWatch: 켜짐·꺼짐 알림 판정 (켜짐 2회·꺼짐 4회 연속 확인 · 처음 상태는 조용히 · 이 Mac 쪽 사정은 모름 ·
// 꺼짐은 같은 망의 다른 서버가 응답할 때만 · 깬 뒤 30초 쉼 · 5분 넘게 모르면 조용히 다시 기준).

import XCTest
@testable import ServersCore

final class PowerWatchTests: XCTestCase {
    private var watch = PowerWatch()
    private var now = Date(timeIntervalSince1970: 0)

    override func setUp() {
        watch = PowerWatch()
        now = Date(timeIntervalSince1970: 0)
    }

    /// 5초 간격 갱신을 흉내 낸다
    private func feed(_ states: [PowerState?], key: String = "win") -> [PowerEvent?] {
        states.map { state in
            now += 5
            return watch.observe(key, state, at: now)
        }
    }

    private func settle(_ state: PowerState, key: String = "win") {
        _ = feed(Array(repeating: state, count: PowerWatch.downConfirmations), key: key)
    }

    func testFirstStateIsSilent() {
        XCTAssertEqual(feed([.up, .up, .up]), [nil, nil, nil], "앱 시작 때 켜져 있던 건 알리지 않는다")
        setUp()
        XCTAssertEqual(feed([.down, .down, .down, .down, .down]), [nil, nil, nil, nil, nil])
    }

    func testBootNeedsTwoConfirmations() {
        settle(.down)
        XCTAssertEqual(feed([.up, .up]), [nil, .booted])
    }

    func testShutdownNeedsFourConfirmations() {
        settle(.up)
        XCTAssertEqual(feed([.down, .down, .down, .down]), [nil, nil, nil, .shutDown])
    }

    func testShortOutageIsIgnored() {
        settle(.up)
        XCTAssertEqual(feed([.down, .down, .down, .up, .up]), [nil, nil, nil, nil, nil], "15초 끊김(Tailscale 재시작 등)은 꺼짐이 아니다")
    }

    func testUnknownBreaksStreak() {
        settle(.up)
        XCTAssertEqual(feed([.down, .down, .down, nil, .down, .down, .down]), [nil, nil, nil, nil, nil, nil, nil],
                       "모름을 사이에 두고 이어 붙이지 않는다")
        XCTAssertEqual(feed([.down]), [.shutDown])
    }

    func testUnknownKeepsStableState() {
        settle(.up)
        XCTAssertEqual(feed([nil, nil, nil, .up, .up]), [nil, nil, nil, nil, nil], "모름 뒤 같은 상태면 알리지 않는다")
    }

    func testKeysAreIndependent() {
        settle(.up, key: "a")
        settle(.down, key: "b")
        XCTAssertEqual(feed([.up, .up], key: "b"), [nil, .booted])
        XCTAssertEqual(feed([.down, .down, .down, .down], key: "a"), [nil, nil, nil, .shutDown])
    }

    func testRetainAndForgetStartOverSilently() {
        settle(.up)
        watch.retain(keys: [])
        XCTAssertEqual(feed([.down, .down, .down, .down]), [nil, nil, nil, nil], "notify 를 껐다 켜면 처음부터 조용히")
        watch.forget("win")
        XCTAssertEqual(feed([.up, .up]), [nil, nil], "접속 정보가 바뀐 서버도 처음부터 조용히")
    }

    func testQuietAfterWake() {
        settle(.up)
        watch.noteWake(at: now)
        XCTAssertEqual(feed([.down, .down, .down, .down, .down]), [nil, nil, nil, nil, nil], "깬 뒤 30초 안의 실패는 모름")
        XCTAssertEqual(feed([.down, .down, .down, .down]), [nil, nil, nil, .shutDown], "30초 뒤부터 다시 센다")
    }

    func testLongUnknownGapRebaselinesSilently() {
        settle(.up)
        now += PowerWatch.staleAfter + 60   // 잠자기 등으로 6분 동안 확인 없음
        XCTAssertEqual(feed([.down, .down, .down, .down]), [nil, nil, nil, nil], "모르는 사이 꺼진 건 뒤늦게 알리지 않는다")
        XCTAssertEqual(feed([.up, .up]), [nil, .booted], "다시 잡은 기준에서의 전이는 알린다")
    }

    // MARK: 스냅샷 → 전원 상태

    private func server(_ key: String, _ network: ServerNetwork, ip: String = "192.0.2.1") -> Server {
        Server.sample(key: key, network: network, type: .linux, ip: ip, check: .tcp)
    }

    private lazy var servers = [server("win", .tailscale), server("nexus", .tailscale), server("was", .lan), server("web", .lan),
                                server("wg1", .direct, ip: "10.1.0.20"), server("wg2", .direct, ip: "10.1.0.21"), server("pub", .direct, ip: "203.0.113.5")]

    private func state(_ key: String, tailscale: TailscaleState = .running, peers: [String: PeerState] = [:],
                       _ remote: [String: RemoteState]) -> PowerState? {
        var s = StatusSnapshot()
        s.tailscale = tailscale
        s.peers = ["win": .online, "nexus": .online].merging(peers) { $1 }
        s.remote = remote
        return PowerWatch.state(of: servers.first { $0.key == key }!, in: s, among: servers)
    }

    func testUpIsUp() {
        XCTAssertEqual(state("win", ["win": .ok(latencyMs: 5)]), .up)
    }

    func testDownNeedsAWitnessOnTheSameNetwork() {
        let fail = RemoteState.fail(latencyMs: 3000)
        XCTAssertEqual(state("win", ["win": fail, "nexus": .ok(latencyMs: 5)]), .down)
        XCTAssertEqual(state("win", ["win": fail, "nexus": .needsAuth(url: nil)]), .down, "인증 필요도 nexus 까지 닿았다는 뜻")
        XCTAssertNil(state("win", ["win": fail, "nexus": fail]), "둘 다 실패 — 이 Mac 의 인터넷이 끊긴 것일 수 있다")
        XCTAssertNil(state("win", ["win": fail]), "기준 서버 확인 전")
        XCTAssertNil(state("win", ["win": fail, "was": .ok(latencyMs: 5)]), "다른 망의 서버는 증거가 아니다")
        let offline = RemoteState.skip(reason: "peer offline")
        XCTAssertEqual(state("win", peers: ["win": .offline], ["win": offline, "nexus": .ok(latencyMs: 5)]), .down)
        XCTAssertNil(state("win", peers: ["win": .offline], ["win": offline, "nexus": fail]))
        // 응답 없음(회색)도 꺼짐 후보 — 증거 규칙은 같다
        let off = RemoteState.off(latencyMs: 3000)
        XCTAssertEqual(state("win", ["win": off, "nexus": .ok(latencyMs: 5)]), .down)
        XCTAssertNil(state("win", ["win": off, "nexus": off]), "둘 다 응답 없음 — 이 Mac 쪽 문제일 수 있다")
    }

    func testLocalSideProblemsAreUnknown() {
        let nexusOK = RemoteState.ok(latencyMs: 5)
        XCTAssertNil(state("win", tailscale: .stopped("Stopped"), ["win": .skip(reason: "tailscale down"), "nexus": .skip(reason: "tailscale down")]),
                     "이 Mac 의 Tailscale 이 꺼짐")
        XCTAssertNil(state("win", peers: ["win": .missing], ["win": .skip(reason: "peer missing"), "nexus": nexusOK]))
        XCTAssertNil(state("win", ["nexus": nexusOK]), "확인 전")
        XCTAssertNil(state("win", ["win": .needsAuth(url: nil), "nexus": nexusOK]))
        XCTAssertNil(state("was", ["was": .skip(reason: "lan down"), "web": .skip(reason: "lan down")]), "내부망을 꺼 둔 상태")
        XCTAssertNil(state("was", ["was": .fail(latencyMs: 3000), "web": .fail(latencyMs: 3000)]), "어댑터 없음·링크 끊김이면 lan 서버가 다 실패")
        XCTAssertEqual(state("was", ["was": .fail(latencyMs: 3000), "web": .ok(latencyMs: 5)]), .down)
    }

    /// Direct 는 망 단계가 없어 서버마다 경로가 다르다 — 같은 /24 서버만 꺼짐의 근거로 (VPN 을 끄면 그 너머 서버만 실패한다)
    func testDirectWitnessOnlyInSameSubnet() {
        let fail = RemoteState.fail(latencyMs: 3000), ok = RemoteState.ok(latencyMs: 5)
        XCTAssertNil(state("wg1", ["wg1": fail, "pub": ok]), "공인 IP 서버가 응답해도 VPN 너머 서버가 꺼졌다고 볼 수 없다")
        XCTAssertNil(state("wg1", ["wg1": fail, "wg2": fail, "pub": ok]), "VPN 을 끈 상태")
        XCTAssertEqual(state("wg1", ["wg1": fail, "wg2": ok]), .down, "같은 대역의 다른 서버는 응답")
        XCTAssertNil(state("pub", ["pub": fail, "wg1": ok]))
        XCTAssertEqual(state("wg1", ["wg1": ok]), .up)
        XCTAssertTrue(PowerWatch.sameSubnet24("10.1.0.20", "10.1.0.200"))
        XCTAssertFalse(PowerWatch.sameSubnet24("10.1.0.20", "10.1.1.20"))
        XCTAssertFalse(PowerWatch.sameSubnet24("host.local", "host.local"), "IPv4 가 아니면 근거로 쓰지 않는다")
        XCTAssertFalse(PowerWatch.sameSubnet24("10.1.0.999", "10.1.0.1"))
    }
}
