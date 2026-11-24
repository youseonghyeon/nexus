// `uci show` 출력 풀이: "패키지.섹션=종류" 가 섹션 줄, "패키지.섹션.옵션='값' '값'" 이 옵션 줄.
// 섹션을 묶는 법은 둘이다 — 나온 순서대로(sections — Firewall: 위쪽 규칙이 먼저 적용된다) · 그 종류만 이름순으로(sections(_:type:) — Clients).
// WireGuard 는 섹션 줄 없이 "패키지.섹션" 으로 옵션을 잇는다 (WireGuardReport.parse — entry 만 쓴다).

import Foundation

enum UCI {
    /// 한 줄 → 경로 칸("패키지" · "섹션" · "옵션")과 값 원문. = 가 없으면 nil
    static func entry(_ line: String) -> (path: [String], value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return (line[..<eq].split(separator: ".").map(String.init), String(line[line.index(after: eq)...]))
    }

    /// 값 "'a' 'b c'" → ["a", "b c"]. 값 안의 ' 는 uci 가 '\'' 로 내보낸다 ("Bob'\''s" → "Bob's"). 따옴표 없는 값은 통째로.
    static func values(_ text: String) -> [String] {
        guard text.hasPrefix("'") else { return text.isEmpty ? [] : [text] }
        let chars = Array(text)
        var values: [String] = [], current = "", inside = false, i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" {
                if inside, i + 3 < chars.count, chars[i + 1] == "\\", chars[i + 2] == "'", chars[i + 3] == "'" {
                    current.append("'"); i += 4; continue
                }
                if inside { values.append(current); current = "" }
                inside.toggle()
            } else if inside {
                current.append(ch)
            }
            i += 1
        }
        return values
    }

    struct Section {
        let name: String
        let type: String
        var options: [String: [String]] = [:]

        func first(_ key: String) -> String? { options[key]?.first }
        /// enabled 는 없으면 켜짐
        var isEnabled: Bool { !["0", "no", "off", "false"].contains(first("enabled") ?? "1") }
        func joined(_ key: String) -> String? { options[key].map { $0.joined(separator: ",") } }
    }

    /// 나온 순서 그대로. 섹션 줄보다 먼저 온 옵션은 버리고, 같은 이름의 섹션 줄이 다시 나오면 새 섹션이다.
    static func sections(_ lines: [String]) -> [Section] {
        var result: [Section] = []
        var index: [String: Int] = [:]
        for line in lines {
            guard let (path, value) = entry(line) else { continue }
            if path.count == 2 {
                index[path[1]] = result.count
                result.append(Section(name: path[1], type: value))
            } else if path.count == 3, let i = index[path[1]] {
                result[i].options[path[2]] = values(value)
            }
        }
        return result
    }

    /// 그 종류(=host · =client) 섹션들의 옵션 → 값 목록. 섹션 이름 순 (@rule[10] 이 @rule[2] 앞 — 순서가 뜻을 갖는 곳에는 쓰지 않는다).
    /// 옵션은 섹션 이름으로만 모은다: 섹션 줄보다 먼저 와도, 패키지가 달라도 합쳐진다.
    static func sections(_ lines: [String], type: String) -> [[String: [String]]] {
        var matched: Set<String> = []
        var fields: [String: [String: [String]]] = [:]
        for line in lines {
            guard let (path, value) = entry(line) else { continue }
            if path.count == 2, value == type { matched.insert(path[1]); continue }
            guard path.count == 3 else { continue }
            fields[path[1], default: [:]][path[2]] = values(value)
        }
        return matched.sorted().map { fields[$0] ?? [:] }
    }
}
