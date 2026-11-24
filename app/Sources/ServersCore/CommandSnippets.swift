// 명령 모음: 외우기 힘든 명령을 서버 종류(windows·linux)·이 Mac(mac)별로 등록해 두고, 누르면 보고 있는 터미널에 입력한다(없으면 복사). 탭 막대의 팝오버가 쓴다.
// 저장: ~/Library/Application Support/Servers/snippets.json (저장소 밖). 사용자가 쓴 내용이라 깨진 파일을 빈 목록으로 덮지 않는다.

import Foundation

/// 명령 모음의 종류: 서버 종류(linux·windows) + 이 Mac 로컬 셸(mac). 저장 글자는 ServerType 과 같아 예전 파일이 그대로 읽힌다.
public enum SnippetKind: String, Codable, Sendable {
    case linux, windows, mac

    public init(_ type: ServerType) { self = type == .windows ? .windows : .linux }

    public var title: String {
        switch self {
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .mac: return "macOS"
        }
    }
}

public struct CommandSnippet: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var type: SnippetKind
    /// 비면 목록에 명령 첫 줄을 보인다
    public var title: String
    public var command: String
    /// 입력한 뒤 Enter 까지 보낸다. 끄면 붙여 넣기만 — 사용자가 보고 Enter.
    public var runImmediately: Bool
    /// 민감한 명령(재부팅·삭제 등): 터미널에 넣기 전에 서버 이름을 쳐서 확인한다 (복사는 그대로)
    public var sensitive: Bool

    public init(id: UUID = UUID(), type: SnippetKind, title: String = "", command: String = "", runImmediately: Bool = false,
                sensitive: Bool? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.command = command
        self.runImmediately = runImmediately
        self.sensitive = sensitive ?? SnippetStore.looksSensitive(command)
    }

    private enum CodingKeys: String, CodingKey { case id, type, title, command, runImmediately, sensitive }

    /// runImmediately·sensitive 가 없던 예전 파일도 읽는다 (바로 실행은 꺼짐, 민감은 명령 글자로 판단 — 이미 넣어 둔 reboot 도 확인을 받게)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(SnippetKind.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        command = try c.decode(String.self, forKey: .command)
        runImmediately = try c.decodeIfPresent(Bool.self, forKey: .runImmediately) ?? false
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? SnippetStore.looksSensitive(command)
    }

    public var displayTitle: String {
        title.isEmpty ? String(command.split(whereSeparator: \.isNewline).first ?? "") : title   // \r\n 은 한 글자라 "\n" 으로는 못 나눈다
    }
}

public struct SnippetState: Codable, Sendable, Equatable {
    public var snippets: [CommandSnippet] = []
    public init(snippets: [CommandSnippet] = []) { self.snippets = snippets }
}

public enum SnippetStore {
    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("snippets.json") }

    /// 파일이 없으면 빈 목록. 있는데 못 읽으면 throw — 저장하면 덮어 버리므로 앱은 편집을 막는다.
    public static func load(from url: URL = defaultURL) throws -> SnippetState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SnippetState() }
        do {
            var state = try AppSupport.readJSON(SnippetState.self, from: url)
            // 손으로 고친 파일도 앱에서 저장한 것과 같게 (끝 줄바꿈이 남으면 입력만 해도 Enter 가 된다)
            state.snippets = state.snippets.map { normalized($0) ?? $0 }
            return state
        } catch {
            throw ConfigError(problem: "명령 모음 파일을 읽지 못했습니다 (\(error.localizedDescription))",
                              fix: "파일을 고치거나 다른 이름으로 옮긴 뒤 앱을 다시 켜세요. 그 전까지 추가·편집은 막습니다.",
                              reference: url.path)
        }
    }

    public static func save(_ state: SnippetState, to url: URL = defaultURL) throws {
        try AppSupport.writeJSON(state, to: url)
    }

    /// 그 종류의 명령 (등록한 순서)
    public static func snippets(for type: SnippetKind, in state: SnippetState) -> [CommandSnippet] {
        state.snippets.filter { $0.type == type }
    }

    /// 입력칸 값 → 저장할 값. 이름은 앞뒤 공백, 명령은 앞뒤 공백·빈 줄을 뗀다 (안쪽 줄바꿈은 그대로). 명령이 비면 nil.
    public static func normalized(_ snippet: CommandSnippet) -> CommandSnippet? {
        var out = snippet
        out.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.command = snippet.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.command.isEmpty ? nil : out
    }

    /// 같은 id 는 그 자리에서 바꾸고, 새것은 끝에 붙인다
    public static func upsert(_ snippet: CommandSnippet, in state: SnippetState) -> SnippetState {
        var next = state
        if let i = next.snippets.firstIndex(where: { $0.id == snippet.id }) {
            next.snippets[i] = snippet
        } else {
            next.snippets.append(snippet)
        }
        return next
    }

    public static func remove(id: UUID, from state: SnippetState) -> SnippetState {
        SnippetState(snippets: state.snippets.filter { $0.id != id })
    }

    /// 민감한 명령으로 보이는 글자 (편집기가 이걸 보고 "민감한 명령" 을 켜 둔다 — 사용자가 끌 수 있다).
    /// 재부팅·전원 · 지우기·포맷 · 서비스·컨테이너·쿠버네티스 자원 내리기 · Windows 같은 뜻 명령. 낱말 경계로, 대소문자 무시.
    static let sensitivePatterns = [
        // 재부팅·전원
        #"\b(reboot|shutdown|poweroff|halt)\b"#, #"\binit\s+[06]\b"#,
        // 서비스: 동작 낱말 앞에 옵션(--user · -q)이 와도. 파이프(|)·다음 줄은 다른 명령이라 보지 않는다 (아래 [^;&|\n] 도 같다)
        #"\bsystemctl\b[^;&|\n]*\s(reboot|poweroff|halt|stop|restart|disable|mask|kill)\b"#, #"\bservice\s+\S+\s+(stop|restart)\b"#,
        // 재귀 삭제 (옵션 위치·순서 무관 — rm -i -rf · rm x -rf · --recursive). git rm 은 아님. 여러 줄 명령은 줄 처음도 명령 자리
        #"(^|[;&|(\n]\s*|\bsudo\s+)rm\b[^;&|\n]*\s-(-recursive|\w*[rR]\w*)\b"#,
        #"\bmkfs(\.\w+)?\b"#, #"\bdd\s+.*\bof="#, #"\bwipefs\b"#, #"\bfdisk\b"#, #"\bparted\b"#,
        // 쿠버네티스·컨테이너 (kubectl -n ns delete · docker compose -f a.yml down · docker-compose down)
        #"\bkubectl\b[^;&|\n]*\s(delete|drain|cordon|scale)\b"#, #"k3s-(killall|uninstall)"#,
        #"\bdocker(-compose)?\b[^;&|\n]*\s(rm|rmi|stop|kill|restart|prune|down)\b"#,
        // Windows (PowerShell · cmd)
        #"\b(Restart|Stop)-(Computer|Service)\b"#, #"\bRemove-Item\b[^;|\n]*\s-(Recurse|r)\b"#, #"\bFormat-Volume\b"#, #"\bClear-Disk\b"#,
        #"\b(rd|rmdir)\s+/s\b"#, #"\bdel\b[^;&|\n]*\s/[fsq]\b"#,
        #"\b(drop|truncate)\s+(table|database|schema)\b"#,
        #"\bdiskutil\s+(erase\w*|reformat|partitionDisk|zeroDisk|secureErase|apfs\s+delete\w*)\b"#,   // macOS
    ]

    public static func looksSensitive(_ command: String) -> Bool {
        sensitivePatterns.contains { command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// 터미널에 넣기 전에 확인을 받을지. 빈칸을 채운 결과가 민감해진 것도 (systemctl {{동작}} 에 restart) —
    /// 다만 템플릿 글자가 이미 민감해 보이는데 꺼져 있으면 사용자가 끈 것이라 그대로 둔다.
    public static func needsConfirm(_ snippet: CommandSnippet, filled: String) -> Bool {
        snippet.sensitive || (!looksSensitive(snippet.command) && looksSensitive(filled))
    }

    /// 민감한 명령 확인: 서버 이름을 그대로 쳤는가 (앞뒤 공백·대소문자 무시)
    public static func confirms(_ typed: String, server: String) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !server.isEmpty && t.caseInsensitiveCompare(server) == .orderedSame
    }

    /// 검색: 이름·명령에 들어 있으면 (대소문자 무시). 빈 검색어는 전부.
    public static func matches(_ snippet: CommandSnippet, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return snippet.title.localizedCaseInsensitiveContains(q) || snippet.command.localizedCaseInsensitiveContains(q)
    }
}

/// 명령 안의 빈칸 `{{이름}}`: 누를 때 값을 물어 채운 뒤 입력한다. 같은 이름은 한 번만 묻고 모두 바꾼다.
/// 중괄호 하나(`{ }`)는 PowerShell 스크립트 블록·bash `${VAR}`·awk `'{print $1}'` 와 겹치므로 두 겹만 빈칸으로 본다.
/// 이름은 글자·숫자·_·-·공백만 — docker `--format '{{.Names}}'`·`{{json .}}` 같은 Go 템플릿은 빈칸이 아니다 (`{{end}}` 처럼 낱말만인 것은 구분 못 함).
public enum SnippetTemplate {
    private static var pattern: Regex<(Substring, Substring)> { /\{\{ *([\p{L}\p{N}_-][\p{L}\p{N}_ -]*?) *\}\}/ }

    /// 나온 순서대로, 겹치지 않게
    public static func variables(in command: String) -> [String] {
        var out: [String] = []
        for match in command.matches(of: pattern) where !out.contains(String(match.1)) {
            out.append(String(match.1))
        }
        return out
    }

    /// 값이 없는 빈칸은 그대로 둔다
    public static func fill(_ command: String, values: [String: String]) -> String {
        command.replacing(pattern) { match in values[String(match.1)] ?? String(match.0) }
    }
}
