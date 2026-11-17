// 패킷 캡처 화면의 판정·글자: 시간 표기 · DNS 결과와 실패 · 대화의 두 끝 순서 · 내용 없는 ACK.
// 색(CaptureText.tone)·시각 표기(clock)는 화면에 둔다.

import Foundation

public enum CaptureFormat {
    /// 0.42 ms · 12.3 ms · 1.25 s
    public static func ms(_ seconds: Double) -> String {
        seconds < 0.001 ? String(format: "%.2f ms", seconds * 1000) : seconds < 1 ? String(format: "%.1f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}

extension DNSTransaction {
    /// 물은 뒤 이만큼(초) 넘게 답이 없으면 응답 없음
    public static let noResponseAfter: Double = 2

    /// 답이 없고 마지막 패킷 시각(now)이 물은 뒤 noResponseAfter 를 넘었다. now 를 모르면 아니다
    private func timedOut(now: Double?) -> Bool {
        now.map { $0 - asked > Self.noResponseAfter } ?? false
    }

    /// 요약 카드 한 줄: 오류 코드 → 답(앞 둘)·걸린 시간 → 응답 없음 → 기다리는 중, 끝에 물은 서버
    public func resultText(now: Double?) -> String {
        if let rcode, rcode != 0 { return "\(DNSMessage.rcodeName(rcode)) · \(server)" }
        if let latency { return (answers.isEmpty ? "답 없음" : answers.prefix(2).joined(separator: ", ")) + " · \(CaptureFormat.ms(latency)) · \(server)" }
        if timedOut(now: now) { return "응답 없음 · \(server)" }
        return "기다리는 중 · \(server)"
    }

    /// 실패(경고색): 오류 코드가 0 이 아니거나, 답 없이 noResponseAfter 를 넘김
    public func isFailed(now: Double?) -> Bool {
        if let rcode { return rcode != 0 }
        return latency == nil && timedOut(now: now)
    }
}

extension Conversation {
    /// (상대, 내 쪽) — 내 주소(local)가 붙은 끝을 뒤로. 둘 다 내 주소거나 둘 다 아니면 a, b 그대로
    public func ends(local: Set<String>) -> (remote: String, local: String) {
        let aLocal = local.contains(CaptureEndpoint.parts(a).host), bLocal = local.contains(CaptureEndpoint.parts(b).host)
        return aLocal && !bLocal ? (b, a) : (a, b)
    }
}

extension CaptureRow {
    /// 내용 없는 ACK (문제 표시 없음) — 목록에서 옅게
    public var isBareACK: Bool {
        decoded.tcp.map { $0.payloadLength == 0 && $0.flags == [.ack] && issue == nil } ?? false
    }
}
