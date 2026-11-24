// 서버 추가·편집 창의 확인 상태([포트 확인] · [Ping])와 안내 문구. 보낼 수 있는가의 판정은 ActionAvailability.swift 의 ServerFormCheck.

import Foundation

extension ServerFormCheck {
    /// [포트 확인] 결과: 응답(걸린 ms) / 응답 없음
    public enum PortResult: Sendable, Equatable {
        case idle, checking, open(Int), closed

        /// 창 아래 한 줄 ("192.0.2.10:22 응답 있음 · 3ms"). 확인 전엔 nil. ip·port 는 입력칸 글자 그대로(앞뒤 공백만 뗀다)
        public func text(ip: String, port: String) -> String? {
            let target = "\(ip.trimmingCharacters(in: .whitespaces)):\(port.trimmingCharacters(in: .whitespaces))"
            switch self {
            case .idle: return nil
            case .checking: return "\(target) 확인 중…"
            case let .open(ms): return "\(target) 응답 있음 · \(ms)ms"
            case .closed: return "\(target) 응답이 없습니다"
            }
        }

        /// 칸 옆 글자 (짧게)
        public var resultText: String? {
            switch self {
            case let .open(ms): return "\(ms)ms"
            case .closed: return "응답 없음"
            default: return nil
            }
        }
    }

    /// [Ping] 결과: 응답(평균 ms · 손실 %) / 응답 없음
    public enum PingResult: Sendable, Equatable {
        case idle, checking, replied(ms: Int, loss: Int), none

        /// ping 요약 → 결과. 응답이 하나도 없으면(평균이 없으면 · 재지 못했으면) none
        public static func of(_ summary: PingSummary?) -> PingResult {
            guard let summary, let average = summary.averageMs else { return .none }
            return .replied(ms: Int(average.rounded()), loss: Int(summary.lossPercent.rounded()))
        }

        /// 일부 손실 (칸 옆 글자를 노랑으로)
        public var hasLoss: Bool {
            if case let .replied(_, loss) = self { return loss > 0 }
            return false
        }

        /// 칸 옆 글자는 짧게 (ms, 일부 손실이면 노랑) — 손실 % 는 그림에 마우스를 올리면
        public var resultText: String? {
            switch self {
            case let .replied(ms, _): return "\(ms)ms"
            case .none: return "응답 없음"
            default: return nil
            }
        }

        /// 창 아래 한 줄. ping 전엔 nil
        public func text(ip: String) -> String? {
            let target = ip.trimmingCharacters(in: .whitespaces)
            switch self {
            case .idle: return nil
            case .checking: return "\(target) ping 중…"
            case let .replied(ms, loss): return "\(target) 응답 있음 · 평균 \(ms)ms · 손실 \(loss)%"
            case .none: return "\(target) ping 응답이 없습니다"
            }
        }
    }

    /// 포트 칸의 글자 → 번호 (1…65535 만)
    public static func portNumber(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    /// 채워야 할 칸 (버튼이 꺼진 이유 — 경고가 아니라 안내). 순서는 안내 문구에 적히는 순서.
    /// lanServiceMissing: 내부망 서비스를 골라야 하는데 안 골랐다
    public static func missingFields(key: String, lanServiceMissing: Bool, ip: String, user: String, group: String) -> [String] {
        var out: [String] = []
        if key.isEmpty { out.append("이름") }
        if lanServiceMissing { out.append("서비스") }
        if ip.isEmpty { out.append("IP") }
        if user.isEmpty { out.append("사용자") }
        if group.trimmingCharacters(in: .whitespaces).isEmpty { out.append("그룹") }   // 빈 목록의 [서버 추가]는 그룹 없이 열린다
        return out
    }

    /// "이름·IP를 채우면 추가할 수 있습니다". 조사는 마지막 칸 이름에 맞춘다 (이름을 · 그룹을 · IP를 · 사용자를 · 서비스를). 다 채웠으면 nil
    public static func missingHint(_ missing: [String], adding: Bool) -> String? {
        guard let last = missing.last else { return nil }
        return "\(missing.joined(separator: "·"))\(["이름", "그룹"].contains(last) ? "을" : "를") 채우면 \(adding ? "추가" : "저장")할 수 있습니다"
    }

    /// 이름을 바꾸면 닫히는 탭·터널 안내 (열린 게 없으면 nil)
    public static func renameClosesText(tabs: Int, tunnels: Int) -> String? {
        let parts = (tabs > 0 ? ["열린 탭 \(tabs)개"] : []) + (tunnels > 0 ? ["터널 \(tunnels)개"] : [])
        return parts.isEmpty ? nil : "이름을 바꾸면 \(parts.joined(separator: "·"))가 닫힙니다"
    }
}
