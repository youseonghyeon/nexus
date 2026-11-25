// 로그 줄의 레벨 판정 (조회 결과 창 — 오류 · 경고 줄을 색으로, 아래 띠의 개수 · 걸러 보기).
// 본문 속 낱말("no error" · "0 errors")이 아니라 레벨이 적히는 자리만 본다 — 못 읽으면 nil(색 없이 그대로).
//   1) klog 머리: "I1124 20:08:19.929324" · W · E · F
//   2) 키-값: level=error · "level":"warn" · lvl= · severity= (구조화 로그, 줄 어디든)
//   3) 줄 앞쪽(headLength 글자)의 레벨 토큰: 대문자 ERROR · WARN · INFO · DEBUG …, 괄호로 싼 것은 소문자도 — [error] · <warn>
// 들여쓰기로 시작하는 줄(스택 트레이스)과 "Caused by:" 는 앞줄의 레벨을 물려받는다.

import Foundation

public enum LogLevel: Equatable, Sendable {
    case error, warning, info, debug

    /// 토큰이 줄 앞쪽 이만큼 안에 있어야 레벨로 본다 (시각 · 호스트 · 유닛 머리를 지난 자리까지)
    static let headLength = 120

    private static let names: [String: LogLevel] = [
        "error": .error, "err": .error, "fatal": .error, "crit": .error, "critical": .error, "panic": .error, "emerg": .error, "alert": .error, "severe": .error,
        "warn": .warning, "warning": .warning, "wrn": .warning,
        "info": .info, "inf": .info, "notice": .info, "log": .info,
        "debug": .debug, "dbg": .debug, "trace": .debug, "trc": .debug, "verbose": .debug,
    ]

    /// 한 줄만 보고 판정 (물려받기 없음)
    public static func detect(_ line: String) -> LogLevel? {
        if let level = klog(line) { return level }
        if let level = keyValue(line) { return level }
        return headToken(line)
    }

    /// 줄마다의 레벨: 들여쓰기로 시작하는 줄 · "Caused by:" 는 앞줄의 것을 물려받는다
    public static func resolve(_ lines: [String]) -> [LogLevel?] {
        var result: [LogLevel?] = []
        result.reserveCapacity(lines.count)
        var previous: LogLevel?
        for line in lines {
            let continues = (line.first == " " || line.first == "\t") && !line.allSatisfy(\.isWhitespace) || line.hasPrefix("Caused by:")
            let level = continues ? previous : detect(line)
            result.append(level)
            if !line.allSatisfy(\.isWhitespace) { previous = level }
        }
        return result
    }

    /// "I1124 20:08:19.929324 …" — 글자 하나 + 월일 네 자리 + 빈칸 + 시각
    private static func klog(_ line: String) -> LogLevel? {
        guard let match = line.prefixMatch(of: #/([IWEF])\d{4} \d{2}:\d{2}:\d{2}/#) else { return nil }
        switch match.1 {
        case "I": return .info
        case "W": return .warning
        default: return .error
        }
    }

    private static func keyValue(_ line: String) -> LogLevel? {
        guard let match = line.firstMatch(of: #/(?i)(?:^|[\s{,"'\[])(?:level|lvl|severity)["']?\s*[=:]\s*["']?([a-z]+)/#) else { return nil }
        return names[match.1.lowercased()]
    }

    private static func headToken(_ line: String) -> LogLevel? {
        let head = Array(line.prefix(headLength))
        var index = 0
        while index < head.count {
            guard head[index].isASCII, head[index].isLetter else { index += 1; continue }
            var end = index
            while end < head.count, head[end].isASCII, head[end].isLetter { end += 1 }
            let word = String(head[index..<end])
            // 낱말 경계: 앞뒤가 숫자 · 밑줄이면 식별자의 일부 (ERROR_CODE · E2BIG)
            let before = index > 0 ? head[index - 1] : " "
            let after = end < head.count ? head[end] : " "
            let bounded = !(before.isNumber || before == "_") && !(after.isNumber || after == "_")
            if bounded, let level = names[word.lowercased()] {
                let upper = word == word.uppercased()
                let bracketed = (before == "[" && after == "]") || (before == "<" && after == ">")
                // "LOG" · "ERR" 같은 짧은 것도 대문자거나 괄호 안일 때만 — 문장 속 소문자 낱말은 레벨이 아니다
                if upper || bracketed { return level }
            }
            index = end
        }
        return nil
    }
}
