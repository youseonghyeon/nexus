// 서버 이름 바꾸기 — 탭·비밀번호·터널 기록·wol_via·db_jump 가 이름(키)에 묶여 있어 함께 옮긴다.
// 여기는 파일의 머리와 참조 줄. 저장 값(비밀번호·키 파일)은 +Credentials.

import Foundation

extension ServerConfigEditor {
    /// 새 이름의 문제 한 줄. nil 이면 쓸 수 있다 (그대로여도 nil).
    public static func renameProblem(_ new: String, for key: String, in config: ServerConfig) -> String? {
        if new == key { return nil }
        if new.range(of: ConfigPattern.key, options: .regularExpression) == nil {
            return "이름은 소문자로 시작하고 소문자·숫자·밑줄만 쓸 수 있습니다 (예: sandbox2)"
        }
        if config.server(new) != nil { return "이미 있는 이름입니다 (\(new))" }
        return nil
    }

    /// [키] 머리와 그 서버를 가리키는 wol_via·db_jump 만 고친 텍스트. 블록 안 줄·자리·머리 뒤 주석은 그대로.
    public static func renaming(key old: String, to new: String, in text: String, reference: String = "servers.conf") throws -> String {
        let current = try ServerConfigParser.parse(text, reference: reference)
        guard current.server(old) != nil else {
            throw missingServer(old, reference: reference)
        }
        if old == new { return text }
        if let problem = renameProblem(new, for: old, in: current) {
            throw ConfigError(problem: problem, fix: "다른 이름을 쓰세요.", reference: reference)
        }
        var all = lines(of: text)
        for server in current.servers where server.wolRoutes.contains(where: { $0.via == old }) {
            let routes = server.wolRoutes.map { $0.via == old ? WakeRoute(via: new, iface: $0.iface) : $0 }
            setFields([("wol_via", routes.map(\.text).joined(separator: ","))], key: server.key, in: &all)
        }
        // [group:…] 머리 전체를 본다 — 파서의 그룹 목록엔 서버가 있는 그룹만 있다
        for group in groupHeaders(in: all) where fieldValue("db_jump", key: group, in: all) == old {
            setFields([("db_jump", new)], key: group, in: &all)
        }
        guard let header = headerLines(in: all).first(where: { $0.name == old }), let range = all[header.line].range(of: "[\(old)]") else {
            throw ConfigError(problem: "'\(old)' 블록 헤더를 찾지 못했습니다.", fix: "servers.conf 에서 직접 고치세요.", reference: reference)
        }
        all[header.line].replaceSubrange(range, with: "[\(new)]")
        let result = all.joined(separator: "\n") + "\n"
        _ = try ServerConfigParser.parse(result, reference: reference)
        return result
    }
}
