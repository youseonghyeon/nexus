// 경로 [주소 검색]: 공인 IP 판정 · 물을 홉 고르기 · batch 응답 읽기 · 요청 모양 · 복사 텍스트

import Foundation
@testable import ServersCore
import XCTest

final class IPLocationTests: XCTestCase {
    /// 2026-10-15 실제 batch 응답
    private let batch = """
    [{"status":"success","countryCode":"KR","regionName":"Seoul","city":"Jung-gu","isp":"Korea Telecom","org":"KORNET","as":"AS4766 Korea Telecom","query":"198.51.100.185"},{"status":"success","countryCode":"AU","regionName":"Queensland","city":"South Brisbane","isp":"Cloudflare, Inc","org":"APNIC and Cloudflare DNS Resolver project","as":"AS13335 Cloudflare, Inc.","query":"1.1.1.1"},{"status":"success","countryCode":"US","regionName":"Virginia","city":"Ashburn","isp":"Google LLC","org":"Google Public DNS","as":"AS15169 Google LLC","query":"8.8.8.8"},{"status":"fail","message":"private range","query":"192.168.0.1"}]
    """

    func testIsPublic() {
        for ip in ["1.1.1.1", "198.51.100.185", "172.32.0.1", "100.128.0.1", "192.169.0.1"] { XCTAssertTrue(IPLocate.isPublic(ip), ip) }
        for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.1", "192.168.0.1", "100.64.0.1", "100.127.0.1", "127.0.0.1",
                   "169.254.1.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "fe80::1", "1.2.3", "a.b.c.d",
                   "1.2.x.3.4", "1.2.3.4.5", "1.2.3.4.x", "1..2.3.4"] {   // 숫자 칸만 세면 네 칸이라 통과하던 꼴
            XCTAssertFalse(IPLocate.isPublic(ip), ip)
        }
    }

    func testTargets() {
        let hops = [TraceHop(number: 1, address: "192.168.0.1", ms: 1), TraceHop(number: 2, address: nil, ms: nil),
                    TraceHop(number: 3, address: "198.51.100.185", ms: 3), TraceHop(number: 4, address: "100.64.0.1", ms: 4),
                    TraceHop(number: 5, address: "1.1.1.1", ms: 5), TraceHop(number: 6, address: "1.1.1.1", ms: 5)]
        XCTAssertEqual(IPLocate.targets(hops), ["198.51.100.185", "1.1.1.1"])
        XCTAssertEqual(IPLocate.targets([TraceHop(number: 1, address: "10.0.0.1", ms: 1)]), [], "사설만이면 묻지 않는다(버튼 꺼짐)")
    }

    func testParseBatch() throws {
        let result = try XCTUnwrap(IPLocate.parseBatch(batch))
        XCTAssertEqual(result["198.51.100.185"]?.text, "Jung-gu, Seoul, KR · AS4766 Korea Telecom · KORNET")
        XCTAssertEqual(result["8.8.8.8"]?.text, "Ashburn, Virginia, US · AS15169 Google LLC · Google Public DNS")
        XCTAssertNil(result["192.168.0.1"], "fail 은 빈칸")
        XCTAssertNil(IPLocate.parseBatch("<html>429</html>"))
        XCTAssertEqual(IPLocation(countryCode: "KR", isp: "Korea Telecom").text, "KR · Korea Telecom")
        XCTAssertEqual(IPLocation(countryCode: "KR", regionName: "Seoul", city: "Seoul", isp: "SK Broadband", org: "SK Broadband", as: "AS9318 SK Broadband Co Ltd").text,
                       "Seoul, KR · AS9318 SK Broadband Co Ltd", "도시와 같은 시·도, AS 에 든 org 는 한 번만")
    }

    func testLookupRequest() async {
        let runner = FakeRunner()
        runner.scripted["curl -fsS -m 5 -X POST -H Content-Type: application/json --data-binary @- --interface en11 \(IPLocate.url)"] =
            CommandResult(exitCode: 0, stdout: batch)
        let result = await IPLocate.lookup(["198.51.100.185", "1.1.1.1"], device: "en11", runner: runner)
        XCTAssertEqual(result?.count, 3)
        let failed = await IPLocate.lookup(["1.1.1.1"], device: "en0", runner: runner)
        XCTAssertNil(failed, "요청 실패면 nil")
        let empty = await IPLocate.lookup([], device: "en11", runner: runner)
        XCTAssertNil(empty)
    }

    func testReportTextWithLocations() {
        var ping = PingTestResult(target: "1.1.1.1", device: "en11")
        ping.hops = [TraceHop(number: 1, address: "192.168.8.1", ms: 2.0), TraceHop(number: 2, address: "1.1.1.1", ms: 9.5)]
        ping.locations = IPLocate.parseBatch(batch)
        XCTAssertTrue(ping.reportText.hasSuffix("  2  1.1.1.1  9.5 ms  South Brisbane, Queensland, AU · AS13335 Cloudflare, Inc. · APNIC and Cloudflare DNS Resolver project"))
        XCTAssertTrue(ping.reportText.contains("  1  192.168.8.1  2.0 ms\n"))
    }

    // MARK: 내 공인 IP + 위치 한 번에 (2026-11-13 이 Mac 의 ip-api.com 응답 모양)

    func testParseSelfLookup() {
        let ok = #"{"status":"success","countryCode":"KR","regionName":"Seoul","city":"Jung-gu","isp":"Korea Telecom","org":"KORNET","as":"AS4766 Korea Telecom","query":"203.0.113.7"}"#
        let found = IPLocate.parseSelf(ok)
        XCTAssertEqual(found?.ip, "203.0.113.7")
        XCTAssertEqual(found?.location.text, "Jung-gu, Seoul, KR · AS4766 Korea Telecom · KORNET")
        XCTAssertNil(IPLocate.parseSelf(#"{"status":"fail","message":"reserved range","query":"10.0.0.1"}"#), "실패 응답은 주소로 치지 않는다")
        XCTAssertNil(IPLocate.parseSelf(#"{"status":"success","query":"<html>"}"#), "주소 모양이 아니면 버린다 (가로챈 페이지)")
        XCTAssertNil(IPLocate.parseSelf("<html>Blocked</html>"))
        XCTAssertNil(IPLocate.parseSelf(""))
    }

    func testSelfLookupBindsDeviceWithTimeouts() async {
        let runner = FakeRunner()
        let command = "curl -4 -fsS --connect-timeout 2 --max-time 4 --interface utun5 http://ip-api.com/json/?fields=status,message,countryCode,regionName,city,isp,org,as,query"
        runner.scripted[command] = CommandResult(exitCode: 0, stdout: #"{"status":"success","countryCode":"JP","city":"Tokyo","as":"AS1 Example","query":"198.51.100.9"}"#)
        let found = await IPLocate.selfLookup(device: "utun5", runner: runner)
        XCTAssertEqual(found?.ip, "198.51.100.9")
        XCTAssertEqual(found?.location.text, "Tokyo, JP · AS1 Example")
        // 막힌 망: curl 이 시간 초과(28)로 끝나면 nil
        runner.scripted[command] = CommandResult(exitCode: 28)
        let blocked = await IPLocate.selfLookup(device: "utun5", runner: runner)
        XCTAssertNil(blocked)
        // 장치 이름이 이상하면 묻지 않는다
        let before = runner.calls.count
        let bad = await IPLocate.selfLookup(device: "utun5; rm", runner: runner)
        XCTAssertNil(bad)
        XCTAssertEqual(runner.calls.count, before)
    }
}
