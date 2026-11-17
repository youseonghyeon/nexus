// 망 화면의 문턱: Wi-Fi 신호(RSSI) 단계 · 신호 막대 채움 · 응답 시간 단계. 색·글자 대응은 화면(SignalScale)에 둔다.

import Foundation

/// RSSI(dBm) 단계: -50 이상 매우 좋음 · -60 이상 좋음 · -70 이상 보통 · 그 아래 약함
public enum SignalGrade: Sendable, Equatable, CaseIterable {
    case excellent, good, fair, weak

    public init(rssi: Int) {
        switch rssi {
        case (-50)...: self = .excellent
        case (-60)...: self = .good
        case (-70)...: self = .fair
        default: self = .weak
        }
    }
}

/// 응답 시간(ms) 단계: 40 미만 빠름 · 120 미만 느림 · 그 이상(또는 NaN) 나쁨
public enum LatencyGrade: Sendable, Equatable, CaseIterable {
    case fast, slow, poor

    public init(ms: Double) {
        switch ms {
        case ..<40: self = .fast
        case ..<120: self = .slow
        default: self = .poor
        }
    }
}

/// Wi-Fi 신호 막대
public enum SignalMeter {
    /// RSSI(dBm) → 0...1 (-100 이하 0, -50 이상 1)
    public static func level(rssi: Int) -> Double {
        min(1, max(0, Double(rssi + 100) / 50))
    }

    /// 칠할 칸 수 (아래 칸부터). 칸 i(0부터)는 level 이 (i+1)/칸수 보다 0.12 모자라도 칠한다
    public static func filledBars(level: Double, bars: Int = 4) -> Int {
        (0..<max(0, bars)).filter { level >= Double($0 + 1) / Double(bars) - 0.12 }.count
    }
}
