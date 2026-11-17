// 이 Mac 의 /etc/hosts (LOCAL 화면 Hosts 카드, 읽기만). DNS 보다 먼저 이름을 푼다 — 같은 이름은 앞 줄이 이긴다.
// 앱이 넣은 줄(서버 이름 터널, lib/hosts.zsh)은 "# servers-app" 표식으로 가린다. 기본 줄(localhost·broadcasthost)은 뺀다.

import Foundation

public struct HostsEntry: Sendable, Equatable, Identifiable {
    public var id: Int { line }
    /// 파일의 몇째 줄 (1부터) — 같은 IP·이름 줄이 겹쳐도 구분
    public let line: Int
    public let address: String
    public let names: [String]
    /// "# servers-app" 표식 — 앱의 서버 이름 터널이 넣은 줄
    public let byApp: Bool
    /// 이 줄의 이름 중 앞 줄(같은 IPv4/IPv6)이 이미 가져가 이 줄로는 풀리지 않는 것
    public let shadowed: [String]

    public init(line: Int, address: String, names: [String], byApp: Bool, shadowed: [String] = []) {
        self.line = line
        self.address = address
        self.names = names
        self.byApp = byApp
        self.shadowed = shadowed
    }
}

public enum HostsFile {
    static let marker = "servers-app"
    /// macOS 기본 줄 — 어느 Mac 에나 있어 보여 줄 게 없다
    static let defaults: Set<String> = ["127.0.0.1 localhost", "255.255.255.255 broadcasthost", "::1 localhost", "fe80::1%lo0 localhost"]

    public static func parse(_ text: String) -> [HostsEntry] {
        var out: [HostsEntry] = []
        var taken: Set<String> = []   // "4 이름" · "6 이름" — 앞 줄이 가져간 이름 (대소문자 무시)
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let fields = (parts.first ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }
            let comment = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let address = fields[0], names = Array(fields.dropFirst())
            let family = address.contains(":") ? "6" : "4"
            let shadowed = names.filter { taken.contains("\(family) \($0.lowercased())") }
            names.forEach { taken.insert("\(family) \($0.lowercased())") }
            if names.allSatisfy({ defaults.contains("\(address) \($0)") }) { continue }
            out.append(HostsEntry(line: index + 1, address: address, names: names,
                                  byApp: comment.split(separator: " ").first == Substring(marker), shadowed: shadowed))
        }
        return out
    }

    /// 읽지 못하면 nil (화면은 "읽지 못했습니다")
    public static func read(path: String = "/etc/hosts") -> [HostsEntry]? {
        guard let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? (try? String(contentsOfFile: path, encoding: .isoLatin1)) else { return nil }
        return parse(text)
    }
}
