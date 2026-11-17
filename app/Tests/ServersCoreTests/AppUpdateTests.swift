@testable import ServersCore
import XCTest

final class AppUpdateTests: XCTestCase {
    private func run(_ events: [AppUpdate.Event], from start: AppUpdate = .none) -> AppUpdate {
        events.reduce(start) { $0.applying($1) }
    }

    /// 발견 → 누름 → 받기 → 풀기 → 설치: 엔진이 알리는 순서 그대로
    func testFullFlow() {
        var state = AppUpdate.none
        XCTAssertNil(state.subtitle); XCTAssertNil(state.buttonTitle); XCTAssertNil(state.title(appName: "Nexus"))

        state = state.applying(.found(version: "1.2.0"))
        XCTAssertEqual(state, .available(version: "1.2.0"))
        XCTAssertEqual(state.title(appName: "Nexus"), "Nexus 1.2.0")
        XCTAssertEqual(state.subtitle, "새 버전이 있습니다")
        XCTAssertEqual(state.buttonTitle, "업데이트")

        state = state.applying(.downloadStarted)
        XCTAssertEqual(state.subtitle, "받는 중…", "크기를 모르면 진행률 없음")
        XCTAssertNil(state.progress); XCTAssertNil(state.buttonTitle)

        state = state.applying(.expected(200)).applying(.received(50)).applying(.received(34))
        XCTAssertEqual(state.progress, 0.42)
        XCTAssertEqual(state.subtitle, "받는 중 42%")

        state = state.applying(.extracting)
        XCTAssertEqual(state, .preparing(version: "1.2.0"))
        XCTAssertNil(state.progress)

        state = state.applying(.installing)
        XCTAssertEqual(state.subtitle, "설치 중 · 곧 다시 시작합니다")
        XCTAssertEqual(state.applying(.dismissed), .none)
    }

    /// 압축 전송은 받은 양이 알린 크기를 넘는다 · 크기가 받은 뒤에 와도 100% 를 넘기지 않는다
    func testProgressNeverExceedsOne() {
        XCTAssertEqual(run([.found(version: "2"), .downloadStarted, .expected(100), .received(80), .received(80)]).progress, 1)
        XCTAssertEqual(run([.found(version: "2"), .downloadStarted, .received(300), .expected(100)]).progress, 1)
        XCTAssertEqual(run([.found(version: "2"), .downloadStarted, .expected(0), .received(10)]).subtitle, "받는 중…")
    }

    /// 실패는 띠에 남는다 (엔진이 과정을 닫아도) — 다시 시도하면 처음부터
    func testFailureStaysUntilRetry() {
        let failed = run([.found(version: "1.2.0"), .downloadStarted, .expected(10), .received(3), .failed, .dismissed])
        XCTAssertEqual(failed, .failed(version: "1.2.0"))
        XCTAssertEqual(failed.subtitle, "업데이트 실패")
        XCTAssertEqual(failed.buttonTitle, "다시 시도")
        XCTAssertEqual(failed.applying(.extracting), failed, "늦게 온 진행 알림이 실패를 덮지 않는다")
        XCTAssertEqual(failed.applying(.found(version: "1.2.1")), .available(version: "1.2.1"))
        XCTAssertEqual(failed.applying(.downloadStarted), .downloading(version: "1.2.0", received: 0, expected: 0))
        XCTAssertEqual(failed.applying(.notFound), .none, "다시 확인했더니 그 버전이 내려갔다")
    }

    /// 새 버전이 없는데 오는 알림(확인 실패·과정 닫힘·진행)은 띠를 만들지 않는다
    func testNothingWithoutUpdate() {
        for event: AppUpdate.Event in [.downloadStarted, .expected(5), .received(5), .extracting, .installing, .failed, .notFound, .dismissed] {
            XCTAssertEqual(AppUpdate.none.applying(event), .none, "\(event)")
        }
    }

    /// 받는 중·설치 중에 다시 "발견"이 와도 되돌아가지 않는다 · 사용자가 안 누른 채 과정이 닫히면 띠를 치운다
    func testFoundDuringWorkAndDismiss() {
        let downloading = run([.found(version: "1"), .downloadStarted, .expected(10), .received(5)])
        XCTAssertEqual(downloading.applying(.found(version: "2")), downloading)
        XCTAssertEqual(run([.found(version: "1"), .extracting, .found(version: "2")]), .preparing(version: "1"))
        XCTAssertEqual(run([.found(version: "1"), .installing, .found(version: "2")]), .installing(version: "1"))
        XCTAssertEqual(run([.found(version: "1"), .dismissed]), .none)
        // 이미 받아 둔 업데이트는 받기 없이 바로 풀기·설치로 간다
        XCTAssertEqual(run([.found(version: "1"), .installing]), .installing(version: "1"))
    }

    func testRestartWarning() {
        XCTAssertNil(AppUpdate.restartWarning(tabs: 0, tunnels: 0, transfers: 0))
        XCTAssertEqual(AppUpdate.restartWarning(tabs: 2, tunnels: 0, transfers: 0), "업데이트하면 앱이 다시 시작되어 터미널 탭 2개가 끊깁니다.")
        XCTAssertEqual(AppUpdate.restartWarning(tabs: 1, tunnels: 3, transfers: 1),
                       "업데이트하면 앱이 다시 시작되어 터미널 탭 1개 · 터널 3개 · 진행 중인 전송 1개가 끊깁니다.")
    }
}
