// 테스트가 함께 쓰는 준비 코드: 서버 값 하나 · 임시 자리 · 셸 문법 검사.

import Foundation
import XCTest
@testable import ServersCore

extension Server {
    /// 테스트용 서버 (그룹 g · 역할·태그·WOL 없음). 판정을 가르는 값(network · type · ip · check)은 기본값을 두지 않는다 —
    /// 파일마다 쓰던 값이 달라(check .tcp ↔ .ssh · ip) 부르는 쪽이 적는다.
    static func sample(key: String = "s", network: ServerNetwork, type: ServerType, ip: String, user: String = "u", port: Int = 22,
                       check: CheckMethod, vpn: String? = nil, extraUsers: [String] = []) -> Server {
        Server(key: key, group: "g", network: network, type: type, ip: ip, user: user, port: port,
               check: check, role: nil, env: nil, wolMac: nil, vpn: vpn, extraUsers: extraUsers)
    }
}

extension XCTestCase {
    /// 임시 자리 하나 (<이름>-<UUID>). 만들지는 않는다 — 폴더로 쓸지 파일로 쓸지, 없는 채로 둘지는 테스트가 정한다. 테스트가 끝나면 지운다.
    func tempPath(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// 셸의 문법 검사(-n)만 — 스크립트를 실행하지 않는다. 종료 코드 (0 이면 문법이 맞다)
func shellSyntaxStatus(_ shell: String, _ script: String, quiet: Bool = false) throws -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: shell); p.arguments = ["-n", "-c", script]
    if quiet { p.standardError = FileHandle.nullDevice }
    try p.run(); p.waitUntilExit()
    return p.terminationStatus
}
