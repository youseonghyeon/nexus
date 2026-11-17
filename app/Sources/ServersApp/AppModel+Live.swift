// 서버 정보 "실시간" 탭: 서버별 수집기와 실패 문구.

import Foundation
import ServersCore

extension AppModel {
    func liveMonitor(_ server: Server) -> ServerLiveMonitor {
        if let monitor = liveMonitors[server.key] { return monitor }
        let monitor = ServerLiveMonitor()
        liveMonitors[server.key] = monitor
        return monitor
    }

    /// 간격마다는 비밀번호 창 없이 읽는다. 인증이 필요하면 멈추고 [다시 시도] 로 한 번 인증하게 안내한다 ([문제 · 해결]).
    func liveFailureText(_ result: CommandResult, server: Server) -> String {
        switch SSHOutcome(result) {
        case .needsAuth: return "\(server.key) 인증에 실패해 읽기를 멈췄습니다 · [다시 시도]를 누르면 비밀번호를 묻습니다"
        case .unreachable: return "\(server.key) 에 연결하지 못했습니다 · 다음 갱신에서 다시 시도합니다"
        case .timedOut: return "\(server.key) 응답이 10초 안에 오지 않았습니다 · 다음 갱신에서 다시 시도합니다"
        default: return "\(server.key) 에서 실시간 정보를 읽지 못했습니다 (exit \(result.exitCode))"
        }
    }
}
