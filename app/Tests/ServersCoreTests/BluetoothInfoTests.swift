// BluetoothInfo: system_profiler -json 파싱 · 배터리 보충 병합 · 판정 (bt.zsh 와 같은 기준).
// 픽스처는 이 Mac 의 출력 모양 그대로 (기기 이름·주소·일련번호는 가짜 값).

import Foundation
import XCTest
@testable import ServersCore

final class BluetoothInfoTests: XCTestCase {
    private let json = """
    {"SPBluetoothDataType":[{
      "controller_properties":{"controller_address":"AA:BB:CC:00:00:01","controller_chipset":"BCM_4388C2","controller_discoverable":"attrib_off",
        "controller_firmwareVersion":"24.1.240.1873","controller_productID":"0x4A35","controller_state":"attrib_on",
        "controller_supportedServices":"0x1390039 < HFP AVRCP A2DP HID LEA AACP GATT SerialPort SCO >","controller_transport":"PCIe",
        "controller_vendorID":"0x004C (Apple)"},
      "device_connected":[
        {"Test Pods":{"device_address":"AA:BB:CC:00:00:02","device_batteryLevelCase":"93%","device_batteryLevelLeft":"76%","device_batteryLevelRight":"70%",
          "device_caseVersion":"1.0","device_firmwareVersion":"8A356","device_minorType":"Headphones","device_productID":"0x2014","device_rssi":"-66",
          "device_serialNumber":"SN0","device_serialNumberLeft":"SNL","device_serialNumberRight":"SNR",
          "device_services":"0x980019 < HFP AVRCP A2DP AACP GATT ACL >","device_vendorID":"0x004C"}},
        {"Test Mouse":{"device_address":"aa-bb-cc-00-00-03","device_minorType":"Mouse","device_services":"0x400000 < BLE >","device_vendorID":"0x046D"}},
        {"Test Keyboard":{"device_address":"AA:BB:CC:00:00:04","device_minorType":"Keyboard","device_batteryLevelMain":"12%"}}
      ],
      "device_not_connected":[
        {"Test Phone":{"device_address":"AA:BB:CC:00:00:05","device_rssi":"-40"}},
        {"Old Speaker":{"device_address":"AA:BB:CC:00:00:06","device_minorType":"Speaker"}}
      ]}]}
    """

    private func snapshot() throws -> BluetoothSnapshot {
        try XCTUnwrap(BluetoothParser.parse(Data(json.utf8)))
    }

    func testParsesControllerAndDevices() throws {
        let snap = try snapshot()
        let controller = try XCTUnwrap(snap.controller)
        XCTAssertTrue(controller.on)
        XCTAssertEqual(controller.discoverable, false)
        XCTAssertEqual(controller.services.first, "HFP")
        XCTAssertEqual(controller.transport, "PCIe")
        XCTAssertEqual(snap.connected.map(\.name), ["Test Pods", "Test Mouse", "Test Keyboard"])
        XCTAssertEqual(snap.paired.map(\.name), ["Test Phone", "Old Speaker"])

        let pods = snap.connected[0]
        XCTAssertEqual(pods.batteries, [BluetoothBattery(part: .left, percent: 76), BluetoothBattery(part: .right, percent: 70),
                                        BluetoothBattery(part: .case_, percent: 93)], "왼쪽 · 오른쪽 · 케이스 순")
        XCTAssertEqual(pods.rssi, -66)
        XCTAssertEqual(pods.services, ["HFP", "AVRCP", "A2DP", "AACP", "GATT", "ACL"])
        XCTAssertEqual(pods.serials["왼쪽"], "SNL")
        XCTAssertEqual(snap.connected[1].address, "AA:BB:CC:00:00:03", "주소는 대문자·콜론으로")
        XCTAssertEqual(snap.connected[2].batteries, [BluetoothBattery(part: .main, percent: 12)], "하나짜리 배터리 키도 읽는다")
        XCTAssertNil(snap.paired[0].minorType)
        XCTAssertNil(BluetoothParser.parse(Data("{}".utf8)))
        XCTAssertNil(BluetoothParser.parse(Data("not json".utf8)))
    }

    func testOffControllerAndEmptyLists() throws {
        let off = try XCTUnwrap(BluetoothParser.parse(Data(#"{"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_off"}}]}"#.utf8)))
        XCTAssertEqual(off.controller?.on, false)
        XCTAssertTrue(off.devices.isEmpty)
        XCTAssertEqual(BluetoothHealth.judge(off).text, "꺼짐")
        XCTAssertNil(BluetoothHealth.judge(off).level)
        XCTAssertEqual(BluetoothHealth.judge(nil).text, "정보를 읽지 못했습니다")
    }

    func testMergeFillsOnlyMissingBatteries() throws {
        let merged = BluetoothParser.merge(try snapshot(), byAddress: ["AA:BB:CC:00:00:03": 65, "AA:BB:CC:00:00:04": 99, "AA:BB:CC:00:00:05": 50])
        XCTAssertEqual(merged.connected[1].batteries, [BluetoothBattery(part: .main, percent: 65)], "배터리 없던 마우스에 채운다")
        XCTAssertEqual(merged.connected[2].batteries.first?.percent, 12, "system_profiler 값이 있으면 덮지 않는다")
        XCTAssertTrue(merged.paired[0].batteries.isEmpty, "연결 안 된 기기에는 붙이지 않는다")
        let byName = BluetoothParser.merge(try snapshot(), byAddress: [:], byName: ["Test Mouse": 40])
        XCTAssertEqual(byName.connected[1].lowestBattery, 40, "주소가 안 맞으면 같은 이름이 하나뿐일 때 이름으로")
    }

    /// 2026-10-05 이 Mac 의 실제 출력 (소니 헤드셋은 system_profiler 에 배터리가 없고 여기에만 있다)
    static let accps = """
    Now drawing from 'Battery Power'
     -InternalBattery-0 (id=22544483)\t71%; discharging; 9:25 remaining present: true
     - (id=40244547)\t55%; discharging present: true
     - (id=57344000)\t84%; discharging present: true
     -AirPods Pro (id=40244548)\t100%; charging; 0:00 remaining present: true
     - (id=40244551)\t31%; discharging present: true
     -WH-1000XM5 (id=25826630)\t60%; discharging present: true
    """

    func testParsesAccessoryPower() async throws {
        XCTAssertEqual(BluetoothParser.parseAccessoryPower(Self.accps), ["AirPods Pro": 100, "WH-1000XM5": 60],
                       "이름 없는 줄·내장 배터리는 뺀다")
        XCTAssertEqual(BluetoothParser.parseAccessoryPower(" -Test Mouse (id=1)\t40%; x\n -Test Mouse (id=2)\t90%; x\n -Pad (id=3)\t7%; x"), ["Pad": 7],
                       "같은 이름이 둘이면 어느 기기 것인지 몰라 뺀다")
        XCTAssertEqual(BluetoothParser.parseAccessoryPower(""), [:])
        // 이름으로 붙이고, system_profiler 값이 있는 기기는 덮지 않는다
        let merged = BluetoothParser.merge(try snapshot(), byAddress: [:], byName: BluetoothParser.parseAccessoryPower(" -Test Mouse (id=1)\t40%; discharging"))
        XCTAssertEqual(merged.connected[1].lowestBattery, 40)
        let runner = FakeRunner()
        runner.scripted["pmset -g accps"] = CommandResult(exitCode: 0, stdout: Self.accps)
        let read = await BluetoothProbe.accessoryBatteries(runner: runner)
        XCTAssertEqual(read["WH-1000XM5"], 60)
        let failing = FakeRunner()
        failing.scripted["pmset -g accps"] = CommandResult(exitCode: 1)
        let none = await BluetoothProbe.accessoryBatteries(runner: failing)
        XCTAssertEqual(none, [:], "못 읽으면 빈 값")
    }

    func testHealthAndText() throws {
        let snap = try snapshot()
        XCTAssertEqual(BluetoothHealth.judge(snap).text, "배터리 부족 · Test Keyboard 12%")
        XCTAssertEqual(BluetoothHealth.judge(snap).level, .bad)
        var fine = snap
        fine.devices.removeAll { $0.name == "Test Keyboard" }
        XCTAssertEqual(BluetoothHealth.judge(fine).text, "켜짐 · 2개 연결")
        XCTAssertEqual(BluetoothHealth.batteryLevel(30), .warn)
        XCTAssertEqual(BluetoothHealth.batteryLevel(31), .good)
        XCTAssertEqual(BluetoothHealth.batteryLevel(15), .bad)
        XCTAssertEqual(BluetoothHealth.signalText(-60), "좋음")
        XCTAssertEqual(BluetoothHealth.signalText(-75), "보통")
        XCTAssertEqual(BluetoothHealth.signalText(-76), "약함")
        XCTAssertEqual(BluetoothHealth.batteryText(snap.connected[0].batteries), "왼쪽 76% · 오른쪽 70% · 케이스 93%")
        XCTAssertEqual(BluetoothHealth.batteryText([BluetoothBattery(part: .main, percent: 65)]), "65%")
        XCTAssertNil(BluetoothHealth.batteryText([]))
    }

    func testHelpers() {
        XCTAssertEqual(BluetoothParser.normalizeAddress("d4-85-59-a0-b2-cb"), "D4:85:59:A0:B2:CB")
        XCTAssertEqual(BluetoothParser.normalizeAddress("d48559 a0b2cb"), "D4:85:59:A0:B2:CB")
        XCTAssertEqual(BluetoothParser.percent("76%"), 76)
        XCTAssertEqual(BluetoothParser.percent(NSNumber(value: 40)), 40)
        XCTAssertNil(BluetoothParser.percent("120%"), "100 을 넘으면 버린다")
        XCTAssertEqual(BluetoothParser.typeName("Magic Trackpad"), "트랙패드")
        XCTAssertEqual(BluetoothParser.typeName("Toaster"), "Toaster", "모르는 종류는 그대로")
        XCTAssertNil(BluetoothParser.typeName(nil))
        XCTAssertEqual(BluetoothParser.services(nil), [])
        XCTAssertEqual(BluetoothParser.services("0x0 <>"), [])
    }

    func testProbeThroughRunnerAndThisMac() async throws {
        let runner = FakeRunner()
        runner.scripted["system_profiler -json SPBluetoothDataType"] = CommandResult(exitCode: 0, stdout: json)
        let snap = await BluetoothProbe.snapshot(runner: runner)
        XCTAssertEqual(snap?.connected.count, 3)
        let failing = FakeRunner()
        failing.scripted["system_profiler -json SPBluetoothDataType"] = CommandResult(exitCode: 1)
        let none = await BluetoothProbe.snapshot(runner: failing)
        XCTAssertNil(none)
        // 레지스트리 읽기는 권한 없이 돈다 (값이 있으면 모양만 본다)
        for (address, percent) in BluetoothProbe.hidBatteries() {
            XCTAssertEqual(address.count, 17)
            XCTAssertTrue((0...100).contains(percent))
        }
        XCTAssertTrue(BluetoothProbe.addressesByIdentifier().values.allSatisfy { $0.count == 17 })
    }
}
