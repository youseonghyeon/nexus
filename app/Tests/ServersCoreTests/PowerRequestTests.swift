// 전원 요청 뒤 대기를 끝낼지 (PowerRequest.settles) 상태 표. 기댓값은 옮기기 전 AppModel.settlePowerPendings 에서 적었다:
//   (boot && 닿음) || (shutdown && !닿음) || until <= 지금

import Foundation
import XCTest
@testable import ServersCore

final class PowerRequestTests: XCTestCase {
    func testSettleTable() {
        let now = Date(timeIntervalSince1970: 10_000)
        let waiting = now.addingTimeInterval(20), expired = now.addingTimeInterval(-1)
        // (요청, 닿음, 대기 끝 시각, 끝내는가)
        let rows: [(PowerRequest, Bool, Date, Bool)] = [
            (.boot, false, waiting, false),       // 아직 안 켜짐 — 기다린다
            (.boot, true, waiting, true),         // 켜졌다
            (.boot, false, expired, true),        // 시간이 지났다
            (.boot, false, now, true),            // 끝나는 시각 그 순간
            (.shutdown, true, waiting, false),    // 아직 응답한다
            (.shutdown, false, waiting, true),    // 꺼졌다 (확인 전·실패도 응답 없음으로 친다)
            (.shutdown, true, expired, true),
            (.shutdown, true, now, true),
        ]
        for (request, reachable, until, expected) in rows {
            XCTAssertEqual(request.settles(reachable: reachable, until: until, now: now), expected, "\(request) · 닿음 \(reachable) · until \(until.timeIntervalSince(now))")
        }
    }

    func testReachabilityComesFromRemoteState() {
        // AppModel 은 status.remote(key).isReachable 을 넘긴다 — ok 만 닿음. 확인 전(pending)은 닿지 않음이라 종료 대기가 풀린다
        let now = Date()
        let until = now.addingTimeInterval(30)
        let states: [(RemoteState, Bool)] = [
            (.pending, false), (.ok(latencyMs: 3), true), (.fail(latencyMs: 3), false), (.off(latencyMs: 3), false),
            (.skip(reason: "vpn down"), false), (.needsAuth(url: nil), false),
        ]
        for (state, reachable) in states {
            XCTAssertEqual(PowerRequest.boot.settles(reachable: state.isReachable, until: until, now: now), reachable, "boot · \(state)")
            XCTAssertEqual(PowerRequest.shutdown.settles(reachable: state.isReachable, until: until, now: now), !reachable, "shutdown · \(state)")
        }
    }
}
