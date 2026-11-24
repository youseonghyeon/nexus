// ScreenMode: 화면 모드 목록 · 저장 값 · 면 색의 기운.

import XCTest
@testable import ServersCore

final class ScreenModeTests: XCTestCase {
    func testStoredValuesStayCompatible() {
        XCTAssertEqual(ScreenMode.defaultsKey, "appearance", "원래 쓰던 키")
        XCTAssertEqual(ScreenMode.resolve("system"), .system)
        XCTAssertEqual(ScreenMode.resolve("light"), .light)
        XCTAssertEqual(ScreenMode.resolve("dark"), .dark, "원래 값 셋은 그대로 읽힌다")
        XCTAssertEqual(ScreenMode.resolve("dusk"), .dusk)
        XCTAssertEqual(ScreenMode.resolve(nil), .system)
        XCTAssertEqual(ScreenMode.resolve("sepia"), .system, "목록 밖은 System")
        XCTAssertEqual(ScreenMode.allCases.map(\.title), ["System", "Light", "Dark", "Dusk", "Midnight", "Paper", "Mist"])
    }

    func testFamiliesAndShifts() {
        XCTAssertEqual(ScreenMode.allCases.map(\.family), [.system, .light, .dark, .dark, .dark, .light, .light])
        for plain in [ScreenMode.system, .light, .dark] { XCTAssertEqual(plain.shift, .none, "원래 있던 셋은 색이 한 톨도 달라지지 않는다") }
        // 변형은 서로 다르고, 기운의 방향이 이름과 맞는다
        let shifts = [ScreenMode.dusk, .midnight, .paper, .mist].map(\.shift)
        XCTAssertEqual(Set(shifts.map { "\($0.r),\($0.g),\($0.b)" }).count, 4)
        XCTAssertGreaterThan(ScreenMode.dusk.shift.r, ScreenMode.dusk.shift.b, "Dusk 는 따뜻하게")
        XCTAssertGreaterThan(ScreenMode.midnight.shift.b, ScreenMode.midnight.shift.r, "Midnight 는 푸르게")
        XCTAssertGreaterThan(ScreenMode.paper.shift.r, ScreenMode.paper.shift.b, "Paper 는 따뜻하게")
        XCTAssertGreaterThan(ScreenMode.mist.shift.b, ScreenMode.mist.shift.r, "Mist 는 푸르게")
    }

    func testShiftedKeepsSurfaceLadderAndClamps() {
        XCTAssertEqual(ScreenMode.shifted(0x141517, by: .none), 0x141517)
        XCTAssertEqual(ScreenMode.shifted(0x141517, by: ScreenMode.dusk.shift), 0x1D1A15)
        XCTAssertEqual(ScreenMode.shifted(0xFFFFFF, by: ScreenMode.paper.shift), 0xFFFCF1, "넘치는 성분은 255 에 머문다")
        XCTAssertEqual(ScreenMode.shifted(0x000000, by: ScreenMode.Shift(-5, -5, -5)), 0x000000, "0 아래로 내려가지 않는다")
        // 면 단계(사이드바 < 본문 < 카드 < 조작부)의 밝기 순서는 어느 모드에서도 그대로 — 어두운 계열의 기준 색으로
        func brightness(_ hex: UInt32) -> Int { Int((hex >> 16) & 0xFF) + Int((hex >> 8) & 0xFF) + Int(hex & 0xFF) }
        let dark: [UInt32] = [0x0F1012, 0x141517, 0x1B1C1F, 0x27282C], light: [UInt32] = [0xEAEAE8, 0xF4F4F2, 0xFFFFFF]
        for mode in ScreenMode.allCases {
            let surfaces = (mode.family == .light ? light : dark).map { brightness(ScreenMode.shifted($0, by: mode.shift)) }
            XCTAssertEqual(surfaces, surfaces.sorted(), "\(mode.rawValue)")
            XCTAssertEqual(Set(surfaces).count, surfaces.count, "\(mode.rawValue) — 두 면이 같은 색이 되지 않는다")
        }
    }
}
