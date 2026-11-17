// ssh 실행 결과의 갈래. 비밀번호 창으로 다시 시도할지, 실시간 읽기를 멈출지(반복 로그인 실패 → 계정 잠금 방지),
// 어떤 실패 문구를 낼지를 이 판정 하나로 정한다.

import Foundation

public enum SSHOutcome: Sendable, Equatable {
    case ok
    /// 비밀번호 창 취소·사용자 중단 (SIGTERM)
    case cancelled
    /// 앱이 정한 시간 안에 끝나지 않아 CommandRunner 가 끊음
    case timedOut
    /// ssh 255 + 비밀번호·호스트 키 확인 필요 — 창을 띄우면 풀린다
    case needsAuth
    /// ssh 255 그 밖 — 망 불통·끊김. 다시 시도해도 소용없고 명령이 두 번 돌 수 있다
    case unreachable
    /// 접속은 됐고 원격 명령이 0 이 아닌 값으로 끝남
    case remoteFailed

    public init(_ result: CommandResult) {
        switch result.exitCode {
        case 0: self = .ok
        case _ where Self.isTermination(result.exitCode): self = .cancelled
        case CommandResult.timedOutExitCode: self = .timedOut
        case 255: self = Self.needsAuthentication(result.stderr) ? .needsAuth : .unreachable
        default: self = .remoteFailed
        }
    }

    /// SIGTERM 으로 끝난 종료 코드 (직접 받은 신호 또는 셸이 넘긴 128+신호)
    public static func isTermination(_ code: Int32) -> Bool {
        code == SIGTERM || code == 128 + SIGTERM
    }

    /// BatchMode 실패 중 비밀번호·호스트 키 확인이 있으면 풀리는 경우
    static func needsAuthentication(_ stderr: String) -> Bool {
        stderr.contains("Permission denied") || stderr.contains("Host key verification failed") || stderr.contains("(yes/no")
    }
}
