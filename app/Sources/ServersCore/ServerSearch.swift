// 사이드바 검색(⌘K): 서버를 이름·IP·역할·태그·그룹으로 찾는다.

import Foundation

public enum ServerSearch {
    /// 검색어를 이름·IP·역할·태그·그룹 중 하나라도 담으면 (대소문자 무시). 빈 검색어는 모두.
    public static func matches(_ server: Server, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields = [server.key, server.ip, server.role ?? "", server.group] + server.tags
        return fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// 서버가 아닌 행(터널·전송)은 보이는 글자로
    public static func matches(_ text: String, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || text.localizedCaseInsensitiveContains(q)
    }
}
