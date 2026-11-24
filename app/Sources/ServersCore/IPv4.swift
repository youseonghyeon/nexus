// IPv4 주소 풀이와 대역 계산. 받는 꼴이 쓰는 곳마다 달라 진입점이 둘이다 — 값으로 푸는 엄격한 parse 와 꼴만 보는 느슨한 isDotted.
// 여기로 모으지 않은 것(받는 꼴이 또 달라서): IPv4Prefix.parse(ip route 출력) · NetworkInfoFetcher.prefixLength 의 칸 읽기 ·
// PowerWatch.sameSubnet24 · OpenWrt.ipSortKey · 루프백 판정 둘(BrowserPolicy · ServicesFormat).

import Foundation

public enum IPv4 {
    /// "10.50.10.17" → 32비트 값. 형식이 틀리면 nil (앞자리 0 거부)
    public static func parse(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            // 앞자리 0(010) 은 받지 않는다 — inet_aton 계열은 8진수로 읽어 다른 주소가 된다
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.count == 1 || part.first != "0",
                  let n = UInt32(part), n <= 255 else { return nil }
            value = value << 8 | n
        }
        return value
    }

    /// 32비트 값 → "10.50.10.17" (parse 의 반대)
    public static func dotted(_ value: UInt32) -> String {
        (0..<4).map { String((value >> (24 - 8 * UInt32($0))) & 0xFF) }.joined(separator: ".")
    }

    /// 숫자 칸 넷(칸마다 1~3자리, 0~255)인가 — 앞자리 0 도 받는다. 사람이 친 글이 주소 꼴인지만 볼 때 (브라우저 주소창 · 터널 대상).
    public static func isDotted(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy { $0.isASCII && $0.isNumber } && (Int(p) ?? 999) <= 255
        }
    }

    /// 접두사 길이(0~32) → 마스크: 24 → 0xFFFFFF00. 범위 밖은 끝값으로 (음수 → 0, 32 초과 → 전부 1) — 거르지 않고 불러도 죽지 않게
    public static func mask(prefix: Int) -> UInt32 {
        let bits = max(0, min(32, prefix))
        return bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
    }

    /// 마스크 → 접두사 길이: 0xFFFFFF00 → 24. 연속된 1 비트가 아니면 nil.
    public static func prefixLength(mask bits: UInt32) -> Int? {
        let ones = bits.nonzeroBitCount
        guard ones == 0 || bits == (UInt32.max << (32 - ones)) else { return nil }
        return ones
    }
}
