// TailscalePeers: 서버 추가 창의 피어 목록 (tailscale status --json → 이름·IPv4·OS·online).

import XCTest
@testable import ServersCore

final class TailscalePeersTests: XCTestCase {
    private let json = #"""
    {"BackendState":"Running",
     "Self":{"HostName":"this-mac","TailscaleIPs":["100.64.0.10"],"OS":"macOS","Online":true},
     "Peer":{
      "k1":{"HostName":"DESKTOP-AB12","DNSName":"desktop-ab12.tail.ts.net.","TailscaleIPs":["fd7a:115c::1","100.64.0.2"],"OS":"windows","Online":false},
      "k2":{"HostName":"nexus","DNSName":"nexus.tail.ts.net.","TailscaleIPs":["100.64.0.1"],"OS":"linux","Online":true},
      "k3":{"HostName":"","DNSName":"3dprinter.tail.ts.net.","TailscaleIPs":["100.64.0.3"],"OS":"linux","Online":true},
      "k4":{"HostName":"v6only","TailscaleIPs":["fd7a:115c::9"],"OS":"linux","Online":true}
     }}
    """#

    func testParseSortsOnlineFirstAndSkipsSelfAndIPv6Only() {
        let peers = TailscalePeers.parse(json)
        XCTAssertEqual(peers.map(\.name), ["3dprinter", "nexus", "DESKTOP-AB12"], "online 먼저 이름순, 이 Mac·IPv4 없는 피어는 뺀다")
        XCTAssertEqual(peers.map(\.ip), ["100.64.0.3", "100.64.0.1", "100.64.0.2"], "IPv6 가 앞에 있어도 IPv4 를 고른다")
        XCTAssertEqual(peers.last?.type, .windows)
        XCTAssertEqual(peers.first?.type, .linux)
        XCTAssertEqual(TailscalePeers.parse("not json"), [])
        XCTAssertEqual(TailscalePeers.parse(#"{"BackendState":"Stopped"}"#), [])
    }

    func testSuggestedKeyFitsConfigKeyRule() {
        func key(_ name: String) -> String { TailscalePeer(name: name, ip: "", os: "", online: true).suggestedKey }
        XCTAssertEqual(key("DESKTOP-AB12"), "desktop_ab12")
        XCTAssertEqual(key("3dprinter"), "s3dprinter")
        XCTAssertEqual(key("my--host..lan"), "my_host_lan")
        XCTAssertEqual(key("-edge-"), "edge")
        XCTAssertEqual(key("한글이름"), "", "영문이 없으면 비워 두고 사용자가 채운다")
        for name in ["DESKTOP-AB12", "3dprinter", "my--host..lan"] {
            XCTAssertNotNil(key(name).range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression), name)
        }
    }
}
