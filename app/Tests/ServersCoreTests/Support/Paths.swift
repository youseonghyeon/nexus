// 테스트가 읽는 저장소 파일 위치: 픽스처(Fixtures/) · 앱 폴더(Resources/) · 저장소 루트(lib/ · servers.conf).

import Foundation

enum TestPaths {
    /// app/Tests/ServersCoreTests
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    /// app
    static let appDir = testsDir.deletingLastPathComponent().deletingLastPathComponent()
    static let repoRoot = appDir.deletingLastPathComponent()
}

/// Fixtures/<name>.txt 의 내용 (이름은 확장자 없이)
func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: TestPaths.testsDir.appendingPathComponent("Fixtures/\(name).txt"), encoding: .utf8)
}

/// Fixtures/<file> 의 바이트 (이름은 확장자까지 — .pcap · .bin)
func fixtureBytes(_ file: String) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: TestPaths.testsDir.appendingPathComponent("Fixtures/\(file)")))
}
