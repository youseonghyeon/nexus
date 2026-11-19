// 메모·로그인 보관 (2026-11-18). 서버마다 따로 — 브라우저 탭은 그 서버에서 켠 브라우저라 같은 주소(localhost:3000)의 계정이 서버마다 다르다.
// 탭 막대의 열쇠 버튼(명령 모음 옆)이 연다. 항목은 두 가지: 메모(제목·본문) · 로그인(주소·ID·비밀번호 — 브라우저 탭에서 저장을 묻고, 누르면 채운다).
// 저장: ~/Library/Application Support/Servers/notes.bin — passwords.bin 과 같은 키(로그인 키체인)로 AES-GCM, 권한 0600.
// 비밀번호와 다른 점: 키체인을 못 읽으면 고정 키로 돌아가지 않고 읽기·쓰기를 막는다(고정 키는 공개 저장소에 있다). 못 푸는 파일은 덮지 않는다.
// 설정의 [키 새로 만들기]는 이 파일도 지운다 (새 키로는 못 푼다). 이 파일은 저장과 목록 바꾸기만 (순수 함수, 테스트 대상).

import CryptoKit
import Foundation

public struct SecretNote: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case memo, login }

    public var id: UUID
    public var kind: Kind
    /// 메모의 제목 · 로그인의 이름 (비워도 된다 — displayTitle)
    public var title: String
    /// 메모 본문
    public var body: String
    /// 메모: 목록에서 본문을 가린다 (펼쳐야 보인다)
    public var concealed: Bool
    /// 로그인: 이 계정을 쓰는 주소들 — 주소창에 보이는 주소의 출처 (`http://localhost:3000` — NoteVault.site). 하나 이상.
    /// 같은 계정으로 들어가는 주소가 여럿일 수 있다 (localhost·127.0.0.1·서버 IP)
    public var sites: [String]
    public var username: String
    public var password: String

    public init(id: UUID = UUID(), kind: Kind, title: String = "", body: String = "", concealed: Bool = false,
                sites: [String] = [], username: String = "", password: String = "") {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.concealed = concealed
        self.sites = sites; self.username = username; self.password = password
    }

    private enum CodingKeys: String, CodingKey { case id, kind, title, body, concealed, sites, site, username, password }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body); try c.encode(concealed, forKey: .concealed)
        try c.encode(sites, forKey: .sites); try c.encode(username, forKey: .username); try c.encode(password, forKey: .password)
    }

    /// 빠진 칸은 빈 값으로 읽는다 (칸이 늘어도 옛 파일이 읽히게)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        concealed = try c.decodeIfPresent(Bool.self, forKey: .concealed) ?? false
        // 주소가 하나이던 때의 파일 (site) 도 읽는다
        let single = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        sites = try c.decodeIfPresent([String].self, forKey: .sites) ?? (single.isEmpty ? [] : [single])
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
    }

    /// 목록의 윗줄. 메모: 제목 → 본문 첫 줄(가린 메모는 "메모"). 로그인: 이름 → ID → 짧은 주소.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        switch kind {
        case .memo: return concealed ? "메모" : String(body.split(whereSeparator: \.isNewline).first ?? "")
        case .login: return username.isEmpty ? siteSummary : username
        }
    }

    /// 목록 아랫줄의 주소: 첫 주소를 짧게, 더 있으면 "외 N"
    public var siteSummary: String {
        guard let first = sites.first else { return "" }
        return BookmarkStore.shortAddress(first) + (sites.count > 1 ? " 외 \(sites.count - 1)" : "")
    }
}

public struct NoteState: Codable, Sendable, Equatable {
    /// 서버 키 → 항목 (넣은 순서)
    public var servers: [String: [SecretNote]] = [:]
    public init(servers: [String: [SecretNote]] = [:]) { self.servers = servers }
}

public enum NoteVault {
    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("notes.bin") }
    /// 페이지가 보낸 ID·비밀번호 글자 수의 끝 (넘으면 저장을 묻지 않는다)
    static let fieldLimit = 1000

    static func locked(_ url: URL) -> ConfigError {
        ConfigError(problem: "키체인에서 키를 읽지 못해 메모·로그인을 열 수 없습니다.", fix: "앱을 다시 실행하세요. 그 전까지 읽기·쓰기를 막습니다.", reference: url.path)
    }

    /// 파일이 없으면 빈 상태. 고정 키(키체인 실패)거나 못 풀면 throw — 앱은 추가·편집을 막는다 (저장하면 그 파일을 덮는다).
    public static func load(from url: URL = defaultURL, key: VaultKey) throws -> NoteState {
        guard !key.isFallback else { throw locked(url) }
        guard FileManager.default.fileExists(atPath: url.path) else { return NoteState() }
        guard let data = try? Data(contentsOf: url), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key.key), let state = try? JSONDecoder().decode(NoteState.self, from: plain) else {
            throw ConfigError(problem: "메모·로그인 파일을 풀지 못했습니다 (다른 Mac 의 파일이거나 키가 바뀌었습니다).",
                              fix: "파일을 다른 이름으로 옮기거나 지운 뒤 앱을 다시 켜세요. 그 전까지 추가·편집은 막습니다.", reference: url.path)
        }
        return state
    }

    /// 비어 있으면 파일을 지운다. 쓸 때는 0600. 고정 키로는 쓰지 않는다.
    public static func save(_ state: NoteState, to url: URL = defaultURL, key: VaultKey) throws {
        guard !key.isFallback else { throw locked(url) }
        if state.servers.values.allSatisfy(\.isEmpty) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(state), using: key.key).combined ?? Data()
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: 주소

    /// 로그인을 묶는 주소: 스킴 + 호스트 + (기본이 아닌) 포트, 소문자. 스킴 없이 친 것은 http 로 본다. http·https 가 아니면 nil.
    /// `http://Localhost:3000/login?x#y` → `http://localhost:3000` · `https://a.example:443/` → `https://a.example`
    public static func site(of address: String) -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host   // IPv6 (URLComponents 는 대괄호째 준다)
        if let port = parts.port, port != (scheme == "https" ? 443 : 80) { return "\(scheme)://\(name):\(port)" }
        return "\(scheme)://\(name)"
    }

    // MARK: 목록

    public static func notes(for serverKey: String, in state: NoteState) -> [SecretNote] { state.servers[serverKey] ?? [] }

    /// 보일 순서: 지금 보는 페이지(site)의 로그인이 맨 위, 나머지는 넣은 순서
    public static func ordered(_ notes: [SecretNote], site: String?) -> [SecretNote] {
        guard let site else { return notes }
        return notes.filter { fits($0, site: site) } + notes.filter { !fits($0, site: site) }
    }

    /// 이 페이지의 로그인인가 (적어 둔 주소 중 하나와 같을 때) — 맨 위로 올리기 · "채우기" 표시 · 로그인 칸 아래 목록(저절로 뜨므로 이 페이지 것만)
    public static func fits(_ note: SecretNote, site: String?) -> Bool {
        guard note.kind == .login, let site else { return false }
        return note.sites.contains(site)
    }

    /// 패널에서 골라 누른 로그인을 채울 수 있는가 — 보고 있는 웹 페이지만 있으면 주소가 달라도 채운다 (사용자가 직접 고른 것이라, 2026-11-19).
    /// 페이지가 없으면(터미널·시작 페이지) 비밀번호 복사.
    public static func canFill(_ note: SecretNote, site: String?) -> Bool {
        note.kind == .login && site != nil
    }

    /// 검색: 제목·주소·ID, 가리지 않은 메모는 본문도 (대소문자 무시). 비밀번호·가린 본문은 찾지 않는다. 빈 검색어는 전부.
    public static func matches(_ note: SecretNote, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        var fields = [note.title]
        switch note.kind {
        case .memo: if !note.concealed { fields.append(note.body) }
        case .login: fields += note.sites + [note.username]
        }
        return fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// 입력칸 값 → 저장할 값. 종류에 안 쓰는 칸은 비운다. 메모는 제목·본문이 다 비면 nil.
    /// 로그인의 주소: 빈 줄은 버리고 같은 것은 하나로. 틀린 주소가 있거나 하나도 없거나 ID·비밀번호가 다 비면 nil.
    /// 비밀번호는 다듬지 않는다 (앞뒤 공백도 비밀번호일 수 있다).
    public static func normalized(_ note: SecretNote) -> SecretNote? {
        var out = note
        out.title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch note.kind {
        case .memo:
            out.body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            out.sites = []; out.username = ""; out.password = ""
            return out.title.isEmpty && out.body.isEmpty ? nil : out
        case .login:
            var sites: [String] = []
            for raw in note.sites where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let site = site(of: raw) else { return nil }
                if !sites.contains(site) { sites.append(site) }
            }
            guard !sites.isEmpty else { return nil }
            out.sites = sites
            out.username = note.username.trimmingCharacters(in: .whitespacesAndNewlines)
            out.body = ""; out.concealed = false
            return out.username.isEmpty && out.password.isEmpty ? nil : out
        }
    }

    /// 같은 id 는 그 자리에서 바꾸고, 새것은 끝에 붙인다
    public static func upsert(_ note: SecretNote, serverKey: String, in state: NoteState) -> NoteState {
        var next = state
        var list = next.servers[serverKey] ?? []
        if let i = list.firstIndex(where: { $0.id == note.id }) { list[i] = note } else { list.append(note) }
        next.servers[serverKey] = list
        return next
    }

    /// 뺀다. 그 서버의 마지막 것이면 서버 칸도 지운다.
    public static func remove(id: UUID, serverKey: String, from state: NoteState) -> NoteState {
        var next = state
        next.servers[serverKey]?.removeAll { $0.id == id }
        if next.servers[serverKey]?.isEmpty ?? false { next.servers[serverKey] = nil }
        return next
    }

    /// 서버 이름을 바꿨다: 옛 이름의 것을 새 이름으로. 옛 것이 없으면 새 이름에 남은 값(지운 서버의 것)도 지운다
    public static func renamingServer(from old: String, to new: String, in state: NoteState) -> NoteState {
        guard old != new else { return state }
        var next = state
        next.servers[new] = next.servers.removeValue(forKey: old)
        return next
    }

    /// 서버를 목록에서 지웠다
    public static func removingServer(_ key: String, from state: NoteState) -> NoteState {
        var next = state
        next.servers[key] = nil
        return next
    }

    // MARK: 브라우저에서 잡은 로그인

    /// 페이지에서 잡은 ID·비밀번호를 어떻게 할지: 묻지 않음 · 새로 저장을 물음 · 저장한 것의 비밀번호 바꾸기를 물음(같은 주소·같은 ID)
    public enum Capture: Equatable {
        case ignore
        case add(SecretNote)
        case update(SecretNote)
    }

    public static func capture(address: String, username: String, password: String, serverKey: String, in state: NoteState) -> Capture {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let site = site(of: address), !password.isEmpty, password.count <= fieldLimit, user.count <= fieldLimit else { return .ignore }
        if var known = notes(for: serverKey, in: state).first(where: { fits($0, site: site) && $0.username == user }) {
            guard known.password != password else { return .ignore }
            known.password = password
            return .update(known)
        }
        return .add(SecretNote(kind: .login, sites: [site], username: user, password: password))
    }

    /// 잡아 둔 로그인을 물어도 되는가: 잡은 지 얼마 안 됐고(window 초), 지금 페이지에 비밀번호 칸이 안 보인다 —
    /// 로그인에 실패하면 같은 칸이 다시 뜨고, 비밀번호 보기 버튼 같은 딴 클릭에는 칸이 그대로 있다.
    public static func confirms(capturedAt: Date, now: Date, passwordFieldVisible: Bool, window: TimeInterval = 60) -> Bool {
        !passwordFieldVisible && now.timeIntervalSince(capturedAt) <= window && now >= capturedAt
    }
}
