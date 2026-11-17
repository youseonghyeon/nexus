// ParsedRemoteInfo: 조회(query) × 서버 종류 → 어느 갈래(파서)로 가는가. 각 파서의 내용은 그 파서의 테스트가 본다.

import Foundation
import XCTest
@testable import ServersCore

final class ParsedRemoteInfoTests: XCTestCase {
    private func kind(_ parsed: ParsedRemoteInfo) -> String {
        switch parsed {
        case .spec: return "spec"
        case .ports: return "ports"
        case .services: return "services"
        case .openwrtServices: return "openwrtServices"
        case .network: return "network"
        case .linuxNetwork: return "linuxNetwork"
        case .schedule: return "schedule"
        case .firewall: return "firewall"
        case .clients: return "clients"
        case .wireguard: return "wireguard"
        case .none: return "none"
        }
    }

    /// 조회마다 (linux, windows, openwrt) 의 갈래. services·network 만 서버 종류로 갈린다.
    func testQueryAndTypeSelectTheCase() {
        let table: [(RemoteCommands.Query, linux: String, windows: String, openwrt: String)] = [
            (.spec, "spec", "spec", "spec"),
            (.ports, "ports", "ports", "ports"),
            (.services, "services", "services", "openwrtServices"),
            (.network, "linuxNetwork", "linuxNetwork", "network"),
            (.schedule, "schedule", "schedule", "schedule"),
            (.firewall, "firewall", "firewall", "firewall"),
            (.clients, "clients", "clients", "clients"),
            (.wireguard, "wireguard", "wireguard", "wireguard"),
            (.live, "none", "none", "none"),
        ]
        XCTAssertEqual(Set(table.map(\.0)), Set(RemoteCommands.Query.allCases), "새 조회를 더하면 이 표에도 줄을 더한다")
        for (query, linux, windows, openwrt) in table {
            XCTAssertEqual(kind(ParsedRemoteInfo.parse(query, lines: [], type: .linux)), linux, "\(query) · linux")
            XCTAssertEqual(kind(ParsedRemoteInfo.parse(query, lines: [], type: .windows)), windows, "\(query) · windows")
            XCTAssertEqual(kind(ParsedRemoteInfo.parse(query, lines: [], type: .openwrt)), openwrt, "\(query) · openwrt")
        }
    }

    /// Spec 의 업데이트 목록(UPDATE 줄)은 linux 만 읽는다
    func testSpecUpdatesOnlyForLinux() {
        let lines = ["HOSTNAME     nexus", "UPDATE       apt/noble-updates,noble-security 2.8.4ubuntu0.1 arm64 [upgradable from: 2.8.3]"]
        for type in [ServerType.linux, .windows, .openwrt] {
            guard case let .spec(items, updates) = ParsedRemoteInfo.parse(.spec, lines: lines, type: type) else { XCTFail("\(type)"); continue }
            XCTAssertEqual(items.map(\.key), ["HOSTNAME"], "UPDATE 줄은 항목이 아니다 · \(type)")
            XCTAssertEqual(updates.map(\.name), type == .linux ? ["apt"] : [], "\(type)")
        }
    }

    /// 실제 출력이 형식을 못 알아본 것(nil)으로 떨어지지 않는다
    func testLinuxServicesFixtureParses() throws {
        let linux = RemoteCommands.cleanOutput(try fixtureText("services-linux-1"), type: .linux)
        if case .services(let report) = ParsedRemoteInfo.parse(.services, lines: linux, type: .linux) { XCTAssertNotNil(report) }
        else { XCTFail("linux services 는 .services 여야 합니다") }
    }
}
