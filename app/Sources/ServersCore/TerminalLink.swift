// 터미널에서 ⌘+클릭으로 링크 열기 (2026-11-15). Ghostty 도 ⌘+클릭 링크가 있지만 두 경우에 안 열렸다:
// 원격 프로그램이 마우스를 잡고 있으면(Claude Code·tmux mouse on·vim) 클릭이 그 프로그램으로 가고(⌘⇧+클릭만 됨),
// 프로그램이 화면 폭에 맞춰 직접 꺾어 찍은 URL(Claude Code 로그인 주소)은 첫 줄까지만 잘려 열렸다.
// 그래서 앱이 ⌘+클릭을 먼저 받아(TerminalDropView) 보이는 화면 글자에서 누른 칸의 URL 을 찾는다. 없으면 Ghostty 기본 동작으로 넘긴다.
// 줄 잇기: 마지막 칸까지 URL 글자로 찬 줄 + 첫 칸이 URL 글자인 다음 줄. 여는 것은 http·https 만 — 서버가 찍은 다른 스킴은 열지 않는다.

import Foundation

public enum TerminalLink {
    /// 누른 칸의 URL. rows 는 보이는 화면의 줄(위 → 아래, 줄 끝 공백은 없어도 됨), columns 는 화면 칸 수, row·column 은 0 부터.
    public static func url(rows: [String], columns: Int, row: Int, column: Int) -> String? {
        guard columns > 0, rows.indices.contains(row), (0..<columns).contains(column) else { return nil }
        let grid = rows.map { cells($0, columns: columns) }
        // 누른 줄에서 위·아래로 이어지는 줄을 붙여 한 줄로
        var first = row, last = row
        while first > 0, continues(grid[first - 1], into: grid[first]) { first -= 1 }
        while last < grid.count - 1, continues(grid[last], into: grid[last + 1]) { last += 1 }
        let line = Array(grid[first...last].joined())
        let index = (row - first) * columns + column
        guard isURLCharacter(line[index]) else { return nil }
        // 누른 칸을 품은 덩어리 (공백·URL 에 못 쓰는 글자에서 끊김)
        var start = index, end = index
        while start > 0, isURLCharacter(line[start - 1]) { start -= 1 }
        while end < line.count - 1, isURLCharacter(line[end + 1]) { end += 1 }
        let token = String(line[start...end].compactMap { $0 })
        // 덩어리 안 첫 스킴부터가 URL — "(https://…" 의 괄호나 앞줄에서 이어 붙은 글자는 뺀다
        guard let scheme = token.range(of: "https?://", options: .regularExpression) else { return nil }
        let link = trimmed(String(token[scheme.lowerBound...]))
        let offset = index - start - token.distance(from: token.startIndex, to: scheme.lowerBound)
        guard offset >= 0, offset < link.count, let parsed = URL(string: link), parsed.host?.isEmpty == false else { return nil }
        return link
    }

    /// 뷰 안의 점(왼쪽 위 기준, 포인트) → 칸. 글자 칸 밖(여백)이면 nil.
    public static func cell(x: Double, y: Double, paddingX: Double, paddingY: Double, cellWidth: Double, cellHeight: Double,
                            columns: Int, rows: Int) -> (row: Int, column: Int)? {
        guard cellWidth > 0, cellHeight > 0, x >= paddingX, y >= paddingY else { return nil }
        let column = Int((x - paddingX) / cellWidth), row = Int((y - paddingY) / cellHeight)
        return column < columns && row < rows ? (row, column) : nil
    }

    // MARK: 줄 → 칸

    /// 줄을 칸 배열로 (넓은 글자는 두 칸 — 둘째 칸은 nil, 모자란 칸은 공백)
    static func cells(_ text: String, columns: Int) -> [Character?] {
        var cells: [Character?] = []
        for character in text {
            cells.append(character)
            if isWide(character) { cells.append(nil) }
        }
        if cells.count < columns { cells.append(contentsOf: repeatElement(" ", count: columns - cells.count)) }
        return Array(cells.prefix(columns))
    }

    private static func continues(_ row: [Character?], into next: [Character?]) -> Bool {
        isURLCharacter(row.last ?? " ") && isURLCharacter(next.first ?? " ")
    }

    /// URL 에 쓰는 글자: 공백·따옴표·꺾쇠 등을 뺀 ASCII. 한글·선 문자(│)는 URL 을 끊는다.
    private static func isURLCharacter(_ character: Character?) -> Bool {
        guard let character, let ascii = character.asciiValue, ascii > 0x20, ascii < 0x7F else { return false }
        return !"\"<>\\^`{|}".contains(character)
    }

    /// 문장 부호로 끝나면 뺀다 ("…/x." · "(…/x)"). 닫는 괄호는 짝이 URL 안에 있으면 둔다 (위키 주소의 "_(b)").
    private static func trimmed(_ link: String) -> String {
        var link = link
        while let last = link.last {
            if ".,;:!?'".contains(last) { link.removeLast(); continue }
            if let open = [")": "(", "]": "["][String(last)],
               link.filter({ String($0) == open }).count < link.filter({ $0 == last }).count { link.removeLast(); continue }
            break
        }
        return link
    }

    /// 두 칸을 쓰는 글자 (한글·한자·가나·전각·이모지) — 줄의 칸 위치를 맞추는 데만 쓴다
    private static func isWide(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD: return true
        default: return false
        }
    }
}
