// 내부망 설정(앱 저장소). ~/Library/Application Support/Servers/lan.json (저장소 밖).
//   service  Intranet 으로 지정한 macOS 네트워크 서비스 하나 — 상태·켜기/끄기·BindInterface 의 대상.
// Intranet 도 그냥 유선 서비스다: 지정은 이 기록 + 서비스 순서 맨 뒤로(한 번), 켜기·끄기는 다른 유선과 같은 활성화·비활성화 (2026-10-15 단순화).
// 파일이 없으면 servers.conf [network:lan] 값으로 만들고, 그 뒤로는 이 파일이 원천이다.
// 예전 파일의 activeService·orderAnchors·routes 는 읽지 않는다 (고른 것/실제 켜진 것 이중 기록·전환·순서 되돌리기는 뺐다).

import Foundation

public struct LanSettings: Codable, Sendable, Equatable {
    public var service: String

    public init(service: String) {
        self.service = service
    }
}

public enum LanStore {
    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("lan.json") }

    /// 파일이 없으면 nil. 있는데 못 읽으면 throw — 설정의 원천이라 조용히 비우지 않는다.
    public static func load(from url: URL = defaultURL) throws -> LanSettings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AppSupport.readJSON(LanSettings.self, from: url)
    }

    public static func save(_ settings: LanSettings, to url: URL = defaultURL) throws {
        try AppSupport.writeJSON(settings, to: url)
    }

    /// 첫 실행: 파일이 없으면 servers.conf 값(service)으로 만들어 저장한다. 있으면 seed 는 무시한다.
    public static func loadOrSeed(service: String, url: URL = defaultURL) throws -> LanSettings {
        if let existing = try load(from: url) { return existing }
        let settings = LanSettings(service: service)
        try save(settings, to: url)
        return settings
    }
}
