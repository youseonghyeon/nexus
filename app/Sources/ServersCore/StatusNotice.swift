// 상태줄 알림(오른쪽 아래 토스트)의 문구 분류.
// 앱의 상태 메시지는 한국어 문장이라 실패·불가 표현으로 경고를 가른다 — 메시지를 만드는 수십 곳에 종류를 일일이 달지 않게.

import Foundation

public enum StatusNotice {
    /// 이 표현이 들어가면 경고(주황)로 띄운다. 새 메시지도 실패·불가를 이 말로 쓰면 저절로 경고가 된다.
    /// "취소" 는 넣지 않는다 — 사용자가 직접 취소한 것(전송 취소·터널 취소됨)은 안내다.
    public static let warningPhrases = ["실패", "없습니다", "못", "않았습니다", "않습니다", "필요합니다", "끊김"]

    public static func isWarning(_ text: String) -> Bool {
        warningPhrases.contains { text.contains($0) }
    }
}
