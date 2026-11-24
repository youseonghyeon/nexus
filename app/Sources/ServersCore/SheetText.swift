// 터널 정보 창 · 전송 목록 행 · 전송 정보 창의 문구와 진행 판정. 화면(TunnelSheets · TransferViews)과 TransferSession 에 있던 것을 그대로 옮긴 것.

import Foundation

// MARK: 터널 정보 창

extension TunnelSpec {
    /// 창 제목: 입력창과 같은 말 ("web-01 포트 터널")
    public var sheetHeading: String {
        switch kind {
        case .port: return "\(server.key) 포트 터널"
        case .db: return "\(server.key) DB 터널"
        case .socks: return "\(server.key) 프록시 터널"
        }
    }

    /// 오른쪽 칸의 이름: 서버 자신의 포트면 "…에서", 서버를 거쳐 다른 곳이면 "…경유"
    public var remoteTitle: String {
        if case .port = kind { return "\(server.key) 에서" }
        return "\(server.key) 경유"
    }

    /// 오른쪽 칸의 주소: 원격 대상 (SOCKS 는 정해진 대상이 없다)
    public var remoteAddress: String {
        switch kind {
        case let .port(remote, host): return "\(host):\(remote)"
        case let .db(host, port, _): return "\(host):\(port)"
        case .socks: return "모든 주소 (SOCKS5)"
        }
    }

    /// 붙여 쓰는 주소: SOCKS 면 프록시 URL, 아니면 호스트:포트 (이름 붙인 터널은 그 이름)
    public var primaryAddress: String {
        if case .socks = kind { return "socks5://\(localHost):\(localPort)" }
        return "\(localHost):\(localPort)"
    }

    /// DB 터널의 복사용 값 (DB 이름을 모르면 "<db>"). DB 터널이 아니면 nil
    public var dbConnection: (name: String, jdbc: String, psql: String)? {
        guard case let .db(_, _, name) = kind else { return nil }
        let db = name ?? "<db>"
        return (db, "jdbc:postgresql://\(localHost):\(localPort)/\(db)",
                "psql \"postgresql://<user>:<password>@\(localHost):\(localPort)/\(db)\"")
    }
}

extension TunnelState {
    /// 터널 정보 창의 상태어 (사이드바 행의 StatusText.tunnelDetail 과 낱말이 다르다 — 창은 "열림 · 닫힘")
    public var sheetText: String {
        switch self {
        case .connecting: return "연결 중"
        case .open: return "열림"
        case .idle: return "지난번에 연 터널 · [다시 연결]로 엽니다"
        case .closed: return "닫힘"
        }
    }

    /// 연 뒤 지난 시간: "방금" · "12분 경과" · "2시간 5분 경과"
    public static func elapsedText(from start: Date, to now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(start) / 60)
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분 경과" }
        return "\(minutes / 60)시간 \(minutes % 60)분 경과"
    }
}

// MARK: 전송

extension TransferState {
    /// 막대 값 0...1. 전체 크기를 알면 전체 기준. 모르면 파일이 하나일 때만 그 파일 기준, 여러 개면 nil (움직이는 막대).
    public func fraction(meter: TransferMeter) -> Double? {
        guard case let .running(progress) = self, let progress else { return nil }
        if let overall = meter.fraction { return overall }
        return meter.fileCount <= 1 ? Double(progress.percent) / 100 : nil
    }

    /// 진행 중 한 줄 (파일 이름 없이): "45% · 1.2 GB / 2.7 GB · 10MB/s · 12번째 파일".
    /// 전체 크기를 모르는 여러 파일이면 "12번째 파일 · 45% · 10MB/s".
    public func progressText(meter: TransferMeter) -> String? {
        guard case let .running(progress) = self, let progress else { return nil }
        let many = meter.fileCount > 1
        if many, meter.fraction == nil {
            return "\(meter.fileCount)번째 파일 · \(progress.percent)% · \(progress.rate)"
        }
        var parts: [String] = []
        if let fraction = fraction(meter: meter) { parts.append("\(Int(fraction * 100))%") }
        if let total = meter.totalBytes, meter.fraction != nil {
            parts.append("\(TransferMeter.format(meter.doneBytes)) / \(TransferMeter.format(total))")
        } else {
            parts.append(progress.transferred)
        }
        parts.append(progress.rate)
        parts.append(many ? "\(meter.fileCount)번째 파일" : progress.eta)   // scp 의 남은 시간은 파일 기준이라 여러 파일이면 뺀다
        return parts.joined(separator: " · ")
    }

    /// 사이드바 전송 행의 아래 줄
    public func rowDetail(meter: TransferMeter) -> String {
        switch self {
        case .running: return progressText(meter: meter) ?? "연결 중…"
        case .done: return "완료"
        case .cancelled: return "취소됨"
        case let .failed(code, message): return "실패 (exit \(code)) · \(message.split(separator: "\n").last ?? "")"
        }
    }

    /// 전송 정보 창의 머리 상태
    public func sheetTitle(meter: TransferMeter) -> String {
        switch self {
        case let .running(progress):
            guard progress != nil else { return "연결 중…" }
            return fraction(meter: meter).map { "전송 중 · \(Int($0 * 100))%" } ?? "전송 중"
        case .done: return "완료"
        case .cancelled: return "취소됨"
        case let .failed(code, _): return "실패 · exit \(code)"
        }
    }
}
