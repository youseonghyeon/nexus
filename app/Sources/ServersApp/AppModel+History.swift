// 변경 이력 (history.json — ServersCore ServerHistory): 원격 정보를 받을 때마다 지난번과 견줘 달라진 것을 사건으로 남긴다.
// 서버에 더 보내는 것은 없다 — 이미 받은 결과(Spec · Ports · Services)를 견줄 뿐이다. 화면은 서버 화면의 "변경 이력" 카드(HistoryCard).

import Foundation
import ServersCore

extension AppModel {
    /// 받은 결과를 기록한다. 달라진 것이 있으면 토스트로 한 줄 알린다 (그 서버를 보고 있을 때 받은 결과라 지금 보는 화면의 일이다).
    func recordHistory(_ server: Server, _ parsed: ParsedRemoteInfo) {
        guard let observed = ServerHistory.observe(parsed, type: server.type) else { return }
        let result = ServerHistory.record(observed, serverKey: server.key, in: history)
        saveHistory(result.state)
        if let notice = ServerHistory.notice(result.events, serverKey: server.key) { statusMessage = notice }
    }

    func historyEvents(_ server: Server) -> [HistoryEvent] {
        ServerHistory.events(for: server.key, in: history)
    }

    /// 카드의 [비우기]: 사건만 지운다 (마지막 값은 남는다 — 지금 상태가 다시 쏟아지지 않게)
    func clearHistory(_ server: Server) {
        saveHistory(ServerHistory.clearingEvents(server.key, in: history))
    }

    /// 바뀐 것이 없으면 쓰지 않는다
    func saveHistory(_ state: HistoryState) {
        guard state != history else { return }
        history = state
        do { try ServerHistory.save(state) } catch { statusMessage = "변경 이력 저장 실패: \(error.localizedDescription)" }
    }
}
