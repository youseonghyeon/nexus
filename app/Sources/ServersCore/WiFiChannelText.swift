// Wi-Fi 채널 글자 "36 (5GHz, 80MHz)" (WiFiMonitor 가 CoreWLAN 값으로 만든다) → 채널 · 대역 · 폭.
// 링크 타일 아래 줄은 괄호 안을 " · " 로 이어 "5GHz · 80MHz".

import Foundation

public struct WiFiChannelText: Sendable, Equatable {
    /// 괄호 앞 ("36")
    public let number: String
    /// 괄호 안을 ", " 로 나눈 것 (["5GHz", "80MHz"])
    public let details: [String]

    /// "5GHz" (CoreWLAN 이 모르면 "?")
    public var band: String? { details.first }
    /// "80MHz"
    public var width: String? { details.count > 1 ? details[1] : nil }
    /// 링크 타일 아래 줄: "5GHz · 80MHz"
    public var caption: String { details.joined(separator: " · ") }

    /// 괄호가 없으면 nil
    public static func parse(_ text: String) -> WiFiChannelText? {
        guard let open = text.firstIndex(of: "(") else { return nil }
        let inner = text[text.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ")"))
        return WiFiChannelText(number: text[..<open].trimmingCharacters(in: .whitespaces), details: inner.components(separatedBy: ", "))
    }
}
