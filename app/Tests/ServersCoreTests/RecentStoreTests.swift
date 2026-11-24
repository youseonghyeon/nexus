// RecentStore: 최근 터널 기록 병합·정렬·저장.

import Foundation
import XCTest
@testable import ServersCore

final class RecentStoreTests: XCTestCase {
    func testRecordMergesSortsAndCaps() {
        var state = RecentState()
        let t0 = Date(timeIntervalSince1970: 1_000)
        state = RecentStore.record(RecentTunnel(serverKey: "was", kind: .db(host: "192.168.113.6", port: 5432, name: "acme"), localPort: 15432, lastUsed: t0), in: state)
        state = RecentStore.record(RecentTunnel(serverKey: "win", kind: .port(remotePort: 443), localPort: 8443, lastUsed: t0.addingTimeInterval(10)), in: state)
        // 같은 터널(서버·원격 대상)은 하나로: 로컬 포트·시각만 갱신
        state = RecentStore.record(RecentTunnel(serverKey: "was", kind: .db(host: "192.168.113.6", port: 5432, name: "acme"), localPort: 15433, lastUsed: t0.addingTimeInterval(20)), in: state)
        XCTAssertEqual(state.tunnels.count, 2)
        XCTAssertEqual(state.tunnels.first?.serverKey, "was", "최근 순")
        XCTAssertEqual(state.tunnels.first?.localPort, 15433)
        XCTAssertEqual(state.tunnels.first?.summary, "localhost:15433 → was → 192.168.113.6:5432")
        XCTAssertEqual(state.tunnels.last?.summary, "localhost:8443 → win localhost:443")
        // 서버당 상한: 오래된 것부터 버린다
        for i in 0..<(RecentStore.perServerLimit + 3) {
            state = RecentStore.record(RecentTunnel(serverKey: "nexus", kind: .port(remotePort: 1000 + i), localPort: 1000 + i, lastUsed: t0.addingTimeInterval(Double(100 + i))), in: state)
        }
        let nexus = state.tunnels.filter { $0.serverKey == "nexus" }
        XCTAssertEqual(nexus.count, RecentStore.perServerLimit)
        XCTAssertEqual(nexus.first.map { if case let .port(p, _) = $0.kind { return p } else { return -1 } }, 1000 + RecentStore.perServerLimit + 2, "가장 최근 것이 남는다")
        XCTAssertEqual(state.tunnels.filter { $0.serverKey != "nexus" }.count, 2, "다른 서버 기록은 그대로")
        state = RecentStore.remove(id: state.tunnels.last!.id, from: state)
        XCTAssertEqual(state.tunnels.count, RecentStore.perServerLimit + 1)
    }

    func testSaveAndLoadRoundTrip() throws {
        let url = tempPath("recent").appendingPathComponent("Servers/recent.json")
        XCTAssertEqual(RecentStore.load(from: url), RecentState(), "파일이 없으면 빈 상태")
        let state = RecentStore.record(RecentTunnel(serverKey: "was", kind: .db(host: "h", port: 5432, name: "acme"), localPort: 15432), in: RecentState())
        try RecentStore.save(state, to: url)
        let loaded = RecentStore.load(from: url)
        XCTAssertEqual(loaded.tunnels.map(\.id), state.tunnels.map(\.id))
        XCTAssertEqual(loaded.tunnels.first?.kind, .db(host: "h", port: 5432, name: "acme"))
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(RecentStore.load(from: url), RecentState(), "깨진 파일은 빈 상태로 (오류로 막지 않는다)")
    }
}
