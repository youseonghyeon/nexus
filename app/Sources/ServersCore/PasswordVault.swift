// 서버 비밀번호 보관. ~/Library/Application Support/Servers/passwords.bin 에 AES-GCM 으로 암호화해 둔다 (파일 권한 0600).
// 키는 설치마다 무작위로 만들어 로그인 키체인에 둔다 (VaultKeyStore) — 앱이나 passwords.bin 만으로는 못 푼다.
// 예전 고정 키(legacyKey)는 옛 파일을 읽어 새 키로 옮길 때와, 키체인을 쓸 수 없을 때만 쓴다.

import CryptoKit
import Foundation
import Security

/// 금고 키 저장소. 앱은 키체인, 테스트는 메모리.
public protocol VaultKeyStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// 로그인 키체인의 일반 암호 항목 하나 (파일 기반 키체인 — 이 Mac 에만, iCloud 로 동기화하지 않는다).
/// data protection 키체인은 provisioning profile(앱 ID entitlement)이 있어야 해 쓰지 않는다. 항목 ACL 은 만든 앱(서명)만 묻지 않고 읽는다.
public struct KeychainKeyStore: VaultKeyStore {
    let service: String
    let account: String

    public init(service: String = "local.yuseonghyeon.servers.password-vault", account: String = "key") {
        self.service = service; self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return data
    }

    public func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let added = SecItemAdd(query.merging([kSecValueData as String: data, kSecAttrLabel as String: "Nexus 비밀번호 키"]) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? { (SecCopyErrorMessageString(status, nil) as String?) ?? "키체인 오류 \(status)" }
}

/// 쓰는 키. 키체인을 못 쓰면 고정 키로 돌아간다 (isFallback — 비밀번호가 사라지지 않게).
public struct VaultKey: @unchecked Sendable {
    let key: SymmetricKey
    public let isFallback: Bool
}

public enum PasswordVault {
    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("passwords.bin") }

    /// 예전 고정 대칭키 (256 bit). 문자열을 SHA-256 으로 늘려 쓴다. 옛 파일 읽기·키체인 실패 때만.
    static let legacyKey = SymmetricKey(data: SHA256.hash(data: Data("local.yuseonghyeon.servers · password vault · v1".utf8)))
    static var legacy: VaultKey { VaultKey(key: legacyKey, isFallback: true) }

    /// 저장소의 키. 없으면 무작위 키를 만들어 저장한다. 읽기·쓰기에 실패하면 고정 키.
    public static func resolveKey(store: VaultKeyStore) -> VaultKey {
        do {
            if let data = try store.read(), data.count == 32 { return VaultKey(key: SymmetricKey(data: data), isFallback: false) }
            let fresh = SymmetricKey(size: .bits256)
            try store.write(fresh.withUnsafeBytes { Data($0) })
            return VaultKey(key: fresh, isFallback: false)
        } catch {
            return legacy
        }
    }

    /// 새 키를 만들어 저장하고 비밀번호 파일을 지운다 (설정의 [키 새로 만들기]). 키 저장에 실패하면 파일은 그대로 두고 throw.
    public static func rotateKey(store: VaultKeyStore, url: URL = defaultURL) throws -> VaultKey {
        let fresh = SymmetricKey(size: .bits256)
        try store.write(fresh.withUnsafeBytes { Data($0) })
        try? FileManager.default.removeItem(at: url)
        return VaultKey(key: fresh, isFallback: false)
    }

    public static func encrypt(_ passwords: [String: String], key: VaultKey) throws -> Data {
        let plain = try JSONEncoder().encode(passwords)
        return try AES.GCM.seal(plain, using: key.key).combined ?? Data()
    }

    /// 깨졌거나 키가 다르면 nil
    public static func decrypt(_ data: Data, key: VaultKey) -> [String: String]? {
        decrypt(data, with: key.key)
    }

    private static func decrypt(_ data: Data, with key: SymmetricKey) -> [String: String]? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: plain)
    }

    /// needsResave: 옛 고정 키로 저장된 파일이라 지금 키로 다시 써야 한다 (옮기기)
    public struct Loaded: Equatable {
        public let passwords: [String: String]
        public let needsResave: Bool
    }

    /// 지금 키로 못 풀면 옛 고정 키로 시도한다. 둘 다 안 되면(다른 Mac 의 파일·키 분실) 빈 목록 — 파일은 다음 저장 때 덮인다.
    public static func load(from url: URL = defaultURL, key: VaultKey) -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return Loaded(passwords: [:], needsResave: false) }
        if let passwords = decrypt(data, with: key.key) { return Loaded(passwords: passwords, needsResave: false) }
        if !key.isFallback, let passwords = decrypt(data, with: legacyKey) { return Loaded(passwords: passwords, needsResave: true) }
        return Loaded(passwords: [:], needsResave: false)
    }

    /// 비어 있으면 파일을 지운다. 쓸 때는 0600.
    /// 고정 키(키체인 실패)로는 고정 키로 못 푸는 파일을 덮지 않는다 — 키체인 키로 저장된 비밀번호를 잃지 않게.
    public static func save(_ passwords: [String: String], to url: URL = defaultURL, key: VaultKey) throws {
        if key.isFallback, let data = try? Data(contentsOf: url), decrypt(data, with: legacyKey) == nil {
            throw ConfigError(problem: "키체인에서 비밀번호 키를 읽지 못해 저장하지 않았습니다.", fix: "앱을 다시 실행하세요.", reference: url.path)
        }
        if passwords.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encrypt(passwords, key: key).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
