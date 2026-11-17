// 패킷 목록 표의 행 자리. 표는 행을 패킷 번호가 아니라 자리(0 = 맨 위)로 구분한다 —
// 새 패킷이 위에 들어와도 표가 행을 끼워 넣고 빼는 대신 내용만 바꾼다
// (번호로 구분하면 갱신마다 보이는 행 전체가 밀려났다: 초당 60 패킷에서 CPU 25% → 13%, 2026-11-16 측정).
// 선택·오른쪽 클릭·스크롤은 표가 자리로 주고받으므로 여기서 패킷 번호와 바꾼다.

import Foundation

/// 표의 한 줄: 자리(id)와 거기 놓인 패킷
public struct CaptureSlot: Identifiable, Equatable, Sendable {
    public let id: Int
    public let row: CaptureRow
}

/// 최근 것이 위인 행 목록(번호 내림차순 — `CaptureSnapshot.visible`)을 자리로 읽는다
public struct CaptureSlots: RandomAccessCollection, Sendable {
    public let rows: [CaptureRow]

    public init(_ rows: [CaptureRow]) {
        self.rows = rows
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { rows.count }

    public subscript(position: Int) -> CaptureSlot {
        CaptureSlot(id: position, row: rows[position])
    }

    /// 그 자리의 행. 목록 밖이면 없다
    public func row(at position: Int?) -> CaptureRow? {
        guard let position, rows.indices.contains(position) else { return nil }
        return rows[position]
    }

    /// 그 번호의 패킷이 놓인 자리. 목록에 없으면(밀려났거나 걸러졌으면) 없다
    public func position(ofPacket id: Int?) -> Int? {
        guard let id else { return nil }
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].id == id { return mid }
            if rows[mid].id > id { low = mid + 1 } else { high = mid }
        }
        return nil
    }
}
