// 리눅스 원격 정보 화면 글자: systemd 타이머의 다음·지난 실행 ("14분 뒤" · "2시간 전"). 지금 시각은 인자로 받는다.

import Foundation

extension SystemdTimer {
    /// 다음 실행: 지났거나 지금이면 "곧", 남았으면 "14분 뒤", 예정이 없으면 "–"
    public func nextText(now: Date) -> String {
        next.map { $0 <= now ? "곧" : "\(DurationFormat.compact($0.timeIntervalSince(now))) 뒤" } ?? "–"
    }

    /// 지난 실행: "2시간 전", 한 번도 안 돌았으면 "–"
    public func lastText(now: Date) -> String {
        last.map { "\(DurationFormat.compact(now.timeIntervalSince($0))) 전" } ?? "–"
    }
}
