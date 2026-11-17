// servers.conf 블록 순서 바꾸기 (그룹 안 서버 · 그룹). 사이드바 순서는 파일의 블록 순서다.

import Foundation

extension ServerConfigEditor {
    public enum MoveDirection: Sendable { case up, down }

    /// 같은 그룹에서 바로 위·아래 서버 키. 그룹 끝이면 nil (메뉴 비활성).
    public static func neighbor(of key: String, _ direction: MoveDirection, in config: ServerConfig) -> String? {
        guard let server = config.server(key) else { return nil }
        let keys = config.servers(in: server.group).map(\.key)
        guard let i = keys.firstIndex(of: key) else { return nil }
        let j = direction == .up ? i - 1 : i + 1
        return keys.indices.contains(j) ? keys[j] : nil
    }

    /// 같은 그룹의 이웃 블록과 자리를 바꾼 텍스트. 블록 = 바로 위에 붙은 주석(빈 줄 없이) + 헤더 + 마지막 설정 줄까지.
    /// 사이의 빈 줄·다른 블록은 제자리에 둔다.
    public static func moving(key: String, _ direction: MoveDirection, in text: String, reference: String = "servers.conf") throws -> String {
        let current = try ServerConfigParser.parse(text, reference: reference)
        guard current.server(key) != nil else {
            throw missingServer(key, reference: reference)
        }
        guard let other = neighbor(of: key, direction, in: current) else {
            throw ConfigError(problem: "'\(key)' 는 그룹의 \(direction == .up ? "맨 위" : "맨 아래")라 옮길 수 없습니다.", fix: "다른 방향으로 옮기세요.", reference: reference)
        }
        let all = lines(of: text)
        guard let a = unitRange(direction == .up ? other : key, in: all), let b = unitRange(direction == .up ? key : other, in: all) else {
            throw ConfigError(problem: "'\(key)' 블록 헤더를 찾지 못했습니다.", fix: "servers.conf 에서 직접 옮기세요.", reference: reference)
        }
        // a 가 앞, b 가 뒤
        let result = Array(all[..<a.lowerBound]) + Array(all[b]) + Array(all[(a.upperBound + 1)..<b.lowerBound]) + Array(all[a]) + Array(all[(b.upperBound + 1)...])
        let joined = result.joined(separator: "\n") + "\n"
        _ = try ServerConfigParser.parse(joined, reference: reference)
        return joined
    }

    /// 블록 한 개의 줄 범위: 바로 위에 붙은 주석(빈 줄 없이) + 헤더 + 마지막 설정 줄까지
    private static func unitRange(_ name: String, in all: [String]) -> ClosedRange<Int>? {
        guard let span = blockSpan(name, in: all) else { return nil }
        var start = span.header
        while start > 0, all[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { start -= 1 }
        return start...span.last
    }

    /// 그룹 순서(첫 서버 블록이 나오는 순서)에서 바로 위·아래 그룹. 끝이면 nil (메뉴 비활성).
    public static func groupNeighbor(of group: String, _ direction: MoveDirection, in config: ServerConfig) -> String? {
        guard let i = config.groups.firstIndex(of: group) else { return nil }
        let j = direction == .up ? i - 1 : i + 1
        return config.groups.indices.contains(j) ? config.groups[j] : nil
    }

    /// 그룹 순서를 바꾼 텍스트: 뒤 그룹의 서버 블록 전부(붙은 주석 포함, 그룹 안 순서 그대로)를 앞 그룹의 첫 서버 블록 앞으로 옮긴다.
    /// [group:…]·[network:…] 블록과 앞 그룹 블록은 제자리.
    public static func movingGroup(_ group: String, _ direction: MoveDirection, in text: String, reference: String = "servers.conf") throws -> String {
        let current = try ServerConfigParser.parse(text, reference: reference)
        guard current.groups.contains(group) else {
            throw ConfigError(problem: "'\(group)' 그룹이 servers.conf 에 없습니다.", fix: "보기 ▸ servers.conf 다시 읽기(⌘⇧R)로 목록을 다시 읽으세요.", reference: reference)
        }
        guard let other = groupNeighbor(of: group, direction, in: current) else {
            throw ConfigError(problem: "'\(group)' 그룹은 \(direction == .up ? "맨 위" : "맨 아래")라 옮길 수 없습니다.", fix: "다른 방향으로 옮기세요.", reference: reference)
        }
        let (front, back) = direction == .up ? (other, group) : (group, other)
        var all = lines(of: text)
        // 뒤 그룹 블록을 아래부터 빼낸다 (앞 줄 번호가 안 바뀌게). 빠진 자리 앞뒤 빈 줄은 하나만.
        var units: [[String]] = []
        for key in current.servers(in: back).map(\.key).reversed() {
            guard let range = unitRange(key, in: all) else {
                throw ConfigError(problem: "'\(key)' 블록 헤더를 찾지 못했습니다.", fix: "servers.conf 에서 직접 옮기세요.", reference: reference)
            }
            units.insert(Array(all[range]), at: 0)
            all.removeSubrange(range)
            let at = range.lowerBound
            if at < all.count, all[at].trimmingCharacters(in: .whitespaces).isEmpty,
               at == 0 || all[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                all.remove(at: at)
            }
        }
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
        guard let firstFront = current.servers(in: front).first, let target = unitRange(firstFront.key, in: all) else {
            throw ConfigError(problem: "'\(front)' 그룹의 첫 블록을 찾지 못했습니다.", fix: "servers.conf 에서 직접 옮기세요.", reference: reference)
        }
        // 앞 줄이 빈 줄이 아니면(블록이 빈 줄 없이 붙어 있던 파일) 하나 띄운다
        let lead = target.lowerBound > 0 && !all[target.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty ? [""] : []
        all.insert(contentsOf: lead + units.flatMap { $0 + [""] }, at: target.lowerBound)
        let joined = all.joined(separator: "\n") + "\n"
        _ = try ServerConfigParser.parse(joined, reference: reference)
        return joined
    }
}
