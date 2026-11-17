// 탭 목록 관리의 순수 로직. UI 없이 테스트한다.
//   탭은 소유자(서버 키 또는 로컬)에 속하고, 닫을 때 다음 활성 탭은 같은 소유자 안에서 고른다.

import Foundation

public struct TabRef<ID: Hashable & Sendable>: Sendable, Equatable {
    public let id: ID
    public let owner: String
    public init(id: ID, owner: String) {
        self.id = id
        self.owner = owner
    }
}

public enum TabSelection {
    /// `closing` 을 닫은 뒤 활성으로 삼을 탭. 같은 소유자의 오른쪽 이웃 → 왼쪽 이웃 → nil.
    public static func nextActive<ID>(after closing: ID, in tabs: [TabRef<ID>]) -> ID? {
        guard let index = tabs.firstIndex(where: { $0.id == closing }) else { return nil }
        let owner = tabs[index].owner
        if let right = tabs[(index + 1)...].first(where: { $0.owner == owner }) { return right.id }
        if let left = tabs[..<index].last(where: { $0.owner == owner }) { return left.id }
        return nil
    }

    /// 그 소유자의 마지막 탭. 기억한 탭이 없을 때 `activeTab` 의 대체값.
    public static func lastTab<ID>(of owner: String, in tabs: [TabRef<ID>]) -> ID? {
        tabs.last(where: { $0.owner == owner })?.id
    }

    /// 그 소유자로 돌아왔을 때 활성으로 삼을 탭: `remembered` 에 적힌 마지막으로 보던 탭.
    /// 기억이 없거나 그 탭이 이미 닫혔으면 그 소유자의 마지막 탭.
    public static func activeTab<ID>(of owner: String, remembered: [String: ID], in tabs: [TabRef<ID>]) -> ID? {
        if let id = remembered[owner], tabs.contains(where: { $0.id == id && $0.owner == owner }) { return id }
        return lastTab(of: owner, in: tabs)
    }

    /// ⌘⇧[ / ⌘⇧] : 탭 막대 순서(Dashboard → 그 소유자의 탭들)에서 한 칸 옆. 양 끝에서는 반대쪽 끝으로 돈다.
    /// `current` 가 nil 이면 Dashboard 를 보는 중. 결과도 nil 이면 Dashboard. 그 소유자의 탭이 없으면(막대가 없으면) 옮기지 않는다 → `.stay`.
    public enum Step<ID: Equatable>: Equatable {
        case dashboard
        case tab(ID)
        case stay
    }

    public static func step<ID>(from current: ID?, owner: String, forward: Bool, in tabs: [TabRef<ID>]) -> Step<ID> {
        let ids = tabs.filter { $0.owner == owner }.map(\.id)
        guard !ids.isEmpty else { return .stay }
        let order: [ID?] = [nil] + ids
        let index = current.flatMap { id in order.firstIndex(where: { $0 == id }) } ?? 0
        let next = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        return next.map { .tab($0) } ?? .dashboard
    }

    /// 드래그로 순서 바꾸기: `moving` 을 같은 소유자 탭들 안 `index` 번째로. 다른 소유자 탭의 자리는 그대로.
    /// index 는 0…(그 소유자 탭 수 - 1) 로 맞춘다. 없는 탭이면 원본 그대로. (Dashboard 는 탭 배열에 없고 화면에서 맨 앞 고정이라 여기 관여하지 않는다.)
    public static func move<ID>(_ moving: ID, to index: Int, in tabs: [TabRef<ID>]) -> [TabRef<ID>] {
        guard let from = tabs.firstIndex(where: { $0.id == moving }) else { return tabs }
        let owner = tabs[from].owner
        let slots = tabs.indices.filter { tabs[$0].owner == owner }
        var mine = slots.map { tabs[$0] }
        let item = mine.remove(at: slots.firstIndex(of: from) ?? 0)   // from 은 slots 안에 있다
        mine.insert(item, at: min(max(index, 0), mine.count))
        var out = tabs
        for (slot, tab) in zip(slots, mine) { out[slot] = tab }
        return out
    }
}

/// 탭 막대 안에서 끌기 (Safari·Chrome 처럼 막대 밖으로 안 나가고 좌우로만, 이웃이 비켜난다). 화면은 이 값만 그린다.
///   자리: 지금 순서의 폭들로 계산한다 (잰 좌표는 순서를 바꾼 뒤 한 박자 늦어 튀거나 왔다 갔다 한다).
///   보이는 위치: 시작 자리 + 끈 거리 — 순서와 무관해 자리가 바뀌어도 커서에 붙어 있다. 첫 탭 앞·마지막 탭 뒤로는 안 나간다.
///   자리 바꾸기: 움직이는 쪽 끝(오른쪽으로 끌면 오른쪽 끝, 왼쪽이면 왼쪽 끝)이 이웃 중심을 넘으면.
///     중심끼리 비교하면 넓은 탭이 작은 탭 중심에 닿지 못해(끝 제한) 넘어가지 못했다 (2026-10-06).
public struct TabDrag: Equatable, Sendable {
    /// 첫 탭 왼쪽 끝 (끌기 중엔 안 바뀐다)
    public let base: Double
    /// 끌기 시작할 때 끄는 탭 왼쪽 끝
    public let startMinX: Double
    /// 탭 사이 간격
    public let spacing: Double
    public var translation: Double = 0

    public init(base: Double, startMinX: Double, spacing: Double) {
        self.base = base
        self.startMinX = startMinX
        self.spacing = spacing
    }

    /// 지금 순서에서 탭마다 자리
    public static func layout(widths: [Double], base: Double, spacing: Double) -> [ClosedRange<Double>] {
        var x = base
        return widths.map { width in
            defer { x += width + spacing }
            return x...(x + width)
        }
    }

    /// 끄는 탭이 보일 왼쪽 끝 (index: 지금 순서에서 끄는 탭 순번)
    public func visualMinX(widths: [Double], index: Int) -> Double {
        let end = Self.layout(widths: widths, base: base, spacing: spacing).last?.upperBound ?? base
        return min(max(startMinX + translation, base), max(base, end - widths[index]))
    }

    /// 끄는 탭을 레이아웃 자리에서 얼마나 옮겨 그릴지
    public func offset(widths: [Double], index: Int) -> Double {
        visualMinX(widths: widths, index: index) - Self.layout(widths: widths, base: base, spacing: spacing)[index].lowerBound
    }

    /// 놓은 자리가 탭 막대(0,0 … width,height) 안인가. 안이면 창 끌기를 끈 채 둔다 —
    /// 커서가 탭 위에 그대로라 호버 들어옴이 다시 오지 않아, 켜 두면 다음 끌기에 창이 움직였다 (2026-10-06).
    public static func releasedInside(x: Double, y: Double, width: Double, height: Double) -> Bool {
        x >= 0 && x <= width && y >= 0 && y <= height
    }

    /// 끄는 탭이 들어갈 순번 (지금 index 와 같으면 그대로)
    public func target(widths: [Double], index: Int) -> Int {
        let spans = Self.layout(widths: widths, base: base, spacing: spacing)
        let x = visualMinX(widths: widths, index: index)
        let probe = x > spans[index].lowerBound ? x + widths[index] : x
        return spans.indices.filter { $0 != index && (spans[$0].lowerBound + spans[$0].upperBound) / 2 < probe }.count
    }
}
