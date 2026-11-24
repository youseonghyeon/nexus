// ServerIcon: 서버 종류 → 사이드바 아이콘, TunnelIcon: 터널 종류 → 사이드바 아이콘 (SF Symbols 이름).

import XCTest
@testable import ServersCore

final class ServerIconTests: XCTestCase {
    func testSymbolByType() {
        XCTAssertEqual(ServerIcon.symbol(for: .linux), "server.rack")
        XCTAssertEqual(ServerIcon.symbol(for: .windows), "desktopcomputer")
        XCTAssertEqual(ServerIcon.symbol(for: .openwrt), "wifi.router")
    }

    func testServerUsesItsType() {
        func server(_ type: ServerType) -> Server {
            Server.sample(network: .direct, type: type, ip: "10.0.0.1", check: .ssh)
        }
        XCTAssertEqual(server(.openwrt).iconSymbol, "wifi.router")
        XCTAssertEqual(server(.windows).iconSymbol, "desktopcomputer")
    }

    func testTunnelSymbolByKind() {
        XCTAssertEqual(TunnelIcon.symbol(for: .socks), "globe")
        XCTAssertEqual(TunnelIcon.symbol(for: .port(remotePort: 3000)), "arrow.forward.circle")
        XCTAssertEqual(TunnelIcon.symbol(for: .db(host: "db", port: 5432, name: nil)), "cylinder")
    }

    func testTransferSymbolByDirection() {
        XCTAssertEqual(TransferIcon.symbol(for: .upload), "arrow.up.doc")
        XCTAssertEqual(TransferIcon.symbol(for: .download), "arrow.down.doc")
    }
}
