// 원격 실행 실패 문구 (RemoteFailure) 상태 표. 기댓값은 옮기기 전 AppModel+Remote 의 failureText·fetchInfo 오류 갈래에서 적었다:
//   한 줄: 취소 → "취소됨" · 인증 → "<키> 인증에 실패했습니다 (…)." · 망 불통 → "<키> 에 연결하지 못했습니다: <stderr>" · 그 밖 → "실패 (exit N)"
//   원격 정보: 성공 → 없음 · 창 없는 조회의 인증 → 안내 · 인증/망/취소 → 한 줄 · 그 밖 → "실패 (exit N) " + 출력 마지막 세 줄

import Foundation
import XCTest
@testable import ServersCore

final class RemoteFailureTests: XCTestCase {
    private let auth = "u@192.0.2.1: Permission denied (publickey,password)."

    func testOneLineTable() {
        let rows: [(String, CommandResult, String)] = [
            ("취소", CommandResult(exitCode: SIGTERM), "취소됨"),
            ("인증", CommandResult(exitCode: 255, stderr: auth), "nexus 인증에 실패했습니다 (취소했거나 비밀번호가 틀림)."),
            ("망 불통", CommandResult(exitCode: 255, stderr: "ssh: connect to host 192.0.2.1 port 22: Operation timed out\n"),
             "nexus 에 연결하지 못했습니다: ssh: connect to host 192.0.2.1 port 22: Operation timed out"),
            ("망 불통 · stderr 없음", CommandResult(exitCode: 255), "nexus 에 연결하지 못했습니다: "),
            ("시간 초과", CommandResult(exitCode: CommandResult.timedOutExitCode), "실패 (exit 124)"),
            ("원격 명령 실패", CommandResult(exitCode: 1, stderr: "boom"), "실패 (exit 1)"),
        ]
        for (name, result, expected) in rows {
            XCTAssertEqual(RemoteFailure.text(result, serverKey: "nexus"), expected, name)
        }
    }

    func testInfoErrorTable() {
        let prompt = "인증이 필요합니다 · 새로고침을 누르면 비밀번호를 묻습니다."
        let authLine = "nexus 인증에 실패했습니다 (취소했거나 비밀번호가 틀림)."
        // (이름, 결과, allowPrompt, 문구)
        let rows: [(String, CommandResult, Bool, String?)] = [
            ("성공", CommandResult(exitCode: 0, stdout: "x"), false, nil),
            ("성공 · 출력 없음", CommandResult(exitCode: 0), true, nil),
            ("자동 조회 · 인증 필요 — 안내만", CommandResult(exitCode: 255, stderr: auth), false, prompt),
            ("새로고침 · 인증 실패", CommandResult(exitCode: 255, stderr: auth), true, authLine),
            ("자동 조회 · 망 불통", CommandResult(exitCode: 255, stderr: "No route to host"), false, "nexus 에 연결하지 못했습니다: No route to host"),
            ("새로고침 · 취소", CommandResult(exitCode: SIGTERM), true, "취소됨"),
            ("원격 명령 실패 · 마지막 세 줄 (빈 줄 뺌)", CommandResult(exitCode: 2, stdout: "a\n\nb", stderr: "c\nd\n"), true, "실패 (exit 2) d · a · b"),
            ("원격 명령 실패 · 출력 없음", CommandResult(exitCode: 127), false, "실패 (exit 127) "),
            ("시간 초과", CommandResult(exitCode: CommandResult.timedOutExitCode, stderr: "slow"), false, "실패 (exit 124) slow"),
        ]
        for (name, result, allowPrompt, expected) in rows {
            XCTAssertEqual(RemoteFailure.infoError(result, serverKey: "nexus", type: .linux, allowPrompt: allowPrompt), expected, name)
        }
    }

    func testInfoErrorCleansWindowsOutput() {
        // Windows: CRLF·CLIXML 진행 메시지를 뺀 뒤 마지막 세 줄
        let result = CommandResult(exitCode: 1, stderr: "#< CLIXML\r\n<Objs Version=\"1.1\">\r\nGet-Service : 오류\r\n")
        XCTAssertEqual(RemoteFailure.infoError(result, serverKey: "win", type: .windows, allowPrompt: true), "실패 (exit 1) Get-Service : 오류")
    }
}
