// 터널 ssh 가 끝났을 때의 갈래: 닫힌 항목에 남길 사유와 토스트 문구 (AppModel.startTunnel 의 onExit 가 적용만 한다).
// 상태 표는 TunnelExitTests.

import Foundation

public struct TunnelExit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 앱이 끊었다 ([끊기]·접속 정보 바뀜 등 stopReason)
        case byUser
        /// 연결 중에 SIGTERM — 비밀번호 창 취소 등
        case cancelled
        /// 0 으로 끝남
        case normal
        /// 그 밖 (망 끊김·인증 실패…)
        case failed
    }

    public let kind: Kind
    /// 닫힌 항목에 남길 사유 (TunnelSession.state .closed 의 message)
    public let reason: String

    /// stopRequested = 앱이 stop() 을 불렀다 · stopReason = 끊은 이유 · wasConnecting = 끝날 때 아직 연결 중이었다 · message = ssh 의 마지막 출력
    public init(stopRequested: Bool, stopReason: String?, exitCode: Int32, message: String, wasConnecting: Bool) {
        if stopRequested {
            kind = .byUser
            reason = stopReason ?? "끊음"
        } else if SSHOutcome.isTermination(exitCode) && wasConnecting {
            kind = .cancelled
            reason = "취소됨"
        } else if exitCode == 0 {
            kind = .normal
            reason = "정상 종료"
        } else {
            kind = .failed
            reason = message.isEmpty ? "exit \(exitCode)" : message
        }
    }

    /// 토스트 문구. 정상 종료면 nil (알리지 않는다). stopReason 은 byUser 일 때만 쓴다
    public func notice(title: String, stopReason: String?) -> String? {
        switch kind {
        case .byUser: return stopReason.map { "터널 끊음(\($0)): \(title)" } ?? "터널 끊음: \(title)"
        case .cancelled: return "터널 취소됨: \(title)"
        case .normal: return nil
        case .failed: return "터널 끊김: \(title) · \(reason.split(separator: "\n").last ?? "")"
        }
    }
}
