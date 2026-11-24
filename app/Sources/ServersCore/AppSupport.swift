// 앱 상태 폴더: ~/Library/Application Support/Servers (저장소 밖).
// servers.conf · passwords.bin · identities.json · recent.json · hosts.json · lan.json · snippets.json · bookmarks.json · notes.bin · history.json 이 여기 있다.

import Foundation

enum AppSupport {
    static var baseURL: URL {
        // 데모(`--demo`)는 임시 폴더 — 실제 상태 파일을 읽지도 쓰지도 않는다 (DemoMode)
        if DemoMode.active { return DemoMode.directory }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Servers")
    }
}

/// 상태 파일(JSON)의 공용 읽기·쓰기. 저장소마다 다른 것은 인자로: 날짜 꼴(recent · history 는 ISO 8601) · 들여쓰기(history 만 한 줄).
/// 못 읽었을 때 빈 값으로 삼킬지 오류로 막을지는 저장소가 정한다.
extension AppSupport {
    /// 파일이 없거나 못 읽거나 꼴이 틀리면 throw
    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL, isoDates: Bool = false) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if isoDates { decoder.dateDecodingStrategy = .iso8601 }
        return try decoder.decode(type, from: data)
    }

    /// 폴더가 없으면 만들고, 키 순으로 적어 통째로 바꿔 넣는다 (atomic)
    static func writeJSON<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true, isoDates: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        if isoDates { encoder.dateEncodingStrategy = .iso8601 }
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
