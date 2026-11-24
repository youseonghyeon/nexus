// AppModel · 모델에서 옮긴 출력 → 값 · 문구 (2026-11-24): Wi-Fi 주소 · 링크 있는 어댑터 · 미등록 피어 · 캡처 종료 문구 ·
// 사이드바 System · Disk 요약 · 브라우저 오류 페이지 · 내려받기 이름. 기댓값은 옮기기 전 코드의 분기를 읽어 적은 것.
// 명령을 돌리는 쪽(AppModel)은 그대로라 여기는 러너 없이 글만 넣는다. 주소는 문서용 대역.

import Foundation
@testable import ServersCore
import XCTest

final class ModelTextTests: XCTestCase {
    // MARK: Wi-Fi 주소

    func testParseIfAddr() {
        XCTAssertEqual(NetworkInfoFetcher.parseIfAddr(CommandResult(exitCode: 0, stdout: "192.0.2.44\n")), "192.0.2.44")
        XCTAssertEqual(NetworkInfoFetcher.parseIfAddr(CommandResult(exitCode: 0, stdout: "  192.0.2.44  \n\n")), "192.0.2.44")
        XCTAssertNil(NetworkInfoFetcher.parseIfAddr(CommandResult(exitCode: 0, stdout: "")))      // 주소 없음
        XCTAssertNil(NetworkInfoFetcher.parseIfAddr(CommandResult(exitCode: 0, stdout: "\n")))
        XCTAssertNil(NetworkInfoFetcher.parseIfAddr(CommandResult(exitCode: 1, stdout: "", stderr: "get if addr en0 failed")))
        XCTAssertNil(NetworkInfoFetcher.parseIfAddr(CommandResult(exitCode: 1, stdout: "192.0.2.44\n")))   // 실패면 글이 있어도 안 쓴다
    }

    func testWiFiAddress() {
        let dhcp = """
        DHCP Configuration
        IP address: 192.0.2.44
        Subnet mask: 255.255.255.0
        Router: 192.0.2.1
        Client ID:
        Wi-Fi ID: 02:00:5e:00:53:01
        """
        // 장치에 붙은 주소가 먼저, 나머지는 서비스 설정
        var a = NetworkInfoFetcher.wifiAddress(getInfo: dhcp, actualIP: "192.0.2.50")
        XCTAssertEqual(a.ip, "192.0.2.50"); XCTAssertEqual(a.subnet, "255.255.255.0")
        XCTAssertEqual(a.router, "192.0.2.1"); XCTAssertEqual(a.configuration, "DHCP Configuration")
        // 연결 안 됨(장치 주소를 안 읽음): 서비스 설정의 주소
        a = NetworkInfoFetcher.wifiAddress(getInfo: dhcp, actualIP: nil)
        XCTAssertEqual(a.ip, "192.0.2.44")
        // DHCP 가 아직 못 받음: "(null)" · "none" 은 빈 값
        a = NetworkInfoFetcher.wifiAddress(getInfo: "DHCP Configuration\nIP address: none\nSubnet mask: (null)\nRouter: (null)\n", actualIP: nil)
        XCTAssertNil(a.ip); XCTAssertNil(a.subnet); XCTAssertNil(a.router); XCTAssertEqual(a.configuration, "DHCP Configuration")
        // 서비스를 못 읽음 (빈 출력 · 오류 글)
        a = NetworkInfoFetcher.wifiAddress(getInfo: "", actualIP: nil)
        XCTAssertNil(a.ip); XCTAssertNil(a.subnet); XCTAssertNil(a.router); XCTAssertNil(a.configuration)
        a = NetworkInfoFetcher.wifiAddress(getInfo: "", actualIP: "192.0.2.50")
        XCTAssertEqual(a.ip, "192.0.2.50"); XCTAssertNil(a.subnet)
    }

    // MARK: [서비스 추가…] 어댑터 후보

    func testHardwarePortLinkActive() {
        let active = "en8: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tether 02:00:5e:00:53:02\n\tmedia: autoselect (1000baseT <full-duplex>)\n\tstatus: active\n"
        XCTAssertTrue(HardwarePort.linkActive(ifconfig: active))
        XCTAssertFalse(HardwarePort.linkActive(ifconfig: active.replacingOccurrences(of: "status: active", with: "status: inactive")))
        XCTAssertFalse(HardwarePort.linkActive(ifconfig: "en8: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500\n"))   // status 줄 없음
        XCTAssertFalse(HardwarePort.linkActive(ifconfig: ""))   // 장치가 없다 (ifconfig 실패)
    }

    // MARK: 미등록 Tailscale 피어

    func testUnregisteredTailscalePeers() {
        let json = """
        {"BackendState":"Running","Version":"1.80.0","MagicDNSSuffix":"example.ts.net",
         "Self":{"HostName":"mac","DNSName":"mac.example.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true,"OS":"macOS"},
         "Peer":{
          "a":{"HostName":"web-01","DNSName":"web-01.example.ts.net.","TailscaleIPs":["100.64.0.11","fd7a::11"],"Online":true,"OS":"linux"},
          "b":{"HostName":"db-01","DNSName":"db-01.example.ts.net.","TailscaleIPs":["100.64.0.12"],"Online":false,"OS":"linux"}}}
        """
        let all = TailscalePeers.parse(json)
        XCTAssertEqual(all.map(\.name), ["web-01", "db-01"])   // 픽스처가 읽히는지 (online 먼저)
        XCTAssertEqual(TailscalePeers.unregistered(json, registeredIPs: []).map(\.name), ["web-01", "db-01"])   // 서버 0대 (빈 목록)
        XCTAssertEqual(TailscalePeers.unregistered(json, registeredIPs: ["100.64.0.11"]).map(\.name), ["db-01"])
        XCTAssertEqual(TailscalePeers.unregistered(json, registeredIPs: ["100.64.0.11", "100.64.0.12", "192.0.2.9"]), [])
        XCTAssertEqual(TailscalePeers.unregistered(json, registeredIPs: ["fd7a::11"]).map(\.name), ["web-01", "db-01"])   // IPv4 로만 견준다
        XCTAssertEqual(TailscalePeers.unregistered("not json", registeredIPs: []), [])
    }

    // MARK: 패킷 캡처가 끝난 이유

    func testCaptureEndText() {
        // 받은 데이터의 문제가 먼저
        XCTAssertEqual(CaptureCommand.endText(pipelineFailure: "pcap 머리를 읽지 못했습니다", stderr: "tcpdump: syntax error\n", code: 1),
                       "pcap 머리를 읽지 못했습니다")
        // tcpdump 가 말한 이유 그대로
        XCTAssertEqual(CaptureCommand.endText(pipelineFailure: nil, stderr: "tcpdump: can't parse filter expression: syntax error\n", code: 1),
                       "tcpdump: can't parse filter expression: syntax error")
        // 인증 실패는 말을 붙인다 (sudo · password 가 든 줄)
        XCTAssertEqual(CaptureCommand.endText(pipelineFailure: nil, stderr: "sudo: a password is required\n", code: 1),
                       "관리자 인증을 받지 못했습니다 (sudo: a password is required)")
        XCTAssertEqual(CaptureCommand.endText(pipelineFailure: nil, stderr: "Sorry, try again.\n3 incorrect password attempts\n", code: 1),
                       "관리자 인증을 받지 못했습니다 (3 incorrect password attempts)")
        // 이유 없이 끝남: 안내 줄뿐이거나 빈 출력
        XCTAssertEqual(CaptureCommand.endText(pipelineFailure: nil, stderr: "tcpdump: listening on en0, link-type EN10MB (Ethernet), snapshot length 256 bytes\n", code: 0),
                       "캡처가 끝났습니다 (종료 코드 0)")
        XCTAssertEqual(CaptureCommand.endText(pipelineFailure: nil, stderr: "", code: 137), "캡처가 끝났습니다 (종료 코드 137)")
    }

    // MARK: 사이드바 System · Disk 요약

    func testSystemSidebarSummary() {
        XCTAssertEqual(SystemSnapshot.sidebarSummary(nil), "확인 중…")
        var snapshot = SystemSnapshot(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(SystemSnapshot.sidebarSummary(snapshot), "CPU – · 메모리 –")   // 첫 표본: 차이를 못 낸다
        snapshot.cpu = CPUUsage(total: 12.5, user: 8, system: 4.5, idle: 87.5, cores: [])
        XCTAssertEqual(SystemSnapshot.sidebarSummary(snapshot), "CPU 13% · 메모리 –")   // 반올림(.5 는 올림)
        let gb: UInt64 = 1 << 30
        snapshot.memory = MemoryBreakdown(total: 16 * gb, app: 6 * gb, wired: 3 * gb, compressed: 1 * gb, stored: 2 * gb, cached: 4 * gb)
        XCTAssertEqual(SystemSnapshot.sidebarSummary(snapshot), "CPU 13% · 메모리 63%")   // 10/16 = 62.5
        snapshot.cpu = nil
        XCTAssertEqual(SystemSnapshot.sidebarSummary(snapshot), "CPU – · 메모리 63%")
        snapshot.cpu = CPUUsage(total: 99.6, user: 90, system: 9.6, idle: 0.4, cores: [])
        XCTAssertEqual(SystemSnapshot.sidebarSummary(snapshot), "CPU 100% · 메모리 63%")
    }

    func testDiskSidebarSummary() {
        XCTAssertEqual(StorageUsage.sidebarSummary(nil), "확인 중…")
        let gb: UInt64 = 1_000_000_000
        XCTAssertEqual(StorageUsage.sidebarSummary(StorageUsage(used: 380 * gb, free: 120 * gb)), "\(DiskFormat.bytes(120 * gb)) 남음 · 76% 사용")
        XCTAssertEqual(StorageUsage.sidebarSummary(StorageUsage(used: 0, free: 0)), "\(DiskFormat.bytes(UInt64(0))) 남음 · 0% 사용")   // 크기 0 (나누기 0 아님)
        XCTAssertEqual(StorageUsage.sidebarSummary(StorageUsage(used: 500 * gb, free: 0)), "\(DiskFormat.bytes(UInt64(0))) 남음 · 100% 사용")
        XCTAssertTrue(StorageUsage.sidebarSummary(StorageUsage(used: 380 * gb, free: 120 * gb)).hasPrefix("120"))   // 10진 단위
    }

    // MARK: 브라우저 오류 페이지 · 내려받기

    func testBrowserErrorMessageTable() {
        let rows: [(Int, String, String)] = [
            (NSURLErrorCannotConnectToHost, "연결할 수 없습니다", "이 주소에서 응답하는 서버가 없습니다."),
            (NSURLErrorTimedOut, "응답이 없습니다", "서버가 제한 시간 안에 응답하지 않았습니다."),
            (NSURLErrorCannotFindHost, "주소를 찾을 수 없습니다", "서버 이름을 확인하세요."),
            (NSURLErrorDNSLookupFailed, "주소를 찾을 수 없습니다", "서버 이름을 확인하세요."),
            (NSURLErrorNetworkConnectionLost, "연결이 끊어졌습니다", "페이지를 불러오는 중 연결이 끊어졌습니다."),
            (NSURLErrorSecureConnectionFailed, "페이지를 열 수 없습니다", "시스템 설명"),   // 모르는 코드는 시스템 설명 그대로
            (0, "페이지를 열 수 없습니다", "시스템 설명"),
        ]
        for (code, title, detail) in rows {
            let message = BrowserErrorPage.message(code: code, fallback: "시스템 설명")
            XCTAssertEqual(message.title, title, "\(code)")
            XCTAssertEqual(message.detail, detail, "\(code)")
        }
    }

    func testBrowserErrorHTML() {
        let html = BrowserErrorPage.html(title: "연결할 수 없습니다", detail: "이 주소에서 응답하는 서버가 없습니다.", target: "http://localhost:3000/a?x=1&y=<2>")
        // 옮기기 전 BrowserSession.showError 가 만들던 글 그대로 (글자 단위)
        let expected = "<!doctype html><meta charset=\"utf-8\"><title>연결할 수 없습니다</title>\n"
            + "<style>body{font:14px -apple-system,system-ui;color:#333;background:#fafafa;margin:0;display:flex;height:100vh;align-items:center;justify-content:center}\n"
            + "@media(prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}} .box{max-width:560px;padding:24px} h1{font-size:17px;margin:0 0 6px}\n"
            + "p{margin:0 0 14px;opacity:.85} code{font:12px ui-monospace,Menlo;word-break:break-all;opacity:.7}</style>\n"
            + "<div class=\"box\"><h1>연결할 수 없습니다</h1><p>이 주소에서 응답하는 서버가 없습니다.</p><code>http://localhost:3000/a?x=1&amp;y=&lt;2&gt;</code></div>"
        XCTAssertEqual(html, expected)
        // 제목 · 설명도 이스케이프 (시스템 설명에 꺾쇠가 올 수 있다), & 를 먼저 바꿔 두 번 바뀌지 않게
        let odd = BrowserErrorPage.html(title: "<b>", detail: "a & b &lt;", target: "")
        XCTAssertTrue(odd.contains("<title>&lt;b&gt;</title>"))
        XCTAssertTrue(odd.contains("<h1>&lt;b&gt;</h1><p>a &amp; b &amp;lt;</p><code></code>"))
    }

    func testBrowserDownloadDestination() {
        let dir = URL(fileURLWithPath: "/tmp/nexus-test-downloads")
        func name(_ suggested: String, existing: Set<String>) -> String {
            BrowserDownload.destination(in: dir, suggested: suggested) { existing.contains($0.lastPathComponent) }.lastPathComponent
        }
        XCTAssertEqual(name("report.pdf", existing: []), "report.pdf")
        XCTAssertEqual(name("report.pdf", existing: ["report.pdf"]), "report (2).pdf")
        XCTAssertEqual(name("report.pdf", existing: ["report.pdf", "report (2).pdf", "report (3).pdf"]), "report (4).pdf")
        XCTAssertEqual(name("report.pdf", existing: ["report.pdf", "report (3).pdf"]), "report (2).pdf")   // 빈 번호부터
        XCTAssertEqual(name("README", existing: ["README"]), "README (2)")                 // 확장자 없음
        XCTAssertEqual(name("backup.tar.gz", existing: ["backup.tar.gz"]), "backup.tar (2).gz")   // 마지막 확장자 앞에
        XCTAssertEqual(name("report.pdf", existing: ["report (2).pdf"]), "report.pdf")     // 제안된 이름이 비어 있으면 그대로
        XCTAssertEqual(BrowserDownload.destination(in: dir, suggested: "report.pdf") { _ in false }.path, "/tmp/nexus-test-downloads/report.pdf")
    }

    // MARK: 관리자 작업 실패 꼬리 · 로그 창 (AppModel 의 반복 틀에서 옮긴 글)

    func testPrivilegedFailureTail() {
        // 출력 + 오류의 마지막 두 줄 (빈 줄은 뺀다)
        XCTAssertEqual(LanCommands.failureTail(CommandResult(exitCode: 1, stdout: "첫 줄\n둘째 줄\n", stderr: "\n셋째 줄\n\n")), "둘째 줄 · 셋째 줄")
        XCTAssertEqual(LanCommands.failureTail(CommandResult(exitCode: 1, stdout: "", stderr: "ifconfig: ioctl (SIOCAIFADDR): permission denied\n")),
                       "ifconfig: ioctl (SIOCAIFADDR): permission denied")
        XCTAssertEqual(LanCommands.failureTail(CommandResult(exitCode: 1, stdout: "a\r\nb\tc\r\n")), "a · b    c")   // CR 은 떼고 탭은 칸으로
        XCTAssertEqual(LanCommands.failureTail(CommandResult(exitCode: 1)), "")   // 아무 출력 없음
        XCTAssertEqual(LanCommands.failureTail(CommandResult(exitCode: 1, stdout: "\n\n", stderr: "\n")), "")
        // 표준 출력이 줄바꿈 없이 끝나면 오류의 첫 줄과 한 줄이 된다 (옮기기 전과 같다 — 둘을 그대로 이어 붙인다)
        XCTAssertEqual(LanCommands.failureTail(CommandResult(exitCode: 1, stdout: "out", stderr: "err\n")), "outerr")
    }

    func testOutputLinesDropsTrailingEmptyLines() {
        XCTAssertEqual(RemoteCommands.outputLines("a\n\nb\n\n\n", type: .linux), ["a", "", "b"])   // 가운데 빈 줄은 둔다
        XCTAssertEqual(RemoteCommands.outputLines("\na\n", type: .linux), ["", "a"])                  // 앞의 빈 줄도 둔다
        XCTAssertEqual(RemoteCommands.outputLines("", type: .linux), [])
        XCTAssertEqual(RemoteCommands.outputLines("\n\n", type: .linux), [])
        XCTAssertEqual(RemoteCommands.outputLines("#< CLIXML\nok\r\n", type: .windows), ["ok"])       // cleanOutput 의 규칙 그대로
    }

    func testServiceLogDisplayLines() {
        // 성공: 표준 출력만 (끝의 빈 줄은 뗀다)
        XCTAssertEqual(ServiceLog.displayLines(CommandResult(exitCode: 0, stdout: "line 1\nline 2\n\n", stderr: "경고"), stripANSI: false), ["line 1", "line 2"])
        XCTAssertEqual(ServiceLog.displayLines(CommandResult(exitCode: 0, stdout: "\n"), stripANSI: false), ["(로그가 없습니다)"])
        XCTAssertEqual(ServiceLog.displayLines(CommandResult(exitCode: 0), stripANSI: true), ["(로그가 없습니다)"])
        // 실패: 오류 출력까지 보이고, 아무것도 못 받았으면 "로그 없음" 이 아니라 실패로
        XCTAssertEqual(ServiceLog.displayLines(CommandResult(exitCode: 1, stdout: "부분 출력\n", stderr: "Permission denied\n"), stripANSI: false),
                       ["부분 출력", "Permission denied"])
        XCTAssertEqual(ServiceLog.displayLines(CommandResult(exitCode: 255), stripANSI: false), ["로그를 가져오지 못했습니다 (exit 255)"])
        XCTAssertEqual(ServiceLog.displayLines(CommandResult(exitCode: 130, stdout: "\n", stderr: ""), stripANSI: true), ["로그를 가져오지 못했습니다 (exit 130)"])
        // 색 코드: docker 로그만 지운다. 서비스 로그는 ESC(제어 글자)만 빠지고 나머지 글자는 남는다 (옮기기 전과 같다)
        let colored = "\u{1B}[32mINFO\u{1B}[0m started\n"
        XCTAssertEqual(ServiceLog.displayLines(CommandResult(exitCode: 0, stdout: colored), stripANSI: true), ["INFO started"])
        XCTAssertEqual(ServiceLog.displayLines(CommandResult(exitCode: 0, stdout: colored), stripANSI: false), ["[32mINFO[0m started"])
    }
}
