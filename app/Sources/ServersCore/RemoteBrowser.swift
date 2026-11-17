// 원격 폴더 탐색 (다운로드·업로드 시트의 [찾아보기…]). sftp 에 stdin 으로 cd → pwd → ls -la 를 줘 정식 경로와 목록을 받는다.
// Linux·Windows(OpenSSH) 둘 다 SFTP 라 셸 차이가 없고, 공유 SSH 연결(ControlMaster)을 타므로 한 번 이동이 수백 ms 다.
// -b(배치)는 쓰지 않는다: 배치는 ssh 에 BatchMode=yes 를 걸어 비밀번호 팝업(askpass)까지 막는다 — Windows 처럼 비밀번호 서버면 접속이 안 된다.
// 대신 명령이 실패해도 다음 줄로 넘어가므로, cd 의 오류는 출력에서 가려낸다 ("sftp> cd …" 다음에 오는 비-에코 줄).

import Foundation

public struct RemoteEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case directory, file, link, drive }
    public let name: String
    public let kind: Kind
    public var id: String { name }
    public var isDirectory: Bool { kind == .directory || kind == .drive }
    public init(name: String, kind: Kind) { self.name = name; self.kind = kind }
}

public enum RemoteBrowser {
    /// 서버가 알려주는 정식 경로와 그 안의 항목
    public struct Listing: Sendable, Equatable {
        public let path: String
        public let entries: [RemoteEntry]
        public init(path: String, entries: [RemoteEntry]) { self.path = path; self.entries = entries }
    }

    /// sftp 인자 ("sftp" 제외). 전송과 같은 연결 공유·비밀번호 팝업 환경. -q 는 "Connected to …" 배너와 진행률을 끈다. 명령은 stdin 으로.
    public static func arguments(server: Server, home: String = NSHomeDirectory(), bindInterface: String? = nil) -> [String] {
        ConnectPolicy.sharedArguments(port: server.port, portFlag: "-P", bindInterface: bindInterface, home: home, identity: server.identityFile) + AskPass.options + ["-q", server.target]
    }

    /// stdin 으로 줄 명령. path 가 nil 이면 홈(접속 직후 위치). 이름은 sftp 토큰 규칙에 맞춰 큰따옴표로 감싼다.
    public static func batchScript(path: String?) -> String {
        var lines: [String] = []
        if let path, !path.isEmpty { lines.append("cd \(quote(path))") }
        lines += ["pwd", "ls -la"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// sftp 의 인자 토큰: 큰따옴표로 감싸고 안의 \ 와 " 는 \ 로 이스케이프
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 출력 해석 결과. error 가 있으면 cd 가 실패한 것(그 줄의 메시지). unparsed 는 ls 뒤에 왔지만 형식을 못 읽은 줄 — 서버별 형식 차이를 드러내는 진단용.
    public struct Outcome: Sendable, Equatable {
        public let listing: Listing?
        public let error: String?
        public let unparsed: [String]
    }

    /// sftp 출력 → 정식 경로 + 항목. "sftp> <명령>" 에코로 어느 명령의 출력인지 가른다. "." ".." 은 뺀다. 폴더(드라이브 포함) 먼저, 이름순.
    public static func parse(_ output: String) -> Outcome {
        var path: String?
        var entries: [RemoteEntry] = []
        var unparsed: [String] = []
        var current = ""   // 마지막 에코된 명령 (cd / pwd / ls)
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.hasPrefix("sftp>") {
                current = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("Remote working directory: ") {
                path = String(line.dropFirst("Remote working directory: ".count))
                continue
            }
            if current.hasPrefix("cd ") { return Outcome(listing: nil, error: line, unparsed: []) }
            guard current.hasPrefix("ls") else { continue }
            if let entry = parseLongLine(line) {
                if entry.name != "." && entry.name != ".." { entries.append(entry) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                unparsed.append(line)
            }
        }
        guard let path else { return Outcome(listing: nil, error: nil, unparsed: unparsed) }
        let sorted = entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return Outcome(listing: Listing(path: path, entries: sorted), error: nil, unparsed: unparsed)
    }

    private static let longLineRegex = try? NSRegularExpression(pattern: #"^([-dlbcps?])[rwxsStT?*-]{9}\s+(?:\d+|\?)\s+(?:.*?\s+)?(?:\d+|\?)\s+[A-Za-z]{3}\s+\d{1,2}\s+(?:\d{2}:\d{2}|\d{4})\s+(.+)$"#)

    /// ls -l 한 줄: "<종류><권한 9자> <링크수> <소유자…> <크기> <월 일 시:분|연도> <이름>". 소유자에 공백·역슬래시(Windows 도메인)가 있어도 된다.
    /// Windows 루트(ls /)의 드라이브 목록은 "C:" 또는 "/C:" 처럼 오므로 그것도 받는다.
    public static func parseLongLine(_ line: String) -> RemoteEntry? {
        // 링크 수·크기는 서버가 모르면 "?" 로 온다 (macOS sftp-server). Windows OpenSSH 는 권한 자리를 "*" 로, 소유자·그룹을 "-" 로 채운다:
        //   drwx******    1 -        -                0 Apr 30 14:06 .android
        if let m = longLineRegex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let typeRange = Range(m.range(at: 1), in: line), let nameRange = Range(m.range(at: 2), in: line) {
            let name = unescapeOctal(String(line[nameRange]))
            switch line[typeRange] {
            case "d": return RemoteEntry(name: name, kind: isDriveName(name) ? .drive : .directory)
            case "l": return RemoteEntry(name: name, kind: .link)
            default: return RemoteEntry(name: name, kind: .file)
            }
        }
        // 드라이브 목록 줄 ("C:" 또는 "/C:", 한 줄에 여러 개일 수도)
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if !tokens.isEmpty, tokens.allSatisfy(isDriveName) { return RemoteEntry(name: tokens[0], kind: .drive) }
        return nil
    }

    /// sftp 가 로케일이 아니라고 본 글자를 "\355\225\234" 처럼 8진수로 바꿔 놓은 것을 되돌린다 (UTF-8 바이트열). 호출 쪽에서 UTF-8 로케일을 주지만 보험.
    static func unescapeOctal(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        let chars = Array(s.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < chars.count {
            // "\" 뒤에 8진수 세 자리가 있으면 바이트 하나로
            if chars[i] == UInt8(ascii: "\\"), i + 3 < chars.count,
               let value = UInt8(String(decoding: chars[(i + 1)...(i + 3)], as: UTF8.self), radix: 8) {
                bytes.append(value)
                i += 4
            } else {
                bytes.append(chars[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func isDriveName(_ s: String) -> Bool {
        s.range(of: #"^/?[A-Za-z]:$"#, options: .regularExpression) != nil
    }

    /// 목록 항목을 골랐을 때의 경로. 드라이브는 "/C:/", 루트 아래는 "/이름", 그 밖은 "경로/이름".
    public static func join(_ path: String, _ entry: RemoteEntry) -> String {
        if entry.kind == .drive {
            let letter = entry.name.hasPrefix("/") ? String(entry.name.dropFirst()) : entry.name
            return "/\(letter)/"
        }
        if path == "/" || path.isEmpty { return "/\(entry.name)" }
        return path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
    }

    /// 한 단계 위. "/D:/a" → "/D:/", "/D:/" → "/"(드라이브 목록), "/home/x" → "/home", "/" → "/".
    public static func parent(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if p == "/" || p.isEmpty { return "/" }
        if isDriveName(p) { return "/" }
        guard let slash = p.lastIndex(of: "/") else { return "/" }
        let up = String(p[..<slash])
        if up.isEmpty { return "/" }
        return isDriveName(up) ? up + "/" : up
    }

    /// 사용자가 직접 적은 경로 정리: Windows 서버면 "\" 를 "/" 로 (scp 의 SFTP 모드가 "\" 를 이스케이프로 먹어 버린다 — "Desktop\a.zip" 이 "Desktopa.zip" 으로 감).
    public static func normalizePath(_ path: String, windows: Bool) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return windows ? trimmed.replacingOccurrences(of: "\\", with: "/") : trimmed
    }

    /// 폴더 아래 이름 붙이기 ("/" 끝 처리)
    public static func child(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}
