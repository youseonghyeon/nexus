// 서버 태그 (servers.conf env=, 쉼표로 여러 개 — 태그 안 공백은 그대로: "DEV, Forward Proxy")와 색 분류.
// 운영(빨강)이 하나라도 있으면 운영 서버로 다룬다 — 목록에서 뺄 때 경고. 스테이징·검증은 파랑, 그 밖은 색 없음.

import Foundation

public enum TagTone: Int, Sendable, Comparable {
    case plain, staging, production

    public static func < (a: TagTone, b: TagTone) -> Bool { a.rawValue < b.rawValue }
}

public enum ServerTags {
    /// 빨강: 운영이거나 운영 데이터·트래픽을 다룸
    public static let production: Set<String> = ["PROD", "PRD", "PRODUCTION", "LIVE", "REAL", "DR", "CANARY"]
    /// 파랑: 운영 직전 단계와 검증
    public static let staging: Set<String> = ["STG", "STAGE", "STAGING", "PREPROD", "PRE", "QA", "UAT", "SIT",
                                              "TEST", "TST", "PERF", "LOAD", "BETA"]

    /// 대소문자 무시. 표에 없는 태그(DEV·HOST·DB 등)는 색 없음.
    /// 공백이 든 태그는 낱말마다 본다 — 쉼표 없이 "PROD DB" 로 적어 한 태그가 돼도 운영(빨강)을 놓치지 않게.
    public static func tone(_ tag: String) -> TagTone {
        let words = [tag] + tag.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.map { word -> TagTone in
            let upper = word.uppercased()
            if production.contains(upper) { return .production }
            if staging.contains(upper) { return .staging }
            return .plain
        }.max() ?? .plain
    }

    /// "PROD, db,,prod" → ["PROD", "db"] · "DEV, Forward Proxy" → ["DEV", "Forward Proxy"]. 쉼표로만 나누고 태그 안 공백은 둔다
    /// (앞뒤 공백은 떼고 안쪽 여러 칸은 한 칸으로). 적힌 순서·대소문자 그대로, 빈 항목과 (대소문자 무시) 중복은 뺀다.
    public static func parse(_ raw: String?) -> [String] {
        var seen = Set<String>()
        return (raw ?? "").split(separator: ",")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && seen.insert($0.uppercased()).inserted }
    }

    /// 가장 센 색 (운영 > 스테이징 > 없음)
    public static func strongest(_ tags: [String]) -> TagTone {
        tags.map(tone).max() ?? .plain
    }
}
