// 이 Mac 의 블루투스 (블루투스 화면). ~/.tools/bt.zsh 를 옮긴 것.
//   컨트롤러·기기: system_profiler -json SPBluetoothDataType (AirPods 의 왼쪽·오른쪽·케이스 배터리는 이 길뿐).
//   배터리 보충: HID 레지스트리(Magic 키보드·마우스·트랙패드의 BatteryPercent) · GATT 배터리 서비스(로지텍 마우스 등 — 앱의 CoreBluetooth)
//   · macOS 전원 소스(`pmset -g accps` — 소니 헤드셋처럼 HFP 로 배터리를 알리는 기기. 주소가 없어 이름으로 붙인다).
//   파싱·병합·판정은 순수 함수라 테스트한다. 연결·끊기·전원은 앱(BluetoothActions).

import Foundation
import IOKit

public struct BluetoothController: Sendable, Equatable {
    public let on: Bool
    public let address: String?
    public let chipset: String?
    public let firmware: String?
    public let transport: String?
    public let discoverable: Bool?
    public let services: [String]
    public let vendor: String?
}

public struct BluetoothBattery: Sendable, Equatable {
    public enum Part: String, Sendable, Equatable { case main = "", left = "왼쪽", right = "오른쪽", case_ = "케이스" }
    public let part: Part
    public let percent: Int
    public init(part: Part, percent: Int) { self.part = part; self.percent = percent }
}

public struct BluetoothDevice: Sendable, Equatable, Identifiable {
    public var id: String { address ?? name }
    public let name: String
    public let address: String?
    public let connected: Bool
    public let minorType: String?
    public let rssi: Int?
    public var batteries: [BluetoothBattery]
    public let vendorID: String?
    public let productID: String?
    public let firmware: String?
    public let caseVersion: String?
    public let services: [String]
    /// "" 본체 · 왼쪽 · 오른쪽 → 일련번호
    public let serials: [String: String]

    public var lowestBattery: Int? { batteries.map(\.percent).min() }
}

public struct BluetoothSnapshot: Sendable, Equatable {
    public let controller: BluetoothController?
    public var devices: [BluetoothDevice]
    public var connected: [BluetoothDevice] { devices.filter(\.connected) }
    public var paired: [BluetoothDevice] { devices.filter { !$0.connected } }
}

public enum BluetoothParser {
    /// system_profiler 의 기기 종류 → 화면 이름. 모르는 종류는 그대로.
    public static func typeName(_ minorType: String?) -> String? {
        guard let minorType else { return nil }
        let names = ["Keyboard": "키보드", "Mouse": "마우스", "Headphones": "헤드폰", "Headset": "헤드셋", "Speaker": "스피커",
                     "Magic Trackpad": "트랙패드", "Trackpad": "트랙패드", "Gamepad": "게임패드", "Phone": "전화기", "Watch": "시계"]
        return names[minorType] ?? minorType
    }

    /// "0x980019 < HFP AVRCP A2DP AACP GATT ACL >" → ["HFP", …]
    public static func services(_ text: String?) -> [String] {
        guard let text, let open = text.firstIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else { return [] }
        return text[text.index(after: open)..<close].split(separator: " ").map(String.init)
    }

    /// "76%" → 76 (0~100 밖은 버린다)
    public static func percent(_ value: Any?) -> Int? {
        let text = (value as? String)?.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let number = text.flatMap(Int.init) ?? (value as? NSNumber)?.intValue, (0...100).contains(number) else { return nil }
        return number
    }

    /// "aa-bb-cc-dd-ee-ff" · "aabbccddeeff" · "AA:BB:…" → "AA:BB:CC:DD:EE:FF"
    public static func normalizeAddress(_ raw: String) -> String {
        let hex = raw.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return raw.uppercased() }
        return stride(from: 0, to: 12, by: 2).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)])
        }.joined(separator: ":")
    }

    /// system_profiler -json SPBluetoothDataType. 모양이 다르면 nil.
    public static func parse(_ data: Data) -> BluetoothSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
        var controller: BluetoothController?
        if let c = entry["controller_properties"] as? [String: Any] {
            controller = BluetoothController(on: (c["controller_state"] as? String) == "attrib_on",
                                             address: c["controller_address"] as? String, chipset: c["controller_chipset"] as? String,
                                             firmware: c["controller_firmwareVersion"] as? String, transport: c["controller_transport"] as? String,
                                             discoverable: (c["controller_discoverable"] as? String).map { $0 == "attrib_on" },
                                             services: services(c["controller_supportedServices"] as? String), vendor: c["controller_vendorID"] as? String)
        }
        var devices: [BluetoothDevice] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for item in entry[key] as? [[String: Any]] ?? [] {
                for (name, value) in item {
                    guard let props = value as? [String: Any] else { continue }
                    devices.append(device(name: name, props: props, connected: connected))
                }
            }
        }
        return BluetoothSnapshot(controller: controller, devices: devices)
    }

    static func device(name: String, props: [String: Any], connected: Bool) -> BluetoothDevice {
        var batteries: [BluetoothBattery] = []
        // 키 이름이 기기마다 다르다 (Left·Right·Case, 하나짜리는 Main 등) — device_batteryLevel 로 시작하면 다 읽는다
        for (key, value) in props where key.hasPrefix("device_batteryLevel") {
            guard let percent = percent(value) else { continue }
            let suffix = key.dropFirst("device_batteryLevel".count)
            let part: BluetoothBattery.Part = suffix == "Left" ? .left : suffix == "Right" ? .right : suffix == "Case" ? .case_ : .main
            batteries.append(BluetoothBattery(part: part, percent: percent))
        }
        let order: [BluetoothBattery.Part] = [.main, .left, .right, .case_]
        batteries.sort { order.firstIndex(of: $0.part)! < order.firstIndex(of: $1.part)! }
        var serials: [String: String] = [:]
        if let s = props["device_serialNumber"] as? String { serials[""] = s }
        if let s = props["device_serialNumberLeft"] as? String { serials["왼쪽"] = s }
        if let s = props["device_serialNumberRight"] as? String { serials["오른쪽"] = s }
        return BluetoothDevice(name: name, address: (props["device_address"] as? String).map(normalizeAddress), connected: connected,
                               minorType: props["device_minorType"] as? String,
                               rssi: (props["device_rssi"] as? String).flatMap { Int($0) } ?? (props["device_rssi"] as? NSNumber)?.intValue,
                               batteries: batteries, vendorID: props["device_vendorID"] as? String, productID: props["device_productID"] as? String,
                               firmware: props["device_firmwareVersion"] as? String, caseVersion: props["device_caseVersion"] as? String,
                               services: services(props["device_services"] as? String), serials: serials)
    }

    /// `pmset -g accps` → 이름 → %. " -WH-1000XM5 (id=25826630)\t60%; discharging present: true" 꼴.
    /// 이름 없는 줄(AirPods 의 왼쪽·오른쪽 등)과 이 Mac 내장 배터리는 뺀다. 같은 이름이 둘이면 어느 기기 것인지 모르므로 뺀다.
    public static func parseAccessoryPower(_ text: String) -> [String: Int] {
        var out: [String: Int] = [:]
        var duplicated: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: /^\s*-(.+?) \(id=\d+\)\s+(\d+)%/) else { continue }
            let name = match.1.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("InternalBattery"), let percent = Int(match.2), (0...100).contains(percent) else { continue }
            if out[name] != nil { duplicated.insert(name) }
            out[name] = percent
        }
        for name in duplicated { out[name] = nil }
        return out
    }

    /// system_profiler 에 배터리가 없는 연결 기기에만 다른 출처의 값을 채운다 (주소로, 주소가 없으면 같은 이름이 하나뿐일 때 이름으로).
    public static func merge(_ snapshot: BluetoothSnapshot, byAddress: [String: Int], byName: [String: Int] = [:]) -> BluetoothSnapshot {
        var merged = snapshot
        let nameCounts = Dictionary(snapshot.devices.map { ($0.name, 1) }, uniquingKeysWith: +)
        for index in merged.devices.indices where merged.devices[index].connected && merged.devices[index].batteries.isEmpty {
            let device = merged.devices[index]
            let value = device.address.flatMap { byAddress[$0] } ?? (nameCounts[device.name] == 1 ? byName[device.name] : nil)
            if let value { merged.devices[index].batteries = [BluetoothBattery(part: .main, percent: value)] }
        }
        return merged
    }
}

// MARK: 판정 · 표시

public enum BluetoothHealth {
    /// bt.zsh 와 같은 기준: 배터리 30% 이하 노랑 · 15% 이하 빨강
    public static func batteryLevel(_ percent: Int) -> SystemHealth.Level {
        percent <= 15 ? .bad : (percent <= 30 ? .warn : .good)
    }

    /// RSSI 판정 (bt.zsh): -60 이상 좋음 · -75 이상 보통 · 그 아래 약함
    public static func signalText(_ rssi: Int) -> String {
        rssi >= -60 ? "좋음" : (rssi >= -75 ? "보통" : "약함")
    }

    /// nil 이면 꺼짐·모름 (회색)
    public static func judge(_ snapshot: BluetoothSnapshot?) -> (level: SystemHealth.Level?, text: String) {
        guard let snapshot, let controller = snapshot.controller else { return (nil, "정보를 읽지 못했습니다") }
        guard controller.on else { return (nil, "꺼짐") }
        let low = snapshot.connected.compactMap { device in device.lowestBattery.map { (device.name, $0) } }.min { $0.1 < $1.1 }
        if let low, batteryLevel(low.1) == .bad { return (.bad, "배터리 부족 · \(low.0) \(low.1)%") }
        if let low, batteryLevel(low.1) == .warn { return (.warn, "배터리 낮음 · \(low.0) \(low.1)%") }
        return (.good, "켜짐 · \(snapshot.connected.count)개 연결")
    }

    /// "왼쪽 76% · 오른쪽 70% · 케이스 93%" · "65%"
    public static func batteryText(_ batteries: [BluetoothBattery]) -> String? {
        guard !batteries.isEmpty else { return nil }
        return batteries.map { $0.part == .main ? "\($0.percent)%" : "\($0.part.rawValue) \($0.percent)%" }.joined(separator: " · ")
    }
}

// MARK: 읽기

public enum BluetoothProbe {
    public static func snapshot(runner: any CommandRunner) async -> BluetoothSnapshot? {
        let result = await runner.run("system_profiler", ["-json", "SPBluetoothDataType"], timeout: 15)
        guard result.ok, let data = result.stdout.data(using: .utf8) else { return nil }
        return BluetoothParser.parse(data)
    }

    /// macOS 전원 소스의 액세서리 배터리 (이름 → %). 못 읽으면 빈 값 — 다른 출처로 보이던 배터리는 그대로.
    public static func accessoryBatteries(runner: any CommandRunner) async -> [String: Int] {
        let result = await runner.run("pmset", ["-g", "accps"], timeout: 5)
        return result.ok ? BluetoothParser.parseAccessoryPower(result.stdout) : [:]
    }

    /// Magic 키보드·마우스·트랙패드: HID 레지스트리의 DeviceAddress → BatteryPercent (권한 없이 읽힌다)
    public static func hidBatteries() -> [String: Int] {
        var out: [String: Int] = [:]
        forEach("AppleDeviceManagementHIDEventService") { address, entry in
            if let percent = BluetoothParser.percent(property(entry, "BatteryPercent")) { out[address] = percent }
        }
        return out
    }

    /// CoreBluetooth 식별자(PhysicalDeviceUniqueID, 대문자) → 블루투스 주소. GATT 배터리를 기기에 붙일 때 쓴다 (btctl 의 hid_addresses).
    public static func addressesByIdentifier() -> [String: String] {
        var out: [String: String] = [:]
        forEach("IOHIDDevice") { address, entry in
            if let identifier = property(entry, "PhysicalDeviceUniqueID") as? String { out[identifier.uppercased()] = address }
        }
        return out
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func forEach(_ className: String, _ body: (String, io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let raw = property(entry, "DeviceAddress") as? String else { continue }
            body(BluetoothParser.normalizeAddress(raw), entry)
        }
    }
}
