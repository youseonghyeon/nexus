import Foundation
@testable import ServersCore
import XCTest

/// 캡처 필터 도우미: 문맥 제안 · 값 후보 · 프리셋 · 목록·대화에서 거꾸로 만들기 · 적용 전 문법 검사(이 Mac 의 tcpdump, root·패킷 없이)
final class CaptureFilterAssistTests: XCTestCase {
    private let context = FilterContext(
        hosts: [("192.168.8.103", "nexus · servers.conf"), ("192.168.8.1", "게이트웨이"), ("10.1.0.1", "DNS")],
        ports: [(8080, "지금 캡처 · TCP"), (22, "지금 캡처 · SSH")],
        nets: [("192.168.8.0/24", "이 Mac 경로 · en11")],
        servers: [("nexus", "192.168.8.103")])

    private func titles(_ text: String) -> [String] { CaptureFilterAssist.suggestions(for: text, context: context, limit: 40).map(\.title) }

    /// 빈 칸: 낱말 + 서버 프리셋 + 자주 쓰는 것
    func testEmptyShowsKeywordsAndPresets() {
        let all = CaptureFilterAssist.suggestions(for: "", context: context, limit: 40)
        XCTAssertEqual(Array(all.prefix(3).map(\.title)), ["host", "port", "net"])
        XCTAssertTrue(all.contains { $0.kind == .preset && $0.title == "nexus 와의 통신" && $0.insert == "host 192.168.8.103" })
        XCTAssertTrue(all.contains { $0.kind == .preset && $0.insert == "udp port 51820" })
    }

    /// host 뒤 → 주소 후보, port 뒤 → 캡처에서 본 포트 + 자주 쓰는 포트(겹치면 한 번), net 뒤 → 이 Mac 대역
    func testValuesAfterKeyword() {
        XCTAssertEqual(titles("host "), ["192.168.8.103", "192.168.8.1", "10.1.0.1"])
        XCTAssertEqual(Array(titles("port ").prefix(4)), ["8080", "22", "53", "80"])
        XCTAssertEqual(titles("port ").filter { $0 == "22" }.count, 1)
        XCTAssertEqual(titles("dst net "), ["192.168.8.0/24"])
        XCTAssertEqual(titles("src "), ["host", "port", "net"])
    }

    /// 쓰던 낱말로 좁힌다 (앞부분·설명 포함)
    func testPartialNarrows() {
        XCTAssertEqual(titles("ho"), ["host", "nexus 와의 통신"], "host 로 시작하는 프리셋도 (설명에 host 가 든 src·dst 는 아님)")
        XCTAssertEqual(titles("host 192.168.8."), ["192.168.8.103", "192.168.8.1"])
        XCTAssertEqual(titles("host nex"), ["192.168.8.103"], "설명(nexus)으로도 찾는다")
    }

    /// 값·프로토콜 뒤 → and / or / and not, tcp 뒤엔 port 도
    func testCombinatorsAfterValue() {
        XCTAssertEqual(titles("host 192.168.8.103 "), ["and", "or", "and not"])
        XCTAssertEqual(titles("tcp "), ["port", "and", "or", "and not"])
        XCTAssertEqual(titles("host 192.168.8.103 and "), ["host", "port", "net", "tcp", "udp", "icmp", "arp", "src", "dst", "not"])
        XCTAssertFalse(titles("not ").contains("not"), "not not 은 권하지 않는다")
    }

    /// 넣기: 쓰던 낱말을 바꿔 끼우고 끝에 빈칸, 프리셋은 통째로
    func testApply() {
        let host = FilterSuggestion("host", "", insert: "host", kind: .keyword)
        XCTAssertEqual(CaptureFilterAssist.apply(host, to: ""), "host ")
        XCTAssertEqual(CaptureFilterAssist.apply(host, to: "port 22 and ho"), "port 22 and host ")
        let value = FilterSuggestion("192.168.8.103", "", insert: "192.168.8.103", kind: .value)
        XCTAssertEqual(CaptureFilterAssist.apply(value, to: "host 192.1"), "host 192.168.8.103 ")
        let preset = FilterSuggestion("DNS 만", "", insert: "port 53", kind: .preset)
        XCTAssertEqual(CaptureFilterAssist.apply(preset, to: "host 1.2.3.4 and "), "port 53")
        let hint = FilterSuggestion("192.168.8.103", "주소를 직접 쓰세요", insert: "", kind: .value)
        XCTAssertEqual(CaptureFilterAssist.apply(hint, to: "host "), "host ", "안내 줄은 아무것도 넣지 않는다")
    }

    /// 목록 행에서: 이 대화만 · 주소 · 포트 · 빼기. IP 가 아닌 프레임은 MAC
    func testFromPacket() {
        var p = DecodedPacket()
        p.source = "192.168.8.101"; p.destination = "199.232.193.91"; p.sourcePort = 57241; p.destinationPort = 443
        p.transport = "TCP"; p.proto = "TLS"; p.sourceMAC = "60:15:6f:a4:b1:d9"; p.destinationMAC = "94:83:c4:a9:b1:64"
        let items = CaptureFilterAssist.fromPacket(p)
        XCTAssertEqual(items.first?.filter, "host 192.168.8.101 and host 199.232.193.91 and tcp port 57241 and tcp port 443")
        XCTAssertTrue(items.contains { $0.filter == "host 199.232.193.91" })
        XCTAssertTrue(items.contains { $0.filter == "port 443" })
        XCTAssertTrue(items.contains { $0.filter == "not port 443" })

        var l2 = DecodedPacket()
        l2.source = "60:15:6f:a4:b1:d9"; l2.destination = "ff:ff:ff:ff:ff:ff"; l2.sourceMAC = l2.source; l2.destinationMAC = l2.destination
        l2.transport = "Ethernet"; l2.proto = "Realtek"
        XCTAssertEqual(CaptureFilterAssist.fromPacket(l2).map(\.filter), ["ether host 60:15:6f:a4:b1:d9"], "MAC 을 host 로 쓰지 않는다")
    }

    func testFromConversation() {
        let tcp = Conversation(id: "", transport: "TCP", a: "172.217.209.94:443", b: "192.168.8.101:60042", first: 0, last: 0)
        XCTAssertEqual(CaptureFilterAssist.fromConversation(tcp), "host 172.217.209.94 and host 192.168.8.101 and tcp port 443 and tcp port 60042")
        let v6 = Conversation(id: "", transport: "UDP", a: "[fd00::1]:53", b: "[fd00::2]:5000", first: 0, last: 0)
        XCTAssertEqual(CaptureFilterAssist.fromConversation(v6), "host fd00::1 and host fd00::2 and udp port 53 and udp port 5000")
        let icmp = Conversation(id: "", transport: "ICMP", a: "1.1.1.1", b: "192.168.8.101", first: 0, last: 0)
        XCTAssertEqual(CaptureFilterAssist.fromConversation(icmp), "host 1.1.1.1 and host 192.168.8.101")
        let eth = Conversation(id: "", transport: "Ethernet", a: "60:15:6f:a4:b1:d9", b: "ff:ff:ff:ff:ff:ff", first: 0, last: 0)
        XCTAssertEqual(CaptureFilterAssist.fromConversation(eth), "ether host 60:15:6f:a4:b1:d9 and ether host ff:ff:ff:ff:ff:ff")
        // ICMPv6 는 포트가 없어 주소에 대괄호가 없다 — "fe80::1" 을 fe80 의 1번 포트로 읽어 "host fe80 and host ff02" 가 나왔다
        let icmp6 = Conversation(id: "", transport: "ICMP", a: "fe80::1", b: "ff02::1", first: 0, last: 0)
        XCTAssertEqual(CaptureFilterAssist.fromConversation(icmp6), "host fe80::1 and host ff02::1")
    }

    /// 끝점 글자 가르기 — DecodedPacket.endpoint 가 내는 꼴 전부 (IPv6 는 포트가 있을 때만 대괄호)
    func testEndpointParts() {
        func parts(_ text: String) -> [String] { let p = CaptureEndpoint.parts(text); return [p.host, p.port.map(String.init) ?? "-"] }
        XCTAssertEqual(parts("1.2.3.4:443"), ["1.2.3.4", "443"])
        XCTAssertEqual(parts("1.2.3.4"), ["1.2.3.4", "-"])
        XCTAssertEqual(parts("[fe80::1]:443"), ["fe80::1", "443"])
        XCTAssertEqual(parts("fe80::1"), ["fe80::1", "-"], "':' 가 여럿이면 포트가 아니다")
        XCTAssertEqual(parts("ff02::1"), ["ff02::1", "-"])
        XCTAssertEqual(parts("::1"), ["::1", "-"])
        XCTAssertEqual(parts("60:15:6f:a4:b1:d9"), ["60:15:6f:a4:b1:d9", "-"], "MAC")
        XCTAssertEqual(parts(""), ["", "-"])
        // 실제로 만들어진 끝점을 다시 가르면 원래 값
        for (host, port) in [("192.168.8.101", UInt16(58108)), ("fd00::2", 443), ("::1", 53)] {
            let back = CaptureEndpoint.parts(DecodedPacket.endpoint(host, port))
            XCTAssertEqual(back.host, host)
            XCTAssertEqual(back.port, Int(port))
            XCTAssertEqual(CaptureEndpoint.parts(DecodedPacket.endpoint(host, nil)).host, host)
            XCTAssertNil(CaptureEndpoint.parts(DecodedPacket.endpoint(host, nil)).port)
        }
    }

    func testLinkTypeGuessAndMessages() {
        XCTAssertEqual(CaptureFilterAssist.linkType(forDevice: "utun6"), LinkType.null)
        XCTAssertEqual(CaptureFilterAssist.linkType(forDevice: "lo0"), LinkType.null)
        XCTAssertEqual(CaptureFilterAssist.linkType(forDevice: "en11"), LinkType.ethernet)
        XCTAssertNil(CaptureFilterAssist.validationMessage(exitCode: 0, stderr: "reading from file x, link-type EN10MB (Ethernet)\n"))
        XCTAssertEqual(CaptureFilterAssist.validationMessage(exitCode: 1, stderr: "reading from file x, link-type EN10MB (Ethernet)\ntcpdump: unknown host 'prot'\n"),
                       "필터 문법 오류: unknown host 'prot'")
    }

    /// 실제 tcpdump 로 (root·패킷 없이 식만 해석): 맞는 식은 통과, 틀린 식은 이유, "-" 낱말은 막는다
    func testValidateWithRealTcpdump() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/sbin/tcpdump"))
        let runner = ProcessRunner()
        let ok = await CaptureFilterAssist.validate("host 192.168.8.103 and tcp port 22", linkType: LinkType.ethernet, runner: runner)
        XCTAssertNil(ok)
        let okNull = await CaptureFilterAssist.validate("udp port 51820 or icmp", linkType: LinkType.null, runner: runner)
        XCTAssertNil(okNull)
        let preset = await CaptureFilterAssist.validate("tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0", linkType: LinkType.ethernet, runner: runner)
        XCTAssertNil(preset, "프리셋 식은 모두 통과해야 한다")
        let bad = await CaptureFilterAssist.validate("host 192.168.8.103 and prot 22", linkType: LinkType.ethernet, runner: runner)
        XCTAssertEqual(bad, "필터 문법 오류: unknown host 'prot'")
        let option = await CaptureFilterAssist.validate("port 22 -w /tmp/x", linkType: LinkType.ethernet, runner: runner)
        XCTAssertNotNil(option)
        let empty = await CaptureFilterAssist.validate("  ", linkType: LinkType.ethernet, runner: runner)
        XCTAssertNil(empty)
        for p in CaptureFilterAssist.fixedPresets {
            let problem = await CaptureFilterAssist.validate(p.insert, linkType: LinkType.ethernet, runner: runner)
            XCTAssertNil(problem, p.insert)
        }
    }

    /// 이 Mac 의 networksetup -listallhardwareports 꼴
    func testParseHardwarePorts() {
        let text = """

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: ac:07:75:a5:b1:86

        Hardware Port: TPlink 2.5G Ethernet
        Device: en11
        Ethernet Address: 60:15:6f:a4:b1:d9

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: N/A

        VLAN Configurations
        ===================
        """
        XCTAssertEqual(CaptureCommand.parseHardwarePorts(text), ["en0": "Wi-Fi", "en11": "TPlink 2.5G Ethernet", "bridge0": "Thunderbolt Bridge"])
        XCTAssertEqual(CaptureCommand.parseHardwarePorts(""), [:])
    }
}
