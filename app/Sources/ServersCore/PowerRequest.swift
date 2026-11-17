// 전원 요청(Boot·Shutdown) 뒤 대기: 같은 서버의 전원 버튼을 잠시 막고, 상태가 바뀌면(켜짐/꺼짐 확인) 먼저 푼다.
// 대기를 걸고 푸는 것은 AppModel(startPowerPending·settlePowerPendings), 풀지 말지 판정은 여기. 상태 표는 PowerRequestTests.

import Foundation

public enum PowerRequest: Sendable, Equatable {
    case boot, shutdown

    /// 상태 갱신 뒤 대기를 끝내는가: 부팅 요청은 닿기 시작하면, 종료 요청은 안 닿기 시작하면. 시간이 지난 것(until ≤ now)도 끝낸다
    public func settles(reachable: Bool, until: Date, now: Date) -> Bool {
        let changed = (self == .boot && reachable) || (self == .shutdown && !reachable)
        return changed || until <= now
    }
}
