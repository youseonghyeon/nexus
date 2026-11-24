// 앱 안 브라우저의 즐겨찾기 (2026-11-17). 서버마다 따로 — 탭은 그 서버에서 켠 브라우저라 같은 주소(localhost:3000)가 서버마다 다른 것을 가리킨다.
// 주소창의 별(☆/★)로 넣고 빼고, 시작 페이지 맨 위에 타일로 보인다 (BrowserStartPage.bookmarksHTML — 타일의 ✕ 로도 뺀다). 순서는 넣은 순서.
// 저장: ~/Library/Application Support/Servers/bookmarks.json (저장소 밖). 주소는 주소창에 보이는 그대로 (루프백 별칭이 아니라 localhost·127.0.0.1).
// 이 파일은 저장과 목록 바꾸기만 (순수 함수, 테스트 대상).

import Foundation

public struct BrowserBookmark: Codable, Sendable, Equatable {
    /// 주소창에 보이는 주소 (http·https)
    public let url: String
    /// 넣을 때의 페이지 제목 (없으면 짧은 주소)
    public var title: String
    /// 페이지 아이콘 (data: 주소). 없으면 nil — 자리 그림
    public var icon: String?

    public init(url: String, title: String, icon: String? = nil) { self.url = url; self.title = title; self.icon = icon }
}

public struct BookmarkState: Codable, Sendable, Equatable {
    /// 서버 키 → 즐겨찾기 (넣은 순서)
    public var servers: [String: [BrowserBookmark]] = [:]
    public init(servers: [String: [BrowserBookmark]] = [:]) { self.servers = servers }
}

public enum BookmarkStore {
    /// 아이콘(data: 주소) 글자 수의 끝 — 64KB 그림을 base64 로 적은 길이쯤. 넘으면 아이콘 없이 넣는다
    public static let iconLimit = 90_000
    static let titleLimit = 120

    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("bookmarks.json") }

    /// 없거나 깨졌으면 빈 상태 (즐겨찾기는 부가 기능이라 오류로 막지 않는다)
    public static func load(from url: URL = defaultURL) -> BookmarkState {
        (try? AppSupport.readJSON(BookmarkState.self, from: url)) ?? BookmarkState()
    }

    public static func save(_ state: BookmarkState, to url: URL = defaultURL) throws {
        try AppSupport.writeJSON(state, to: url)
    }

    /// 같은 주소로 보는 기준: 조각(#…)과 끝의 슬래시를 뗀 것. 스킴·호스트는 소문자로 (경로·질의는 그대로 — 대소문자가 다른 페이지일 수 있다)
    public static func key(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespaces)
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        if var parts = URLComponents(string: text) {
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            text = parts.string ?? text
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// 넣을 수 있는 주소인가: http·https 이고 호스트가 있다 (시작 페이지 about:blank·data: 는 아니다)
    public static func isBookmarkable(_ url: String) -> Bool {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(), let host = parts.host else { return false }
        return ["http", "https"].contains(scheme) && !host.isEmpty
    }

    public static func contains(_ url: String, serverKey: String, in state: BookmarkState) -> Bool {
        let wanted = key(url)
        return state.servers[serverKey]?.contains { key($0.url) == wanted } ?? false
    }

    /// 제목 다듬기: 공백을 한 칸으로, 비면 짧은 주소, 길면 자른다
    static func cleanTitle(_ title: String, url: String) -> String {
        let text = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty { return shortAddress(url) }
        return text.count > titleLimit ? String(text.prefix(titleLimit)) + "…" : text
    }

    /// 아이콘은 data:image/ 로 시작하고 너무 크지 않을 때만 쓴다 (페이지가 준 값이다)
    static func cleanIcon(_ icon: String?) -> String? {
        guard let icon, icon.lowercased().hasPrefix("data:image/"), icon.utf8.count <= iconLimit else { return nil }
        return icon
    }

    /// data: 주소의 그림 바이트 (탭의 페이지 아이콘 — 앱이 그릴 때). 그림이 아니거나 너무 크거나 못 풀면 nil.
    /// base64 가 아닌 것(`data:image/svg+xml,<svg…>`)은 퍼센트 인코딩을 풀어 쓴다.
    public static func iconData(_ icon: String?) -> Data? {
        guard let icon = cleanIcon(icon), let comma = icon.firstIndex(of: ",") else { return nil }
        let header = icon[..<comma].lowercased(), body = String(icon[icon.index(after: comma)...])
        let data = header.hasSuffix(";base64") ? Data(base64Encoded: body, options: .ignoreUnknownCharacters) : body.removingPercentEncoding.map { Data($0.utf8) }
        return data.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 타일 아랫줄의 짧은 주소: "http://localhost:3000/d/x/" → "localhost:3000/d/x", https 는 스킴을 남긴다
    public static func shortAddress(_ url: String) -> String {
        var text = url
        if text.lowercased().hasPrefix("http://") { text = String(text.dropFirst(7)) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// 넣는다 (맨 뒤에). 넣을 수 없는 주소거나 이미 있으면 그대로.
    public static func adding(url: String, title: String, icon: String?, serverKey: String, to state: BookmarkState) -> BookmarkState {
        guard isBookmarkable(url), !contains(url, serverKey: serverKey, in: state) else { return state }
        var next = state
        next.servers[serverKey, default: []].append(BrowserBookmark(url: url, title: cleanTitle(title, url: url), icon: cleanIcon(icon)))
        return next
    }

    /// 뺀다. 그 서버의 마지막 것이면 서버 칸도 지운다.
    public static func removing(url: String, serverKey: String, from state: BookmarkState) -> BookmarkState {
        let wanted = key(url)
        var next = state
        next.servers[serverKey]?.removeAll { key($0.url) == wanted }
        if next.servers[serverKey]?.isEmpty ?? false { next.servers[serverKey] = nil }
        return next
    }

    /// 서버 이름을 바꿨다: 옛 이름의 것을 새 이름으로. 옛 것이 없으면 새 이름에 남은 값(지운 서버의 것)도 지운다 — 다른 서버의 즐겨찾기가 살아나지 않게
    public static func renamingServer(from old: String, to new: String, in state: BookmarkState) -> BookmarkState {
        guard old != new else { return state }
        var next = state
        next.servers[new] = next.servers.removeValue(forKey: old)
        return next
    }

    /// 서버를 목록에서 지웠다
    public static func removingServer(_ key: String, from state: BookmarkState) -> BookmarkState {
        var next = state
        next.servers[key] = nil
        return next
    }
}
