// 원격 실행(ssh) 실패를 사용자에게 보일 문구로: 한 줄 실패(Wake·Shutdown·원격 정보 공통)와 원격 정보 카드의 오류 줄.
// 갈래는 SSHOutcome 하나. 상태 표는 RemoteFailureTests.

import Foundation

public enum RemoteFailure {
    /// 실패 결과를 한 줄로 (취소·인증·망 불통은 이유, 그 밖은 종료 코드)
    public static func text(_ result: CommandResult, serverKey: String) -> String {
        switch SSHOutcome(result) {
        case .cancelled: return "취소됨"
        case .needsAuth: return "\(serverKey) 인증에 실패했습니다 (취소했거나 비밀번호가 틀림)."
        case .unreachable: return "\(serverKey) 에 연결하지 못했습니다: " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return "실패 (exit \(result.exitCode))"
        }
    }

    /// 원격 정보 카드의 오류 줄. 성공이면 nil.
    /// allowPrompt=false(자동·탭 전환 조회)에서 인증이 필요하면 안내만 — 새로고침(↻)이 비밀번호를 묻는다.
    /// 접속 단계 실패(인증·망·취소)는 한 줄(text), 원격 명령 실패는 종료 코드 + 출력 마지막 세 줄
    public static func infoError(_ result: CommandResult, serverKey: String, type: ServerType, allowPrompt: Bool) -> String? {
        let outcome = SSHOutcome(result)
        if outcome == .ok { return nil }
        if !allowPrompt, outcome == .needsAuth { return "인증이 필요합니다 · 새로고침을 누르면 비밀번호를 묻습니다." }
        if [.needsAuth, .unreachable, .cancelled].contains(outcome) { return text(result, serverKey: serverKey) }
        let lines = RemoteCommands.cleanOutput(result.stderr + result.stdout, type: type).filter { !$0.isEmpty }
        return "실패 (exit \(result.exitCode)) " + lines.suffix(3).joined(separator: " · ")
    }
}
