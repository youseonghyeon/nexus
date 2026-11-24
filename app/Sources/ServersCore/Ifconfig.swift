// `ifconfig` 출력을 장치 덩이로 나눈다: 들여쓰기 없이 콜론이 있는 줄("en8: flags=…")이 장치 줄, 그 아래 줄들이 그 장치의 내용.
// 무엇을 고르는지는 쓰는 곳이 정한다 — Ethernet.parseInterfaces(MAC · 주소 · 마스크 · 링크) · LocalCommands.parseInterfaceAddresses(lo0 뺀 주소 전부) ·
// RouteTable.parseInterfaceDetails(첫 주소 · MTU).

import Foundation

enum Ifconfig {
    struct Block {
        /// 장치 이름 (장치 줄의 첫 콜론 앞). 장치 줄보다 먼저 나온 줄들의 덩이는 빈 이름
        let device: String
        /// 장치 줄 원문. 장치 줄보다 먼저 나온 줄들의 덩이는 nil
        let header: String?
        /// 내용 줄 (앞뒤 공백을 뗀 것)
        var lines: [String] = []

        /// "inet 192.0.2.10 netmask …" 줄들의 주소 (나온 순서)
        var inetAddresses: [String] {
            lines.compactMap { line in
                guard line.hasPrefix("inet ") else { return nil }
                let parts = line.split(separator: " ")
                return parts.count >= 2 ? String(parts[1]) : nil
            }
        }
    }

    /// 나온 순서대로. 같은 이름의 장치 줄이 다시 나오면 덩이도 따로다.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        for raw in text.split(separator: "\n") {
            if !raw.hasPrefix("\t"), !raw.hasPrefix(" "), let colon = raw.firstIndex(of: ":") {
                out.append(Block(device: String(raw[..<colon]), header: String(raw)))
                continue
            }
            if out.isEmpty { out.append(Block(device: "", header: nil)) }
            out[out.count - 1].lines.append(raw.trimmingCharacters(in: .whitespaces))
        }
        return out
    }
}
