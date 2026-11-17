import Foundation
@testable import ServersCore
import XCTest

final class SSHOutcomeTests: XCTestCase {
    private func outcome(_ code: Int32, _ stderr: String = "") -> SSHOutcome {
        SSHOutcome(CommandResult(exitCode: code, stderr: stderr))
    }

    func testClassifiesExitCodes() {
        XCTAssertEqual(outcome(0), .ok)
        XCTAssertEqual(outcome(SIGTERM), .cancelled, "비밀번호 창 취소")
        XCTAssertEqual(outcome(128 + SIGTERM), .cancelled)
        XCTAssertEqual(outcome(CommandResult.timedOutExitCode), .timedOut)
        XCTAssertEqual(outcome(1, "Permission denied"), .remoteFailed, "255 가 아니면 원격 명령 실패 — stderr 문구로 인증을 의심하지 않는다")
        XCTAssertEqual(outcome(CommandResult.timedOutExitCode, "Permission denied"), .timedOut, "종료 코드가 문구보다 앞선다")
    }

    /// 255 중 인증만 비밀번호 창으로 다시 시도한다 — 망 불통이면 소용없고 명령이 두 번 돌 수 있다
    func testOnly255WithAuthPromptNeedsAuth() {
        XCTAssertEqual(outcome(255, "u@1.1.1.1: Permission denied (publickey,password)."), .needsAuth)
        XCTAssertEqual(outcome(255, "Host key verification failed."), .needsAuth)
        XCTAssertEqual(outcome(255, "Are you sure you want to continue connecting (yes/no/[fingerprint])?"), .needsAuth)
        XCTAssertEqual(outcome(255, "ssh: connect to host 1.1.1.1 port 22: Connection refused"), .unreachable)
        XCTAssertEqual(outcome(255, "Connection closed by 1.1.1.1 port 22"), .unreachable)
        XCTAssertEqual(outcome(255), .unreachable)
    }

    func testTerminationExitCodes() {
        XCTAssertTrue(SSHOutcome.isTermination(SIGTERM))
        XCTAssertTrue(SSHOutcome.isTermination(128 + SIGTERM))
        XCTAssertFalse(SSHOutcome.isTermination(0))
        XCTAssertFalse(SSHOutcome.isTermination(255))
    }
}
