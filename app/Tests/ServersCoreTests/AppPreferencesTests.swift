// AppPreferences: 설정 창 값의 기본값 · 목록 밖 값 처리 · 기존 키와 같은 이름인지.

import XCTest
@testable import ServersCore

final class AppPreferencesTests: XCTestCase {
    func testIntervalsResolveToChoicesOrDefault() {
        XCTAssertEqual(AppPreferences.statusInterval.resolve(nil), 5, "처음엔 기본값 (지금까지의 5초)")
        XCTAssertEqual(AppPreferences.statusInterval.resolve(10), 10)
        XCTAssertEqual(AppPreferences.statusInterval.resolve(0), 5, "목록 밖(0 이면 쉬지 않고 돈다)은 기본값")
        XCTAssertEqual(AppPreferences.systemInterval.resolve(nil), 3)
        XCTAssertEqual(AppPreferences.diskInterval.resolve(nil), 2)
        // 1초는 가벼운 System·Disk 만 (서버 상태 확인·Live 는 ssh, Bluetooth 는 system_profiler)
        XCTAssertEqual(AppPreferences.systemInterval.resolve(1), 1)
        XCTAssertEqual(AppPreferences.diskInterval.resolve(1), 1)
        XCTAssertEqual(AppPreferences.statusInterval.resolve(1), 5)
        XCTAssertEqual(AppPreferences.serverLiveInterval.resolve(1), 5)
        XCTAssertEqual(AppPreferences.bluetoothInterval.resolve(1), 5)
        XCTAssertEqual(AppPreferences.bluetoothInterval.resolve(7), 5)
        XCTAssertEqual(AppPreferences.serverLiveInterval.resolve(nil), 5)
        for preference in [AppPreferences.statusInterval, AppPreferences.systemInterval, AppPreferences.diskInterval, AppPreferences.bluetoothInterval,
                           AppPreferences.serverLiveInterval] {
            XCTAssertTrue(preference.choices.contains(preference.defaultValue), preference.key)
            XCTAssertTrue(preference.choices.allSatisfy { $0 > 0 }, preference.key)
        }
    }

    func testKeysMatchExistingStoredSettings() {
        // 원격 탐색 창의 체크박스가 이미 이 키로 저장해 왔다 — 설정 창도 같은 값을 본다
        XCTAssertEqual(AppPreferences.remoteShowHiddenKey, "remoteBrowserShowHidden")
        let keys = [AppPreferences.statusInterval.key, AppPreferences.systemInterval.key, AppPreferences.diskInterval.key,
                    AppPreferences.bluetoothInterval.key, AppPreferences.serverLiveInterval.key, AppPreferences.coreAnimationKey, AppPreferences.remoteShowHiddenKey]
        XCTAssertEqual(Set(keys).count, keys.count, "키가 겹치지 않는다")
    }

    func testWakeRouteChoiceFallsBackToFirst() {
        let routes = [WakeRoute(via: "brume3", iface: "br-lan"), WakeRoute(via: "nexus")]
        XCTAssertEqual(AppPreferences.wakeRoute(routes, stored: nil), routes[0], "고른 적 없으면 첫 경로")
        XCTAssertEqual(AppPreferences.wakeRoute(routes, stored: "nexus"), routes[1])
        XCTAssertEqual(AppPreferences.wakeRoute(routes, stored: "gone"), routes[0], "servers.conf 에서 빠진 경로면 첫 경로")
        XCTAssertNil(AppPreferences.wakeRoute([], stored: "nexus"))
        XCTAssertEqual(AppPreferences.wakeRouteKey(for: "win"), "wakeRoute.win")
    }
}
