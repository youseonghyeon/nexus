// 어떤 장비인지: IEEE 목록 대조(가장 긴 접두 먼저) · 임의 MAC · NetBIOS 이름 읽기. 실제 목록 파일도 한 번 읽어 본다.

import Foundation
@testable import ServersCore
import XCTest

final class DeviceIdentityTests: XCTestCase {
    private let table = OUITable.parse("# 주석\n588694\tEFM Networks\n5444A3\tSamsung Electronics Co.,Ltd\n8C1F64\tIEEE Registration Authority\n8C1F64AFA\tDATA ELECTRONIC DEVICES, INC\n")

    func testVendorLongestPrefix() {
        XCTAssertEqual(table.vendor(mac: "58:86:94:aa:b1:17"), "EFM Networks")
        XCTAssertEqual(table.vendor(mac: "54:44:a3:ac:b1:6a"), "Samsung Electronics Co.,Ltd")
        XCTAssertEqual(table.vendor(mac: "8c:1f:64:af:a1:23"), "DATA ELECTRONIC DEVICES, INC", "MA-S 9자리가 MA-L 6자리보다 먼저")
        XCTAssertNil(table.vendor(mac: "20:25:07:af:b1:39"))
        XCTAssertNil(table.vendor(mac: "bad"))
    }

    func testRandomMACAndText() {
        XCTAssertTrue(DeviceIdentity.isRandomMAC("16:12:17:ad:b1:7e"), "0x16 의 로컬 관리 비트")
        XCTAssertFalse(DeviceIdentity.isRandomMAC("58:86:94:aa:b1:17"))
        XCTAssertTrue(DeviceIdentity.isRandomMAC("ae:07:75:a4:b2:64"))
        XCTAssertEqual(DeviceIdentity(randomMAC: true, netbios: nil).text, "임의 MAC")
        XCTAssertEqual(DeviceIdentity(vendor: "Samsung", netbios: "DESKTOP-ABC").text, "Samsung · DESKTOP-ABC")
        XCTAssertNil(DeviceIdentity().text)
    }

    func testNetBIOSParse() {
        XCTAssertEqual(DeviceIdentity.parseNetBIOS("Using IP address of 192.168.0.5: 192.168.0.5\nWorkgroup: WORKGROUP\nServer: DESKTOP-ABC\n"), "DESKTOP-ABC")
        XCTAssertNil(DeviceIdentity.parseNetBIOS("Operation timed out: unable to get status from 192.168.0.24 using address 192.168.0.24\n"))
    }

    func testPTRParse() {
        XCTAssertEqual(DeviceIdentity.parsePTR("brume3.lan.\n"), "brume3.lan")
        XCTAssertNil(DeviceIdentity.parsePTR(""), "이름 없음(NXDOMAIN)은 빈 출력")
        XCTAssertNil(DeviceIdentity.parsePTR(";; communications error to 192.168.8.1#53: timed out\n;; no servers could be reached\n"))
    }

    func testTextDropsSameName() {
        XCTAssertEqual(DeviceIdentity(vendor: "Micro-Star", hostname: "window-pc.lan", netbios: "WINDOW-PC").text, "Micro-Star · window-pc.lan")
        XCTAssertEqual(DeviceIdentity(vendor: "GL", hostname: "console.gl-inet.com", upnp: "GL-MT3000").text, "GL · console.gl-inet.com · GL-MT3000")
        XCTAssertEqual(DeviceIdentity(randomMAC: true, hostname: "iPhone.lan").text, "임의 MAC · iPhone.lan")
    }

    func testSSDPParse() {
        let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLocation: http://192.168.8.1:5000/rootDesc.xml\r\nST: upnp:rootdevice\r\n\r\n"
        XCTAssertEqual(SSDP.location(response), "http://192.168.8.1:5000/rootDesc.xml")
        XCTAssertNil(SSDP.location("HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\n"))
        XCTAssertTrue(SSDP.acceptable("http://192.168.8.1:5000/rootDesc.xml", from: "192.168.8.1"))
        XCTAssertFalse(SSDP.acceptable("http://203.0.113.9/desc.xml", from: "192.168.8.1"), "다른 곳을 가리키면 따라가지 않는다")
        XCTAssertFalse(SSDP.acceptable("https://192.168.8.1/desc.xml", from: "192.168.8.1"))
        XCTAssertFalse(SSDP.acceptable("file:///etc/passwd", from: "192.168.8.1"))
        let xml = "<root><device><deviceType>urn:x</deviceType><friendlyName>Living Room TV &amp; Audio</friendlyName><modelName>UN55</modelName></device></root>"
        XCTAssertEqual(SSDP.name(fromDescription: xml), "Living Room TV & Audio")
        XCTAssertEqual(SSDP.name(fromDescription: "<root><modelName>GL-MT3000</modelName><friendlyName> </friendlyName></root>"), "GL-MT3000")
        // 숫자 참조 (Windows 의 AirScreen 이 보낸 이름 — 풀지 않아 "window-pc&#39;s AirScreen" 으로 보였다)
        XCTAssertEqual(SSDP.name(fromDescription: "<friendlyName>window-pc&#39;s AirScreen</friendlyName>"), "window-pc's AirScreen")
        XCTAssertEqual(SSDP.name(fromDescription: "<friendlyName>A&#x27;s &#xAC70;&#49892; TV</friendlyName>"), "A's 거실 TV")
        // &amp; 로 감싼 참조는 글자 그대로, 잘못된 숫자는 지운다
        XCTAssertEqual(SSDP.decodeEntities("&amp;#39; &#99999999; ok"), "&#39; &#99999999; ok")
        XCTAssertEqual(SSDP.decodeEntities("x&#1114112;y"), "xy")
        XCTAssertNil(SSDP.name(fromDescription: "not xml"))
    }

    func testIdentifyAll() async {
        let runner = FakeRunner()
        runner.scripted["smbutil status 192.168.0.5"] = CommandResult(exitCode: 0, stdout: "Workgroup: WORKGROUP\nServer: DESKTOP-ABC\n")
        let entries = [ArpEntry(ip: "192.168.0.1", mac: "58:86:94:aa:b1:17", device: "en0"),
                       ArpEntry(ip: "192.168.0.5", mac: "54:44:a3:ac:b1:6a", device: "en0"),
                       ArpEntry(ip: "192.168.0.222", mac: "16:12:17:ad:b1:7e", device: "en0"),
                       ArpEntry(ip: "192.168.0.9", mac: nil, device: "en0")]
        let result = await DeviceIdentity.identifyAll(entries, table: table, runner: runner)
        XCTAssertEqual(result["192.168.0.1"]?.text, "EFM Networks")
        XCTAssertEqual(result["192.168.0.5"]?.text, "Samsung Electronics Co.,Ltd · DESKTOP-ABC")
        XCTAssertEqual(result["192.168.0.222"]?.text, "임의 MAC")
        XCTAssertNil(result["192.168.0.9"], "응답 없는 주소는 묻지 않는다")
        XCTAssertFalse(runner.calls.contains { $0.executable == "dig" }, "DNS 서버를 모르면 PTR 을 묻지 않는다")
    }

    func testIdentifyAllWithPTR() async {
        let runner = FakeRunner()
        runner.scripted["dig +short +time=1 +tries=1 -b 192.168.0.10 @192.168.0.1 -x 192.168.0.5"] = CommandResult(exitCode: 0, stdout: "desktop-abc.lan.\n")
        runner.scripted["smbutil status 192.168.0.5"] = CommandResult(exitCode: 0, stdout: "Server: DESKTOP-ABC\n")
        let entries = [ArpEntry(ip: "192.168.0.5", mac: "54:44:a3:ac:b1:6a", device: "en0"),
                       ArpEntry(ip: "192.168.0.6", mac: "58:86:94:ab:b1:18", device: "en0")]
        let result = await DeviceIdentity.identifyAll(entries, table: table, dns: .init(server: "192.168.0.1", source: "192.168.0.10"), runner: runner)
        XCTAssertEqual(result["192.168.0.5"]?.text, "Samsung Electronics Co.,Ltd · desktop-abc.lan")
        XCTAssertEqual(result["192.168.0.6"]?.text, "EFM Networks", "PTR·NetBIOS 답이 없으면 제조사만")
    }

    /// 번들에 넣는 실제 목록 (Resources/oui/oui.tsv)
    func testBundledTable() throws {
        let path = TestPaths.appDir.appendingPathComponent("Resources/oui/oui.tsv").path
        let real = try XCTUnwrap(OUITable.load(path: path))
        XCTAssertEqual(real.vendor(mac: "58:86:94:aa:b1:17"), "EFM Networks")
        XCTAssertEqual(real.vendor(mac: "54:44:a3:ac:b1:6a"), "Samsung Electronics Co.,Ltd")
        XCTAssertGreaterThan(real.names.count, 50_000)
    }
}
