// 기간·바이트를 화면 글로. 꼴이 여럿인 것은 화면마다 쓰임이 달라서다 — 새 화면은 여기서 고른다.
// 화면별 이름(ServicesFormat.duration · SystemVPNs.duration · SystemFormat.uptime·bytes · DiskFormat.bytes)은 이리로 넘긴다.
// 따로 둔 것: scp 진행률의 크기(TransferMeter.format — ByteCountFormatter) · Windows 디스크·VRAM 용량(RemoteInfo — 제조사 표기대로 정수 GB).

import Foundation

public enum DurationFormat {
    /// 큰 단위 둘까지, 0 인 둘째 단위는 뺀다: "220일" · "3일 1시간" · "1일 14시간" · "5분" · "10초"
    public static func compact(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86400, hours = total % 86400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return hours > 0 ? "\(days)일 \(hours)시간" : "\(days)일" }
        if hours > 0 { return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간" }
        if minutes > 0 { return "\(minutes)분" }
        return "\(total)초"
    }

    /// 늘 두 단위, 초까지: "25분 47초" · "3시간 2분" · "2일 4시간"
    public static func withSeconds(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = seconds % 86_400 / 3600, m = seconds % 3600 / 60, s = seconds % 60
        if d > 0 { return "\(d)일 \(h)시간" }
        if h > 0 { return "\(h)시간 \(m)분" }
        if m > 0 { return "\(m)분 \(s)초" }
        return "\(s)초"
    }

    /// 분까지 세 단위: "2일 3시간 4분" · "3시간 4분" · "4분"
    public static func full(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86400, hours = total % 86400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days)일 \(hours)시간 \(minutes)분" }
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        return "\(minutes)분"
    }
}

public enum ByteFormat {
    /// 2진 단위 (stats.zsh 와 같다): GiB·TiB 는 소수 한 자리, MiB·KiB 는 정수
    public static func binary(_ value: UInt64) -> String {
        let v = Double(value)
        switch value {
        case (1 << 40)...: return String(format: "%.1f TiB", v / 1_099_511_627_776)
        case (1 << 30)...: return String(format: "%.1f GiB", v / 1_073_741_824)
        case (1 << 20)...: return String(format: "%.0f MiB", v / 1_048_576)
        case (1 << 10)...: return String(format: "%.0f KiB", v / 1024)
        default: return "\(value) B"
        }
    }

    /// 10진 단위: 100 이상은 정수, 그 아래는 소수 한 자리
    public static func decimal(_ value: Double) -> String {
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        for (scale, unit) in units where value >= scale {
            let v = value / scale
            return v >= 100 ? String(format: "%.0f %@", v, unit) : String(format: "%.1f %@", v, unit)
        }
        return String(format: "%.0f B", value)
    }
}
