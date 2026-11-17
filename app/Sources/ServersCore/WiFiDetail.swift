// Wi-Fi 상세 (루트 필요): `sudo wdutil info` 의 WIFI 구역에서 CoreWLAN 이 일반 권한으로 주지 않는 값만 읽는다.
// SSID·BSSID·MAC 은 sudo 로도 <redacted> 라 쓰지 않는다 (2026-10-14 실제 출력). 채널·신호·전송 속도는 CoreWLAN 쪽 값을 그대로 쓴다.
// 인증은 내부망 토글과 같은 길 (LanCommands.privilegedScript — Touch ID 시트 → 안 되면 암호 창). sudo 자격이 남지 않아 누를 때마다 한 번.

import Foundation

public struct WiFiDetail: Sendable, Equatable {
    /// 채널 혼잡도 % (CCA)
    public var cca: Int?
    public var mcs: Int?
    /// 공간 스트림 수 (NSS)
    public var nss: Int?
    /// ns
    public var guardInterval: Int?
    public var countryCode: String?
    public var fetchedAt: Date

    public init(cca: Int? = nil, mcs: Int? = nil, nss: Int? = nil, guardInterval: Int? = nil, countryCode: String? = nil, fetchedAt: Date = Date()) {
        self.cca = cca; self.mcs = mcs; self.nss = nss; self.guardInterval = guardInterval; self.countryCode = countryCode; self.fetchedAt = fetchedAt
    }

    /// 읽은 값이 하나도 없으면 실패로 본다 (WIFI 구역이 없거나 꺼짐)
    public var isEmpty: Bool { cca == nil && mcs == nil && nss == nil && guardInterval == nil && countryCode == nil }

    /// root 로 wdutil info 를 돌리는 zsh 스크립트. 취소하면 LanCommands.authFailedExitCode.
    public static let script = LanCommands.privilegedScript(body: "sudo /usr/bin/wdutil info", prompt: "Wi-Fi 상세 보기")

    /// `wdutil info` 전체 출력 → WIFI 구역의 값. 구역 머리는 "————" 줄 사이의 대문자 한 줄.
    public static func parse(_ text: String, at date: Date = Date()) -> WiFiDetail {
        var detail = WiFiDetail(fetchedAt: date)
        var section = ""
        var previousWasRule = false
        // 줄 나눔은 \n·\r 모두: 암호 창 경로(osascript do shell script)는 줄 끝을 \r 로 바꿔 돌려준다
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("—") || line.hasPrefix("---") { previousWasRule = true; continue }
            if previousWasRule, !line.isEmpty, !line.contains(":") { section = line; previousWasRule = false; continue }
            previousWasRule = false
            guard section == "WIFI", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != "None", value != "n/a" else { continue }
            let number = Int(value.prefix { $0.isNumber })
            switch key {
            case "CCA": detail.cca = number
            case "MCS Index": detail.mcs = number
            case "NSS": detail.nss = number
            case "Guard Interval": detail.guardInterval = number
            case "Country Code": detail.countryCode = value
            default: break
            }
        }
        return detail
    }
}
