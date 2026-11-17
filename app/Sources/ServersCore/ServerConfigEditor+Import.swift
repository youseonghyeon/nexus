// 가져오기 (다른 사람이 내보낸 servers.conf): 없는 서버·그룹 설정·내부망 설정만 붙인다.

import Foundation

extension ServerConfigEditor {
    public struct Merge: Sendable, Equatable {
        public let text: String
        /// 새로 붙인 서버 키 (파일 순서)
        public let added: [String]
        /// 이름이 이미 있어 건너뛴 서버 키
        public let skipped: [String]
    }

    /// 가져온 목록에서 없는 것만 붙인다: 서버 블록(키가 이미 있으면 건너뜀), 그 서버들이 쓰는 [group:이름](없을 때),
    /// [network:lan](없을 때 — 서비스 이름은 Mac 마다 달라 Ethernet 화면에서 지정). 블록은 글자 그대로(바로 위 주석은 빼고) 파일 끝에.
    /// 두 파일 모두 파서로 읽히고, 결과도 다시 읽혀야 한다 (다른 서버를 가리키는 wol_via 등이 빠져 있으면 ConfigError).
    public static func merging(_ imported: String, into text: String, importedReference: String = "가져온 파일",
                               reference: String = "servers.conf") throws -> Merge {
        let source = try ServerConfigParser.parse(imported, reference: importedReference)
        let current = try ServerConfigParser.parse(text, reference: reference)
        let sourceLines = lines(of: imported)
        let currentNames = Set(headerLines(in: lines(of: text)).map(\.name))

        func block(_ name: String) -> [String]? {
            blockSpan(name, in: sourceLines).map { Array(sourceLines[$0.header...$0.last]) }
        }

        var blocks: [[String]] = []
        var added: [String] = [], skipped: [String] = []
        if current.lan == nil, !currentNames.contains("network:lan"), source.lan != nil, let lan = block("network:lan") {
            blocks.append(lan)
        }
        let newServers = source.servers.filter { server in
            guard current.server(server.key) == nil else { skipped.append(server.key); return false }
            return true
        }
        var groupsAdded = Set<String>()
        for server in newServers where !currentNames.contains("group:\(server.group)") && !groupsAdded.contains(server.group) {
            groupsAdded.insert(server.group)
            if let group = block("group:\(server.group)") { blocks.append(group) }
        }
        for server in newServers {
            guard let lines = block(server.key) else { continue }
            blocks.append(lines)
            added.append(server.key)
        }
        guard !blocks.isEmpty else { return Merge(text: text, added: [], skipped: skipped) }
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        let result = (body.isEmpty ? "" : body + "\n\n") + blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
        _ = try ServerConfigParser.parse(result, reference: reference)
        return Merge(text: result, added: added, skipped: skipped)
    }
}
