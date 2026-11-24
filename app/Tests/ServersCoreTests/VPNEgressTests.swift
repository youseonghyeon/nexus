import Foundation
@testable import ServersCore
import XCTest

final class VPNEgressTests: XCTestCase {
    private let wireGuardAppex = "/Applications/WireGuard.app/Contents/PlugIns/WireGuardNetworkExtension.appex"
    private var ps: String {
        [
            "    1 /sbin/launchd",
            "  412 /System/Library/PrivateFrameworks/Foo.framework/XPCServices/Other.appex/Contents/MacOS/Other",
            "  733 /Library/SystemExtensions/5E1A/com.example.vpn.extension.systemextension/Contents/MacOS/com.example.vpn.extension",
            " 1260 \(wireGuardAppex)/Contents/MacOS/WireGuardNetworkExtension",
            " 1300 /Applications/My VPN.app/Contents/PlugIns/Tunnel Ext.appex/Contents/MacOS/Tunnel Ext",
        ].joined(separator: "\n")
    }
    private func appexIDs(_ path: String) -> String? {
        [wireGuardAppex: "com.wireguard.macos.network-extension",
         "/System/Library/PrivateFrameworks/Foo.framework/XPCServices/Other.appex": "com.apple.other",
         "/Applications/My VPN.app/Contents/PlugIns/Tunnel Ext.appex": "com.my.vpn.tunnel"][path]
    }

    /// 앱 확장은 .appex 번들 ID 로, 시스템 확장은 경로의 번들 ID 로, 경로에 빈칸이 있어도 찾는다. 없으면 nil
    func testProviderPIDFromPS() {
        XCTAssertEqual(VPNEgresses.providerPID(ps: ps, bundleID: "com.wireguard.macos.network-extension", appexBundleID: appexIDs), 1260)
        XCTAssertEqual(VPNEgresses.providerPID(ps: ps, bundleID: "com.example.vpn.extension", appexBundleID: appexIDs), 733)
        XCTAssertEqual(VPNEgresses.providerPID(ps: ps, bundleID: "com.my.vpn.tunnel", appexBundleID: appexIDs), 1300)
        XCTAssertNil(VPNEgresses.providerPID(ps: ps, bundleID: "com.gone.vpn", appexBundleID: appexIDs))
        XCTAssertNil(VPNEgresses.providerPID(ps: "", bundleID: "com.wireguard.macos.network-extension", appexBundleID: appexIDs))
    }

    /// 이 Mac 실제 출력: udp4 소켓이 en11(Wired), udp6 은 장치 없음, tcp 는 머리줄만 → en11 (Ethernet) 하나
    func testRealNettopWireGuard() throws {
        let text = try fixtureText("nettop-wireguard-udp") + "\n" + fixtureText("nettop-wireguard-tcp")
        let egress = VPNEgresses.parseNettop(text, excluding: "utun6")
        XCTAssertEqual(egress.map(\.interface), ["en11"])
        XCTAssertEqual(egress.first?.type, "Ethernet")
        XCTAssertEqual(egress.first?.bytes, 790084512 + 31925308)
    }

    /// tcp 출력은 type 칸이 없다 — 칸은 머리줄마다 다시 읽는다. 같은 장치는 합치고 많이 쓴 순, 터널 자신·lo·합계 줄은 뺀다
    func testNettopMergesAndSkips() {
        let text = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        10:00:00.0,MyVPN.1300,,,999,999,,,,,,,,,,,,,,,
        10:00:00.0,tcp4 192.168.8.104:50000<->203.0.113.9:443,en0,Established,100,50,0,0,0,1 ms,0,0,BE,-,cubic,-,-,-,-,so,
        10:00:00.0,tcp4 10.1.0.2:50001<->10.1.0.1:53,utun6,Established,9000,9000,0,0,0,1 ms,0,0,BE,-,cubic,-,-,-,-,so,
        10:00:00.0,tcp4 127.0.0.1:50002<->127.0.0.1:9000,lo0,Established,9000,9000,0,0,0,1 ms,0,0,BE,-,cubic,-,-,-,-,so,
        time,,interface,type,bytes_in,bytes_out,rcvsize,tc_class,arch,
        10:00:00.0,udp4 *:4500<->*:*,en11,Wired,1000,1000,0,BE,so,
        10:00:00.0,udp4 *:4501<->*:*,en0,WiFi,10,10,0,BE,so,
        """
        let egress = VPNEgresses.parseNettop(text, excluding: "utun6")
        XCTAssertEqual(egress.map(\.interface), ["en11", "en0"])
        XCTAssertEqual(egress.map(\.bytes), [2000, 170])
        XCTAssertEqual(egress.map(\.type), ["Ethernet", "Wi-Fi"])   // tcp 로 먼저 본 en0 도 udp 의 type 으로 채운다
        XCTAssertEqual(VPNEgresses.parseNettop("", excluding: nil), [])
    }

    /// route get -ifscope 출력의 gateway. 없으면 nil
    func testParseGateway() {
        let text = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.8.1
          interface: en11
        """
        XCTAssertEqual(VPNEgresses.parseGateway(text), "192.168.8.1")
        XCTAssertNil(VPNEgresses.parseGateway("route: writing to routing socket: not in table\n"))
    }

    func testText() {
        XCTAssertEqual(VPNEgress(interface: "en11", type: "Ethernet", gateway: "192.168.8.1").text, "en11 (Ethernet) · 192.168.8.1")
        XCTAssertEqual(VPNEgress(interface: "en5").text, "en5")
    }

    /// 전체 흐름: ps → nettop(udp·tcp) → route. 확장 프로세스가 없거나 ps 가 실패하면 nettop 을 부르지 않고 빈 목록
    func testFetch() async throws {
        let udp = try fixtureText("nettop-wireguard-udp"), tcp = try fixtureText("nettop-wireguard-tcp"), psText = ps
        final class Runner: CommandRunner, @unchecked Sendable {
            let outputs: [String: CommandResult]
            var calls: [String] = []
            init(_ outputs: [String: CommandResult]) { self.outputs = outputs }
            func hasExecutable(_ name: String) -> Bool { true }
            func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
                let key = ([executable] + arguments).joined(separator: " ")
                calls.append(key)
                return outputs[key] ?? CommandResult(exitCode: 1)
            }
        }
        let ok = Runner([
            "ps -axo pid=,comm=": CommandResult(exitCode: 0, stdout: psText),
            "nettop -L 1 -n -m udp -p 1260": CommandResult(exitCode: 0, stdout: udp),
            "nettop -L 1 -n -m tcp -p 1260": CommandResult(exitCode: 0, stdout: tcp),
            "route -n get -ifscope en11 default": CommandResult(exitCode: 0, stdout: "    gateway: 192.168.8.1\n  interface: en11\n"),
        ])
        let egress = await VPNEgresses.fetch(providerBundleID: "com.wireguard.macos.network-extension", tunnel: "utun6", runner: ok, appexBundleID: appexIDs)
        XCTAssertEqual(egress.map(\.text), ["en11 (Ethernet) · 192.168.8.1"])

        let missing = Runner(["ps -axo pid=,comm=": CommandResult(exitCode: 0, stdout: psText)])
        let none = await VPNEgresses.fetch(providerBundleID: "com.gone.vpn", tunnel: "utun6", runner: missing, appexBundleID: appexIDs)
        XCTAssertEqual(none, [])
        XCTAssertFalse(missing.calls.contains { $0.hasPrefix("nettop") })

        let psFailed = await VPNEgresses.fetch(providerBundleID: "com.wireguard.macos.network-extension", tunnel: "utun6", runner: Runner([:]), appexBundleID: appexIDs)
        XCTAssertEqual(psFailed, [])
    }
}
