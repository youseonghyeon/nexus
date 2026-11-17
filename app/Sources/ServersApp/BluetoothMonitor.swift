// 블루투스 화면(컨트롤러·기기·배터리) 수집기. 파싱·병합은 ServersCore BluetoothInfo, 동작은 BluetoothActions.
// 화면이 떠 있고 창이 보일 때만 5초마다 system_profiler + HID·전원 소스(pmset) 배터리, 60초마다 GATT 배터리를 읽는다 (BluetoothDashboardView 의 .task).
// 사이드바 요약은 창이 보일 때 30초에 한 번만 (system_profiler 가 다른 수집보다 무겁다 — 0.06초).

import Foundation
import ServersCore

@MainActor
final class BluetoothMonitor: ObservableObject {
    static let gattInterval: TimeInterval = 60
    static let summaryInterval: TimeInterval = 30

    @Published private(set) var snapshot: BluetoothSnapshot?
    @Published private(set) var at: Date?
    /// system_profiler 를 마지막에 못 읽었다 (이전 값을 보이는 중)
    @Published private(set) var readFailed = false
    /// 블루투스 권한이 거부돼 GATT 배터리를 못 읽는다
    @Published private(set) var gattDenied = false
    /// 진행 중인 동작: "power" 또는 기기 주소
    @Published private(set) var busy: String?

    private var raw: BluetoothSnapshot?
    /// raw 를 쓸 때마다 올린다 — 동작 전에 시작한 느린 읽기가 동작 뒤의 새 값을 덮지 않게
    private var rawGeneration = 0
    private var gattByAddress: [String: Int] = [:]
    private var gattByName: [String: Int] = [:]
    private var gattAt: Date?
    /// macOS 전원 소스의 액세서리 배터리 (이름 → %, pmset -g accps). system_profiler 를 읽을 때 같이 읽는다.
    private var powerByName: [String: Int] = [:]
    private let reader = GATTBatteryReader()
    private var sampling = false

    /// 사이드바 요약용: 마지막 표본이 오래됐는가
    var isStale: Bool { at.map { Date().timeIntervalSince($0) >= Self.summaryInterval } ?? true }

    func sample(full: Bool, runner: any CommandRunner) async {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }
        let started = rawGeneration
        let read = await BluetoothProbe.snapshot(runner: runner)
        let power = await BluetoothProbe.accessoryBatteries(runner: runner)
        if started == rawGeneration {
            powerByName = power   // raw 와 같은 보호 — 동작 뒤 refresh 가 읽은 새 값을 늦게 끝난 옛 값이 덮지 않게
            if let read {
                raw = read
                rawGeneration += 1
                readFailed = false
                at = Date()   // 확인 시각은 읽은 때만 (실패면 이전 값과 그때 시각을 그대로)
            } else {
                readFailed = true
            }
        }
        if full, raw?.controller?.on == true, gattAt.map({ Date().timeIntervalSince($0) >= Self.gattInterval }) ?? true {
            await readGATT()
        }
        publish()
    }

    /// 동작 뒤처럼 기다리지 않고 바로 다시 읽을 때 (GATT 는 다음 주기에)
    func refresh(runner: any CommandRunner) async {
        rawGeneration += 1   // 진행 중인 표본의 결과는 버린다
        powerByName = await BluetoothProbe.accessoryBatteries(runner: runner)
        if let read = await BluetoothProbe.snapshot(runner: runner) {
            raw = read
            rawGeneration += 1
            readFailed = false
            at = Date()
        }
        publish()
    }

    private func readGATT() async {
        gattAt = Date()
        switch await reader.read() {
        case .readings(let readings):
            gattDenied = false
            let addresses = BluetoothProbe.addressesByIdentifier()
            gattByAddress = [:]
            gattByName = [:]
            for reading in readings {
                if let address = addresses[reading.identifier] { gattByAddress[address] = reading.percent }
                if let name = reading.name { gattByName[name] = reading.percent }
            }
        case .denied:
            gattDenied = true
            gattByAddress = [:]   // 옛 값을 계속 보이지 않게
            gattByName = [:]
        case .unavailable:
            // 권한 창에 답하기 전 시간 초과 등 — 60초 기다리지 않고 곧 다시
            gattAt = Date().addingTimeInterval(10 - Self.gattInterval)
        }
    }

    private func publish() {
        guard let raw else { snapshot = nil; return }
        let hid = BluetoothProbe.hidBatteries()
        snapshot = BluetoothParser.merge(raw, byAddress: hid.merging(gattByAddress) { a, _ in a },
                                         byName: gattByName.merging(powerByName) { a, _ in a })
    }

    // MARK: 동작 (확인 창은 AppModel 이 띄운다)

    func setPower(_ on: Bool, runner: any CommandRunner) async -> String? {
        busy = "power"
        defer { busy = nil }
        let error = await BluetoothActions.setPower(on)
        if on { gattAt = nil }   // 켠 뒤엔 배터리도 곧바로 다시
        await refresh(runner: runner)
        return error
    }

    func setConnected(_ device: BluetoothDevice, connect: Bool, runner: any CommandRunner) async -> String? {
        guard let address = device.address else { return "\(device.name) 의 주소를 읽지 못했습니다 · 시스템 설정 > 블루투스에서 하세요" }
        busy = address
        defer { busy = nil }
        if let error = await BluetoothActions.setConnected(address: address, name: device.name, connect: connect) {
            await refresh(runner: runner)
            return error
        }
        if connect { gattAt = nil }
        // API 가 성공이라 해도 실제로 바뀌었는지 다시 읽어 본다 (BLE 기기는 클래식 연결 API 가 모를 수 있다). 반영이 늦을 수 있어 한 번 더.
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            await refresh(runner: runner)
            if snapshot?.devices.first(where: { $0.address == address })?.connected == connect { return nil }
        }
        return connect ? "\(device.name) 에 연결하지 못했습니다 · 기기가 켜져 있고 가까이 있는지 확인하세요"
                       : "\(device.name) 의 연결을 끊지 못했습니다 · 시스템 설정 > 블루투스에서 끊으세요"
    }

    // MARK: 판정 (사이드바·머리글 공통)

    var health: (level: SystemHealth.Level?, text: String) { BluetoothHealth.judge(snapshot) }

    var summary: String {
        guard at != nil else { return "확인 중…" }
        return health.text
    }
}
