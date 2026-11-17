// 블루투스 화면의 앱 쪽 동작 (~/.tools/bt-helpers/btctl.m 과 같은 API):
//   GATT 배터리 — CoreBluetooth 로 이미 연결된 기기의 배터리 서비스(180F)·레벨(2A19)을 한 번 읽는다 (5초 제한, 읽고 나면 앱 쪽 연결만 놓는다).
//   연결·끊기 — IOBluetoothDevice openConnection/closeConnection (블로킹이라 메인 스레드 밖에서).
//   전원 — 비공개 IOBluetoothPreference{Get,Set}ControllerPowerState (blueutil·btctl 과 같다). 바뀔 때까지 10초 기다린다.
// CoreBluetooth·IOBluetooth 는 처음 쓸 때 macOS 블루투스 권한을 묻는다 (Info.plist NSBluetoothAlwaysUsageDescription).

import CoreBluetooth
import Foundation
import IOBluetooth

@MainActor
final class GATTBatteryReader: NSObject {
    enum Outcome {
        /// CoreBluetooth 식별자(대문자) · 이름 · %
        case readings([(identifier: String, name: String?, percent: Int)])
        case denied
        case unavailable
    }

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    private var central: CBCentralManager?
    private var peripherals: [CBPeripheral] = []
    /// 아직 읽기를 기다리는 기기 — 한 기기에 배터리 서비스가 둘이어도 한 번만 센다
    private var pending: Set<UUID> = []
    /// 이번 읽기에서 poweredOn 까지 갔는가 (아니면 시간 초과는 "읽을 게 없음"이 아니라 "못 읽음")
    private var reachedPoweredOn = false
    private var results: [(identifier: String, name: String?, percent: Int)] = []
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var generation = 0

    func read(timeout: TimeInterval = 5) async -> Outcome {
        guard continuation == nil else { return .unavailable }
        generation += 1
        let round = generation
        results = []
        pending = []
        reachedPoweredOn = false
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if let central {
                started(central)
            } else {
                central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if self.generation == round { self.finish(self.reachedPoweredOn ? .readings(self.results) : .unavailable) }
            }
        }
    }

    /// 상태가 정해지면 시작 (처음엔 unknown → 권한 창 → poweredOn/unauthorized)
    fileprivate func started(_ central: CBCentralManager) {
        guard continuation != nil else { return }
        switch central.state {
        case .poweredOn: reachedPoweredOn = true
        case .unauthorized: finish(.denied); return
        case .unknown, .resetting: return   // 다음 상태 알림을 기다린다
        default: finish(.unavailable); return
        }
        peripherals = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        pending = Set(peripherals.map(\.identifier))
        guard !pending.isEmpty else { finish(.readings([])); return }
        for peripheral in peripherals {
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    fileprivate func finishOne(_ peripheral: CBPeripheral) {
        guard pending.remove(peripheral.identifier) != nil else { return }
        if pending.isEmpty { finish(.readings(results)) }
    }

    fileprivate func record(_ peripheral: CBPeripheral, _ value: Data?) {
        if pending.contains(peripheral.identifier), let byte = value?.first, byte <= 100 {
            results.append((peripheral.identifier.uuidString.uppercased(), peripheral.name, Int(byte)))
        }
        finishOne(peripheral)
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        generation += 1
        for peripheral in peripherals { central?.cancelPeripheralConnection(peripheral) }   // 앱 쪽 연결만 놓는다 (시스템 연결은 그대로)
        peripherals = []
        continuation.resume(returning: outcome)
    }
}

// 대리자는 queue: .main 으로 만들었으므로 메인 스레드에서 불린다 — 메인 액터 격리 준수로 선언해 컴파일러가 확인한다
extension GATTBatteryReader: @MainActor CBCentralManagerDelegate, @MainActor CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        started(central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishOne(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else { finishOne(peripheral); return }
        for service in services { peripheral.discoverCharacteristics([Self.batteryLevel], for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let level = service.characteristics?.first else { finishOne(peripheral); return }
        peripheral.readValue(for: level)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        record(peripheral, error == nil ? characteristic.value : nil)
    }
}

enum BluetoothActions {
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void

    /// 비공개 전원 함수 (IOBluetooth 프레임워크에서 이름으로 찾는다 — 없어졌으면 nil)
    private static let power: (get: GetPower, set: SetPower)? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW),
              let get = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
              let set = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return (unsafeBitCast(get, to: GetPower.self), unsafeBitCast(set, to: SetPower.self))
    }()

    /// 전원 함수를 찾았는가 (비공개 API — 없어졌으면 전원 버튼을 비활성으로)
    static var canSetPower: Bool { power != nil }

    /// 켜고 끈다. 실패 문구 [문제 · 해결] 또는 nil.
    static func setPower(_ on: Bool) async -> String? {
        guard let (getPower, setPower) = power else { return "블루투스 전원을 바꾸지 못했습니다 · 시스템 설정 > 블루투스에서 바꾸세요" }
        let want: Int32 = on ? 1 : 0
        if getPower() == want { return nil }
        setPower(want)
        for _ in 0..<100 {   // 비동기로 바뀐다 — blueutil 처럼 10초까지
            try? await Task.sleep(for: .milliseconds(100))
            if getPower() == want { return nil }
        }
        return "블루투스가 10초 안에 \(on ? "켜지지" : "꺼지지") 않았습니다 · 시스템 설정 > 블루투스를 확인하세요"
    }

    /// 연결·끊기 전용 큐 — openConnection 은 몇 초씩 막혀 Swift 동시성 스레드를 붙잡지 않게 따로 돌린다 (한 번에 하나)
    private static let queue = DispatchQueue(label: "nexus.bluetooth.connection")

    /// 연결·끊기. 실패 문구 [문제 · 해결] 또는 nil. 돌려준 nil 은 "API 가 성공을 알렸다" 까지 — 실제 상태는 BluetoothMonitor 가 다시 읽어 확인한다.
    static func setConnected(address: String, name: String, connect: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: connection(address: address, name: name, connect: connect)) }
        }
    }

    private static func connection(address: String, name: String, connect: Bool) -> String? {
        guard let device = IOBluetoothDevice(addressString: address) else { return "\(name) 의 주소를 읽지 못했습니다 · 목록을 새로 읽은 뒤 다시 하세요" }
        if connect {
            if device.isConnected() { return nil }
            let result = device.openConnection()
            guard result == kIOReturnSuccess, device.isConnected() else {
                return "\(name) 에 연결하지 못했습니다 · 기기가 켜져 있고 가까이 있는지 확인하세요 (iPhone·iPad 는 여기서 연결되지 않습니다)"
            }
            return nil
        } else {
            guard device.isConnected() else { return nil }
            guard device.closeConnection() == kIOReturnSuccess else { return "\(name) 의 연결을 끊지 못했습니다 · 다시 하거나 시스템 설정 > 블루투스에서 끊으세요" }
            return nil
        }
    }
}
