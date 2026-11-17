// 서버별 키 파일 (서버 정보 접속 카드의 [키 파일], 2026-10-26). .pem 처럼 기본 이름(~/.ssh/id_*)이 아닌 개인키를 그 서버에만 쓴다.
// 저장: ~/Library/Application Support/Servers/identities.json ({저장 키: 경로} — 기본 계정은 서버 키, 추가 계정은 키@계정) — 비밀번호처럼 이 Mac 의 값이라 servers.conf 에 두지 않는다.
// 파일은 복사하지 않고 그 자리를 쓴다 — 개인키가 두 벌이 되지 않게. ~/.ssh 밖(다운로드 폴더 등)이면 ~/.ssh 로 옮길지 묻는다 (moveIntoSSH).
// 연결에 붙이는 인자는 ConnectPolicy.identityOptions (파일이 없으면 붙이지 않는다).

import Foundation

public enum IdentityFile {
    /// 등록할 수 없거나 ssh 가 쓰지 않는 이유
    public enum Problem: Equatable, Sendable {
        case missing
        /// 개인키가 아님 (.pub · PuTTY .ppk · 다른 파일)
        case notPrivateKey
        /// 다른 사용자도 읽을 수 있음 — ssh 가 "UNPROTECTED PRIVATE KEY FILE" 로 거부한다
        case tooOpen
    }

    /// nil = 그대로 쓸 수 있음
    public static func check(path: String) -> Problem? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard !isDirectory.boolValue, let handle = FileHandle(forReadingAtPath: path) else { return .notPrivateKey }
        let head = String(decoding: handle.readData(ofLength: 200), as: UTF8.self)
        try? handle.close()
        guard isPrivateKey(head) else { return .notPrivateKey }
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        return tooOpen(mode: mode) ? .tooOpen : nil
    }

    /// 파일 머리: "-----BEGIN OPENSSH PRIVATE KEY-----" · "-----BEGIN RSA PRIVATE KEY-----"(.pem) · "-----BEGIN PRIVATE KEY-----" · ENCRYPTED·EC·DSA
    public static func isPrivateKey(_ head: String) -> Bool {
        guard let line = head.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return false }
        return line.hasPrefix("-----BEGIN ") && line.hasSuffix("PRIVATE KEY-----")
    }

    /// 그룹·다른 사용자 권한이 하나라도 있으면 ssh 가 키를 거부한다
    public static func tooOpen(mode: Int) -> Bool { mode & 0o077 != 0 }

    /// 600 (나만 읽기·쓰기)
    public static func restrict(path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// ~/.ssh 아래(하위 폴더 포함)에 있는가
    public static func isInSSHDirectory(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let ssh = (home as NSString).appendingPathComponent(".ssh")
        let standardized = (path as NSString).standardizingPath
        return standardized.hasPrefix(ssh + "/")
    }

    /// ~/.ssh/<같은 이름> 으로 옮기고 600 으로. 옮긴 경로를 돌려준다. ~/.ssh 가 없으면 700 으로 만든다.
    /// 같은 이름이 이미 있으면: 내용이 같으면 원본은 두고 그 파일을 쓰고, 다르면 덮지 않고 실패.
    public static func moveIntoSSH(_ path: String, home: String = NSHomeDirectory()) throws -> String {
        let fm = FileManager.default
        let ssh = (home as NSString).appendingPathComponent(".ssh")
        if !fm.fileExists(atPath: ssh) {
            try fm.createDirectory(atPath: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let destination = (ssh as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        if fm.fileExists(atPath: destination) {
            guard fm.contentsEqual(atPath: path, andPath: destination) else {
                throw ConfigError(problem: "~/.ssh/\((destination as NSString).lastPathComponent) 이 이미 있어 옮기지 못했습니다 (내용이 다름)",
                                  fix: "키 파일 이름을 바꿔 다시 고르거나, [이 자리 그대로] 로 등록하세요.", reference: destination)
            }
        } else {
            try fm.moveItem(atPath: path, toPath: destination)
        }
        try restrict(path: destination)
        return destination
    }
}

public enum IdentityStore {
    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("identities.json") }

    /// 없거나 깨졌으면 빈 목록 (키 파일이 없으면 지금처럼 기본 키·비밀번호로 접속한다)
    public static func load(from url: URL = defaultURL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public static func save(_ identities: [String: String], to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(identities).write(to: url, options: .atomic)
    }
}
