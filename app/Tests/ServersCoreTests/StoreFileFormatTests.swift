// 상태 파일(JSON 저장소 일곱)의 글자 단위 형식: 키 순서 · 들여쓰기 · 날짜 꼴 · 깨진 파일 처리.
// 사용자의 실제 파일이 이 꼴이라, 읽기·쓰기 구현을 바꿔도 달라지면 안 된다 (2026-11-24 공용 읽기·쓰기로 모으기 전에 넣은 테스트).

import Foundation
import XCTest
@testable import ServersCore

final class StoreFileFormatTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = tempPath("store-format")
    }

    /// 폴더가 없던 자리(Servers/ 아래)에 저장한 파일의 글
    private func written(_ name: String, _ save: (URL) throws -> Void) throws -> String {
        let url = dir.appendingPathComponent("Servers/\(name)")
        try save(url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let date = Date(timeIntervalSince1970: 1_763_000_000)

    func testPrettyStoresWriteSortedIndentedJSON() throws {
        XCTAssertEqual(try written("lan.json") { try LanStore.save(LanSettings(service: "Office LAN"), to: $0) }, """
        {
          "service" : "Office LAN"
        }
        """)
        XCTAssertEqual(try written("identities.json") { try IdentityStore.save(["web": "/Users/me/.ssh/a b.pem", "db": "/k"], to: $0) }, #"""
        {
          "db" : "\/k",
          "web" : "\/Users\/me\/.ssh\/a b.pem"
        }
        """#)
        XCTAssertEqual(try written("hosts.json") { try HostAliasStore.save(HostAliasState(assignments: ["was-db": "127.0.0.3", "db": "127.0.0.2"]), to: $0) }, """
        {
          "assignments" : {
            "db" : "127.0.0.2",
            "was-db" : "127.0.0.3"
          }
        }
        """)
        let bookmarks = BookmarkState(servers: ["web": [BrowserBookmark(url: "http://localhost:3000/d/x", title: "결제 지연", icon: "data:image/png;base64,AAAA"),
                                                        BrowserBookmark(url: "https://example.com", title: "e")]])
        XCTAssertEqual(try written("bookmarks.json") { try BookmarkStore.save(bookmarks, to: $0) }, #"""
        {
          "servers" : {
            "web" : [
              {
                "icon" : "data:image\/png;base64,AAAA",
                "title" : "결제 지연",
                "url" : "http:\/\/localhost:3000\/d\/x"
              },
              {
                "title" : "e",
                "url" : "https:\/\/example.com"
              }
            ]
          }
        }
        """#)
        let snippets = SnippetState(snippets: [CommandSnippet(id: id, type: .linux, title: "t", command: "df -h\nuptime", runImmediately: true, sensitive: false)])
        XCTAssertEqual(try written("snippets.json") { try SnippetStore.save(snippets, to: $0) }, #"""
        {
          "snippets" : [
            {
              "command" : "df -h\nuptime",
              "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
              "runImmediately" : true,
              "sensitive" : false,
              "title" : "t",
              "type" : "linux"
            }
          ]
        }
        """#)
    }

    /// recent.json: 날짜는 ISO 8601 (초 아래는 버린다), 없는 값의 키는 쓰지 않는다
    func testRecentStoreWritesISODates() throws {
        let state = RecentState(tunnels: [
            RecentTunnel(serverKey: "was", kind: .db(host: "192.0.2.6", port: 5432, name: "acme"), localPort: 15432, lastUsed: date, bindAddress: "127.0.0.2", hostName: "db.acme", user: "ops"),
            RecentTunnel(serverKey: "win", kind: .port(remotePort: 443), localPort: 8443, lastUsed: date.addingTimeInterval(0.5)),
        ])
        XCTAssertEqual(try written("recent.json") { try RecentStore.save(state, to: $0) }, """
        {
          "tunnels" : [
            {
              "bindAddress" : "127.0.0.2",
              "hostName" : "db.acme",
              "kind" : {
                "db" : {
                  "host" : "192.0.2.6",
                  "name" : "acme",
                  "port" : 5432
                }
              },
              "lastUsed" : "2025-11-13T02:13:20Z",
              "localPort" : 15432,
              "serverKey" : "was",
              "user" : "ops"
            },
            {
              "kind" : {
                "port" : {
                  "remoteHost" : "127.0.0.1",
                  "remotePort" : 443
                }
              },
              "lastUsed" : "2025-11-13T02:13:20Z",
              "localPort" : 8443,
              "serverKey" : "win"
            }
          ]
        }
        """)
        XCTAssertEqual(RecentStore.load(from: dir.appendingPathComponent("Servers/recent.json")).tunnels.map(\.lastUsed), [date, date], "읽으면 초 단위")
    }

    /// history.json 만 한 줄로 쓴다 (들여쓰기 없음), 날짜는 ISO 8601
    func testHistoryWritesCompactJSON() throws {
        let entry = HistoryState.Entry(snapshot: ServerSnapshot(spec: ["OS": "Ubuntu 24.04"], updates: ["curl": .init(version: "8.5", security: true)], ports: ["22": "ssh", "80": ""],
                                                             failed: ["broken"], containers: ["docker|web": "nginx:1.27"]),
                                       events: [HistoryEvent(id: id, at: date, kind: .portOpened, text: "80 열림")])
        let state = HistoryState(servers: ["web01": entry, "db": HistoryState.Entry()])
        XCTAssertEqual(try written("history.json") { try ServerHistory.save(state, to: $0) },
                       #"{"servers":{"db":{"events":[],"snapshot":{}},"web01":{"events":[{"at":"2025-11-13T02:13:20Z","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"portOpened","text":"80 열림"}],"#
                       + #""snapshot":{"containers":{"docker|web":"nginx:1.27"},"failed":["broken"],"ports":{"22":"ssh","80":""},"spec":{"OS":"Ubuntu 24.04"},"updates":{"curl":{"security":true,"version":"8.5"}}}}}}"#)
        XCTAssertEqual(ServerHistory.load(from: dir.appendingPathComponent("Servers/history.json")), state)
    }

    /// 다시 저장하면 통째로 바뀐다 (이어 쓰지 않는다)
    func testSaveReplacesTheWholeFile() throws {
        let url = dir.appendingPathComponent("Servers/identities.json")
        try IdentityStore.save(["web": "/a", "db": "/b"], to: url)
        try IdentityStore.save([:], to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\n\n}")
    }

    /// 없는 파일 · 깨진 파일 · 꼴이 다른 JSON: 부가 기능 다섯은 빈 값, 설정의 원천 둘(lan · snippets)은 없으면 빈 값이고 못 읽으면 오류
    func testMissingAndBrokenFiles() throws {
        let url = dir.appendingPathComponent("Servers/x.json")
        func check(_ label: String) throws {
            XCTAssertEqual(BookmarkStore.load(from: url), BookmarkState(), label)
            XCTAssertEqual(HostAliasStore.load(from: url), HostAliasState(), label)
            XCTAssertEqual(RecentStore.load(from: url), RecentState(), label)
            XCTAssertEqual(IdentityStore.load(from: url), [:], label)
            XCTAssertEqual(ServerHistory.load(from: url), HistoryState(), label)
        }
        try check("없음")
        XCTAssertNil(try LanStore.load(from: url))
        XCTAssertEqual(try SnippetStore.load(from: url), SnippetState())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (label, text) in [("깨짐", "{ broken"), ("빈 파일", ""), ("다른 꼴", "[1, 2]")] {
            try Data(text.utf8).write(to: url)
            try check(label)
            XCTAssertThrowsError(try LanStore.load(from: url), label) { XCTAssertTrue($0 is DecodingError, "\(label): \($0)") }
            XCTAssertThrowsError(try SnippetStore.load(from: url), label) { XCTAssertEqual(($0 as? ConfigError)?.reference, url.path, label) }
        }
        // 날짜가 ISO 꼴이 아닌 recent.json 은 깨진 것으로 본다
        try Data(#"{"tunnels":[{"kind":{"port":{"remoteHost":"127.0.0.1","remotePort":443}},"lastUsed":784692800,"localPort":8443,"serverKey":"win"}]}"#.utf8).write(to: url)
        XCTAssertEqual(RecentStore.load(from: url), RecentState())
    }
}
