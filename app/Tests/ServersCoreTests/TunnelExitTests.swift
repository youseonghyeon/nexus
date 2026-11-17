// 터널 ssh 종료 갈래 (TunnelExit) 상태 표. 기댓값은 옮기기 전 AppModel.startTunnel 의 onExit 에서 적었다:
//   byUser = stopRequested · cancelled = !byUser && SIGTERM && 연결 중 · reason = byUser ? (stopReason ?? "끊음") : cancelled ? "취소됨" : 0 ? "정상 종료" : (메시지 ?? "exit N")
//   토스트 = byUser → "터널 끊음(이유): 제목" · cancelled → "터널 취소됨: 제목" · 0 이 아님 → "터널 끊김: 제목 · 사유 마지막 줄" · 정상 종료 → 없음

import Foundation
import XCTest
@testable import ServersCore

final class TunnelExitTests: XCTestCase {
    private let title = "nexus 5432"

    func testExitTable() {
        let term = SIGTERM, shellTerm = 128 + SIGTERM
        // (이름, stopRequested, stopReason, exit, message, 연결 중, 갈래, 사유, 토스트)
        let rows: [(String, Bool, String?, Int32, String, Bool, TunnelExit.Kind, String, String?)] = [
            ("[끊기]", true, nil, term, "", false, .byUser, "끊음", "터널 끊음: nexus 5432"),
            ("접속 정보 바뀜", true, "접속 정보 바뀜", term, "", false, .byUser, "접속 정보 바뀜", "터널 끊음(접속 정보 바뀜): nexus 5432"),
            ("연결 중에 끊기 (취소보다 앞선다)", true, nil, term, "", true, .byUser, "끊음", "터널 끊음: nexus 5432"),
            ("앱이 끊었는데 0 으로 끝남", true, nil, 0, "", false, .byUser, "끊음", "터널 끊음: nexus 5432"),
            ("비밀번호 창 취소 (연결 중 SIGTERM)", false, nil, term, "", true, .cancelled, "취소됨", "터널 취소됨: nexus 5432"),
            ("셸이 넘긴 SIGTERM (143)", false, nil, shellTerm, "", true, .cancelled, "취소됨", "터널 취소됨: nexus 5432"),
            ("열린 뒤 SIGTERM (밖에서 끊음)", false, nil, term, "", false, .failed, "exit 15", "터널 끊김: nexus 5432 · exit 15"),
            ("정상 종료", false, nil, 0, "", false, .normal, "정상 종료", nil),
            ("연결 중에 0 으로 끝남", false, nil, 0, "", true, .normal, "정상 종료", nil),
            ("망 끊김 · 메시지 여러 줄", false, nil, 255, "Warning: x\nConnection closed by 192.0.2.1", false, .failed,
             "Warning: x\nConnection closed by 192.0.2.1", "터널 끊김: nexus 5432 · Connection closed by 192.0.2.1"),
            ("메시지 없음", false, nil, 255, "", true, .failed, "exit 255", "터널 끊김: nexus 5432 · exit 255"),
            ("앱이 끊지 않았으면 stopReason 은 쓰지 않는다", false, "접속 정보 바뀜", 1, "", false, .failed, "exit 1", "터널 끊김: nexus 5432 · exit 1"),
        ]
        for (name, requested, stopReason, code, message, connecting, kind, reason, notice) in rows {
            let outcome = TunnelExit(stopRequested: requested, stopReason: stopReason, exitCode: code, message: message, wasConnecting: connecting)
            XCTAssertEqual(outcome.kind, kind, name)
            XCTAssertEqual(outcome.reason, reason, name)
            XCTAssertEqual(outcome.notice(title: title, stopReason: stopReason), notice, name)
        }
    }
}
