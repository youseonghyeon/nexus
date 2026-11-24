// ServerDiagnose: 입력 검사 · 서버 스크립트 · 실제 출력 풀이 · [Run] 판정.
// Fixtures/diagnose-*.txt 는 스크립트를 로컬 ubuntu:24.04 컨테이너에서 돌린 실제 출력이다 (2026-11-18 — iputils 20240117 · curl 8.5.0 · 컨테이너 안 주소와 문서용 대역만).
// diagnose-openwrt-*.txt 는 openwrt/rootfs:x86-64-23.05.5 (BusyBox 1.36.1) — docker run --rm -i --platform linux/amd64 … sh -s. tcp-open 은 uhttpd 를 띄운 뒤.
//   docker run --rm -i ubuntu:24.04 sh -s < 스크립트   (ping·curl 은 apt 로 넣은 뒤. ping-missing 은 넣기 전 맨 이미지)

import Foundation
import XCTest
@testable import ServersCore

final class ServerDiagnoseTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try fixtureText("diagnose-\(name)")
    }
    private func request(_ tool: ServerDiagnose.Tool, _ input: String) throws -> ServerDiagnose.Request {
        try XCTUnwrap(ServerDiagnose.request(tool, input: input), input)
    }
    private func server(_ tool: ServerDiagnose.Tool, _ input: String, _ name: String) throws -> ServerDiagnose.Outcome {
        ServerDiagnose.parseServer(try request(tool, input), output: try fixture(name), ok: true)
    }

    // MARK: 입력 · 스크립트

    func testRequestValidatesLikeTheNetworkCard() {
        XCTAssertEqual(ServerDiagnose.request(.ping, input: " db.internal ")?.target, "db.internal")
        XCTAssertEqual(ServerDiagnose.request(.tcp, input: "192.0.2.10 5432")?.target, "192.0.2.10:5432")
        XCTAssertEqual(ServerDiagnose.request(.http, input: "localhost:3000/health")?.target, "http://localhost:3000/health")
        XCTAssertEqual(ServerDiagnose.request(.dns, input: "db.internal")?.target, "db.internal")
        // 셸로 넘어가는 값: 옵션·명령 끼워 넣기·공백은 입력 단계에서 걸러진다
        for (tool, bad) in [(ServerDiagnose.Tool.ping, "-f 192.0.2.1"), (.ping, "a;reboot"), (.ping, "$(id)"), (.ping, "a b"), (.tcp, "db.internal:5432"), (.tcp, "192.0.2.10:0"),
                            (.tcp, "192.0.2.10:22;id"), (.http, "http://a b"), (.http, "file:///etc/passwd"), (.http, "http://u:p@a.example"), (.dns, "-x"), (.dns, "a`id`"), (.dns, "")] {
            XCTAssertNil(ServerDiagnose.request(tool, input: bad), "\(tool) \(bad)")
        }
    }

    func testScriptsQuoteTheTargetAndReportWithMarkers() throws {
        let http = ServerDiagnose.script(try request(.http, "http://a.example/it's?x=$(id)&y=`id`"))
        XCTAssertTrue(http.contains(#"'http://a.example/it'\''s?x=$(id)&y=`id`'"#), "작은따옴표로 싸고 안의 따옴표만 풀어 준다 — $() · ` 는 글자 그대로")
        XCTAssertTrue(http.contains("--max-time 10") && http.contains("--noproxy '*'") && http.contains("exit=%{exitcode}"))
        let tcp = ServerDiagnose.script(try request(.tcp, "192.0.2.10:5432"))
        XCTAssertTrue(tcp.contains("timeout 3 bash -c 'exec 3<>/dev/tcp/192.0.2.10/5432'"))
        XCTAssertTrue(ServerDiagnose.script(try request(.ping, "db.internal")).contains("ping -c 5 -i 0.2 -W 1 'db.internal'"))
        XCTAssertTrue(ServerDiagnose.script(try request(.dns, "db.internal")).contains("getent ahosts 'db.internal'"))
        for tool in ServerDiagnose.Tool.allCases {
            let script = ServerDiagnose.script(try request(tool, tool == .tcp ? "192.0.2.1:1" : "a.example"))
            XCTAssertTrue(script.contains("@MISSING") && script.contains("@RC"), "\(tool)")
            XCTAssertFalse(script.contains("sudo"), "관리자 권한을 쓰지 않는다")
        }
    }

    // MARK: 서버 쪽 실제 출력

    func testServerPing() throws {
        XCTAssertEqual(try server(.ping, "127.0.0.1", "ping-ok"), .init(state: .ok, headline: "0.1 ms · Jitter 0.0 ms"))
        XCTAssertEqual(try server(.ping, "192.0.2.1", "ping-lost"), .init(state: .failed, headline: "응답 없음"))
        XCTAssertEqual(try server(.ping, "no-such-host.invalid", "ping-noname"), .init(state: .failed, headline: "이름을 찾지 못했습니다"))
        XCTAssertEqual(try server(.ping, "127.0.0.1", "ping-missing"), .init(state: .unavailable, headline: "서버에 ping 이(가) 없습니다"))
    }

    func testServerTCPTellsRefusedFromFiltered() throws {
        XCTAssertEqual(try server(.tcp, "127.0.0.1:8080", "tcp-open"), .init(state: .ok, headline: "열림 · 5 ms"))
        XCTAssertEqual(try server(.tcp, "127.0.0.1:9", "tcp-refused"), .init(state: .failed, headline: "거부됨 (닫힘)"))
        XCTAssertEqual(try server(.tcp, "192.0.2.1:81", "tcp-timeout"), .init(state: .failed, headline: "응답 없음 (막힘 · 시간 초과)"))
    }

    func testServerHTTP() throws {
        let ok = try server(.http, "http://127.0.0.1:8081/", "http-ok")
        XCTAssertEqual(ok.state, .ok)
        XCTAssertEqual(ok.headline, "200 성공", "걸린 시간은 결과 줄이 아니라 시간 줄에 (진단 카드와 같게)")
        XCTAssertEqual(ok.check?.status, 200, "화면은 curl 값 그대로 받아 진단 카드와 같은 줄로 그린다")
        XCTAssertEqual(ok.check?.endpoint, "127.0.0.1:8081")
        XCTAssertNotNil(ok.check?.stages?.dnsMs, "시간 막대의 재료")
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(ok.addresses, ["127.0.0.1"])
        XCTAssertEqual(ok.lines.first, "연결: 127.0.0.1:8081")
        let refused = try server(.http, "http://127.0.0.1:9/", "http-refused")
        XCTAssertEqual(refused.state, .failed)
        XCTAssertEqual(refused.headline, "연결 실패")
        XCTAssertEqual(refused.check?.failureText, "연결 실패")
        XCTAssertEqual(refused.lines.first, "상세: Failed to connect to 127.0.0.1 port 9 after 0 ms: Couldn't connect to server")
        XCTAssertEqual(try server(.http, "http://no-such-host.invalid/", "http-noname").headline, "이름을 찾지 못했습니다")
        XCTAssertEqual(try server(.http, "http://127.0.0.1/", "http-missing"), .init(state: .unavailable, headline: "서버에 curl 이(가) 없습니다"))
    }

    /// 옛 curl 은 %{exitcode}·%{errormsg} 를 몰라 그 줄이 비어 온다 — 셸의 종료 코드로 채운다
    func testServerHTTPOldCurlWithoutExitcode() throws {
        let old = "exit=\ncode=200\nscheme=HTTP\nip=192.0.2.10\nport=80\ndns=0.001\nconnect=0.002\ntls=0.000\nfirst=0.010\ntotal=0.020\nredirect=\nerror=\n@RC 0\n"
        let outcome = ServerDiagnose.parseServer(try request(.http, "http://192.0.2.10/"), output: old, ok: true)
        XCTAssertEqual(outcome.state, .ok); XCTAssertEqual(outcome.status, 200)
        let failed = ServerDiagnose.parseServer(try request(.http, "http://192.0.2.10/"), output: old.replacingOccurrences(of: "code=200", with: "code=000").replacingOccurrences(of: "@RC 0", with: "@RC 7"), ok: true)
        XCTAssertEqual(failed.headline, "연결 실패")
    }

    func testServerDNS() throws {
        let ok = try server(.dns, "localhost", "dns-ok")
        XCTAssertEqual(ok, .init(state: .ok, headline: "127.0.0.1", addresses: ["127.0.0.1"], ms: 1), "STREAM·DGRAM·RAW 로 여러 번 나온 주소는 한 번만")
        XCTAssertEqual(try server(.dns, "no-such-host.invalid", "dns-none"), .init(state: .failed, headline: "이름을 찾지 못했습니다"))
        XCTAssertEqual(ServerDiagnose.getentAddresses("192.0.2.10 STREAM a\n2001:db8::1 STREAM a\n192.0.2.10 DGRAM\n192.0.2.11 RAW\n"), ["192.0.2.10", "2001:db8::1", "192.0.2.11"])
        let many = ServerDiagnose.dns(addresses: (1...6).map { "192.0.2.\($0)" }, ms: nil)
        XCTAssertEqual(many.headline, "192.0.2.1, 192.0.2.2, 192.0.2.3, 192.0.2.4 외 2")
        // IPv6 는 결과 줄이 아니라 IPv6 줄로 (진단 카드와 같게)
        let mixed = ServerDiagnose.dns(addresses: ["192.0.2.10", "2001:db8::1"], ms: 3)
        XCTAssertEqual(mixed.headline, "192.0.2.10"); XCTAssertEqual(mixed.addresses6, ["2001:db8::1"]); XCTAssertEqual(mixed.lines, ["IPv6: 2001:db8::1"])
        let only6 = ServerDiagnose.dns(addresses: ["2001:db8::1"], ms: nil)
        XCTAssertEqual(only6.headline, "IPv4 주소 없음"); XCTAssertEqual(only6.state, .ok)
    }

    // MARK: OpenWrt (BusyBox)

    private func openwrt(_ tool: ServerDiagnose.Tool, _ input: String, _ name: String) throws -> ServerDiagnose.Outcome {
        ServerDiagnose.parseServer(try request(tool, input), output: try fixture("openwrt-\(name)"), ok: true, type: .openwrt)
    }

    /// BusyBox 에 없는 것(bash · timeout · getent · ping 의 소수 간격 · date 의 나노초)을 쓰지 않는다. http 는 linux 와 같다 (curl 이 있으면)
    func testOpenWrtScriptsUseOnlyBusyBox() throws {
        for tool in [ServerDiagnose.Tool.ping, .tcp, .dns] {
            let script = ServerDiagnose.script(try request(tool, tool == .tcp ? "192.0.2.1:22" : "a.example"), type: .openwrt)
            for missing in ["bash", "timeout ", "getent", "-i 0.2", "%N", "sudo"] { XCTAssertFalse(script.contains(missing), "\(tool) \(missing)") }
            XCTAssertTrue(script.contains("@MISSING") && script.contains("@RC"), "\(tool)")
        }
        XCTAssertTrue(ServerDiagnose.script(try request(.ping, "a.example"), type: .openwrt).contains("ping -c 5 -W 1 'a.example'"))
        XCTAssertTrue(ServerDiagnose.script(try request(.dns, "a.example"), type: .openwrt).contains("nslookup 'a.example'"))
        let tcp = ServerDiagnose.script(try request(.tcp, "192.0.2.1:22"), type: .openwrt)
        XCTAssertTrue(tcp.contains("nc 192.0.2.1 22 </dev/null") && tcp.contains("max=30") && tcp.contains("max=3;"), "3초까지만 기다린다 (sleep 이 소수를 모르면 1초씩 세 번)")
        let http = try request(.http, "http://a.example/")
        XCTAssertEqual(ServerDiagnose.script(http, type: .openwrt), ServerDiagnose.script(http))
        // linux 스크립트는 그대로
        XCTAssertTrue(ServerDiagnose.script(try request(.dns, "a.example"), type: .linux).contains("getent ahosts"))
    }

    func testOpenWrtActualOutput() throws {
        XCTAssertEqual(try openwrt(.ping, "127.0.0.1", "ping-ok"), .init(state: .ok, headline: "0.2 ms"), "BusyBox 요약 줄엔 mdev 가 없다 — Jitter 없이")
        XCTAssertEqual(try openwrt(.ping, "192.0.2.1", "ping-lost"), .init(state: .failed, headline: "응답 없음"))
        XCTAssertEqual(try openwrt(.ping, "no-such-host.invalid", "ping-noname"), .init(state: .failed, headline: "이름을 찾지 못했습니다"))
        XCTAssertEqual(try openwrt(.tcp, "127.0.0.1:8080", "tcp-open"), .init(state: .ok, headline: "열림"), "걸린 시간은 재지 않는다")
        XCTAssertEqual(try openwrt(.tcp, "127.0.0.1:9", "tcp-refused"), .init(state: .failed, headline: "거부됨 (닫힘)"))
        XCTAssertEqual(try openwrt(.tcp, "192.0.2.1:81", "tcp-timeout"), .init(state: .failed, headline: "응답 없음 (막힘 · 시간 초과)"))
        let dns = try openwrt(.dns, "localhost", "dns-ok")
        XCTAssertEqual(dns.addresses, ["::1", "127.0.0.1"], "앞머리의 리졸버 주소(Server · Address)는 답이 아니다")
        XCTAssertEqual(dns.headline, "127.0.0.1"); XCTAssertEqual(dns.addresses6, ["::1"])
        XCTAssertEqual(try openwrt(.dns, "no-such-host.invalid", "dns-none"), .init(state: .failed, headline: "이름을 찾지 못했습니다"))
        XCTAssertEqual(try openwrt(.http, "http://127.0.0.1:8080/", "http-missing"), .init(state: .unavailable, headline: "서버에 curl 이(가) 없습니다"))
        // 옛 BusyBox 꼴 ("Address 1: 주소 이름")
        XCTAssertEqual(ServerDiagnose.nslookupAddresses("Server:    127.0.0.1\nAddress 1: 127.0.0.1 localhost\n\nName:      a.example\nAddress 1: 192.0.2.10 a.example\nAddress 2: 2001:db8::1\n"), ["192.0.2.10", "2001:db8::1"])
    }

    /// ssh 가 실패했거나 출력이 끊겼으면 "안 됨"이 아니라 "재지 못함" — 서버에서 안 되는 것과 서버에 못 들어간 것은 다르다
    func testServerRunFailureIsUnavailableNotFailed() throws {
        let ping = try request(.ping, "192.0.2.1")
        XCTAssertEqual(ServerDiagnose.parseServer(ping, output: "", ok: false, failure: "인증이 필요합니다"), .init(state: .unavailable, headline: "인증이 필요합니다"))
        XCTAssertEqual(ServerDiagnose.parseServer(ping, output: "", ok: false).state, .unavailable)
        XCTAssertEqual(ServerDiagnose.parseServer(ping, output: "PING 192.0.2.1\n", ok: true).state, .unavailable, "끝 표시(@RC)가 없다 — 도중에 끊겼다")
    }

    // MARK: 한 번의 실행

    func testRunReport() throws {
        var run = ServerDiagnose.Run(request: try request(.tcp, "192.0.2.10:5432"), at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(run.running)
        XCTAssertTrue(run.reportText(serverKey: "web01").hasSuffix("결과: 재는 중"))
        run.outcome = .init(state: .failed, headline: "거부됨 (닫힘)", lines: ["연결: 192.0.2.10:5432"], ms: 4)
        XCTAssertFalse(run.running)
        let report = run.reportText(serverKey: "web01").split(separator: "\n").map(String.init)
        XCTAssertTrue(report[0].hasPrefix("TCP 192.0.2.10:5432 · web01 에서 · "))
        XCTAssertEqual(Array(report.dropFirst()), ["결과: 거부됨 (닫힘) · 4 ms", "연결: 192.0.2.10:5432"])
    }

    // MARK: 탭 · [Run]

    /// [Run] 상태 표: 서버가 응답 중이고 · 돌고 있지 않고 · 입력이 꼴에 맞을 때만. 빈 입력(처음 연 탭)은 꺼져 있다
    func testCanRunTable() {
        let rows: [(ServerDiagnose.Tool, String, Bool, Bool, Bool)] = [
            (.ping, "", true, false, false),                 // 처음 연 탭
            (.ping, "192.0.2.1", true, false, true),
            (.ping, "192.0.2.1", false, false, false),       // 서버가 응답하지 않는다 — 잴 수 없다
            (.ping, "192.0.2.1", true, true, false),         // 재는 중
            (.tcp, "192.0.2.1", true, false, false),         // 포트가 없다
            (.tcp, "192.0.2.1:22", true, false, true),
            (.http, "a.example/health", true, false, true),
            (.http, "ftp://a.example", true, false, false),
            (.dns, "a.example", true, false, true),
            (.dns, "a b", true, false, false),
        ]
        for (tool, input, reachable, running, expected) in rows {
            XCTAssertEqual(ServerDiagnoseRun.canRun(tool, input: input, reachable: reachable, running: running), expected, "\(tool) '\(input)' reachable=\(reachable) running=\(running)")
        }
    }

    /// Diagnose 탭은 linux · openwrt 만, 가져오는 조회가 아니다 (새로고침·자동 조회·확인 시각이 없다 — Live 와 같은 갈래)
    func testDiagnoseTabIsLinuxAndOpenWrtAndNotAFetch() {
        XCTAssertTrue(RemoteCommands.supports(.diagnose, type: .linux))
        XCTAssertFalse(RemoteCommands.supports(.diagnose, type: .windows))
        XCTAssertTrue(RemoteCommands.supports(.diagnose, type: .openwrt))
        for type in [ServerType.linux, .windows, .openwrt] {
            XCTAssertNil(RemoteCommands.query(.diagnose, for: type), "조회 명령이 없다")
            for query in RemoteCommands.Query.allCases where query != .diagnose {
                XCTAssertEqual(RemoteCommands.supports(query, type: type), RemoteCommands.query(query, for: type) != nil, "\(type) \(query) — 다른 탭은 그대로")
            }
        }
        XCTAssertEqual(RemoteCommands.Query.allCases.filter { !$0.fetches }, [.diagnose, .live])
        XCTAssertFalse(RemoteInfoTabs.fetchesOnSelect(.diagnose, fetchedAt: nil), "탭을 골라도 서버에 아무것도 보내지 않는다")
        XCTAssertTrue(RemoteInfoTabs.canSwitch(reachable: false, current: .diagnose, currentFetchedAt: nil), "서버가 꺼져도 다른 탭으로 옮길 수 있다")
        XCTAssertEqual(RemoteCommands.Query.diagnose.title, "Diagnose")
    }
}
