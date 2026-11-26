// 조회 결과 창(로그)의 줄 고르기: 한 줄을 누르고 끌면 그 사이 줄들이 통째로 골라지고, 놓으면 복사한다 (2026-11-26 사용자 — "영역 복사").
// 글자 단위가 아니라 줄 단위다 — 간단히 보는 창이라 화면(줄마다 그린 글자 · 띠 · 색)을 그대로 두기로 했다.
// 끌지 않고 누르기만 한 것은 "한 줄을 고른 것"이라 전처럼 그 줄이 복사된다. Shift 를 누른 채 누르면 앞서 누른 줄부터 그 줄까지 (화면 밖까지 길게 고를 때).
// 끌기는 화면에 그려진 줄 안에서만 — 끌면서 저절로 넘기지는 않는다. 화면 밖으로 나가면 그려진 맨 위 · 맨 아래 줄에서 멈춘다.
// 줄 번호는 결과의 원래 번호다. 걸러 보는 중(Error 만)이면 사이에 숨은 줄은 복사에서 빠진다 (text 의 shown).
// 마우스는 AI 가 조작해 볼 수 없어 판정을 전부 여기 두고 과정을 순서대로 흉내 내는 테스트로 본다 (LineSelectionTests). 화면은 값만 흘린다 (Sheets.swift).

import Foundation

public struct LineSelection: Equatable, Sendable {
    /// 처음 누른 줄 · 지금 끝 줄 (원래 줄 번호). 고른 것이 없으면 nil
    public private(set) var anchor: Int?
    public private(set) var focus: Int?
    /// 누르고 있는 중인가 (놓기 전)
    public private(set) var pressing = false

    public init() {}

    /// 고른 줄들 (처음 누른 줄과 끝 줄 사이 — 위로 끌어도 같다)
    public var range: ClosedRange<Int>? {
        guard let anchor, let focus else { return nil }
        return min(anchor, focus)...max(anchor, focus)
    }

    public func contains(_ line: Int) -> Bool { range?.contains(line) ?? false }

    /// 누름. extend(Shift)면 앞서 누른 줄에서 이 줄까지 — 앞서 누른 줄이 없으면 그냥 누름
    public mutating func press(_ line: Int, extend: Bool = false) {
        if !(extend && anchor != nil) { anchor = line }
        focus = line
        pressing = true
    }

    /// 누른 채 움직임. 누르고 있지 않으면 아무 일도 없다
    public mutating func drag(to line: Int) {
        guard pressing else { return }
        focus = line
    }

    /// 놓음 → 복사할 줄들. 고른 표시는 남는다 (무엇이 복사됐는지 보이게 · 다음 Shift 누름의 시작 줄). 누르고 있지 않았으면 nil
    public mutating func release() -> ClosedRange<Int>? {
        guard pressing else { return nil }
        pressing = false
        return range
    }

    /// 고른 것을 지운다 (걸러 보기를 바꿨을 때 — 숨은 줄에 표시가 남지 않게)
    public mutating func clear() { self = LineSelection() }

    /// 복사할 글: 범위 안의 보이는 줄을 줄바꿈으로 잇는다. 범위가 결과를 벗어나면 있는 줄까지만
    public static func text(lines: [String], range: ClosedRange<Int>, shown: (Int) -> Bool = { _ in true }) -> String {
        lines.indices.filter { range.contains($0) && shown($0) }.map { lines[$0] }.joined(separator: "\n")
    }
}

/// 마우스 자리(세로) → 줄. 화면에 그려진 줄들의 자리만 안다 (LazyVStack 은 보이는 줄만 만든다).
public enum LineHit {
    public struct Row: Equatable, Sendable {
        public let line: Int
        public let minY: Double
        public let maxY: Double
        public init(line: Int, minY: Double, maxY: Double) { self.line = line; self.minY = minY; self.maxY = maxY }
    }

    /// y 에 있는 줄. 그려진 줄들 위 · 아래로 벗어나면 맨 위 · 맨 아래 줄, 줄 사이 틈이면 가까운 줄. 그려진 줄이 없으면 nil.
    /// 줄의 아래 경계는 다음 줄 것이다 (minY ≤ y < maxY).
    public static func line(atY y: Double, rows: [Row]) -> Int? {
        let sorted = rows.sorted { $0.minY < $1.minY }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if y < first.minY { return first.line }
        if y >= last.maxY { return last.line }
        if let hit = sorted.first(where: { $0.minY <= y && y < $0.maxY }) { return hit.line }
        return sorted.min { distance(y, $0) < distance(y, $1) }?.line
    }

    private static func distance(_ y: Double, _ row: Row) -> Double {
        y < row.minY ? row.minY - y : max(0, y - row.maxY)
    }
}
