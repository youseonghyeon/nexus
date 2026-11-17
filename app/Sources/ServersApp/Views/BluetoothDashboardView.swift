// 블루투스 화면: 사이드바 LOCAL 의 Bluetooth 행. ~/.tools/bt.zsh 를 옮긴 것.
// 머리글(칩셋 · 상태 · 전원) → 배터리 타일(연결된 기기) → 연결된 기기(신호·배터리·끊기) → 페어링된 기기(연결) → 컨트롤러.
// 기기 행을 누르면 세부(제조사·제품 ID·펌웨어·서비스·일련번호)를 펼친다. 검색·페어링은 시스템 설정에 맡긴다.
// 화면이 떠 있고 창이 보일 때만 설정한 간격(AppPreferences.bluetoothInterval, 기본 5초)마다 읽는다 (BluetoothMonitor).

import AppKit
import ServersCore
import SwiftUI

struct BluetoothDashboardView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var monitor: BluetoothMonitor
    @AppStorage(AppPreferences.bluetoothInterval.key) private var interval = AppPreferences.bluetoothInterval.defaultValue
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                let live = monitor.snapshot.flatMap { $0.controller?.on == true && !$0.connected.isEmpty ? $0 : nil }
                HeroCard(hasStrip: live != nil) { header } strip: {
                    if let live { batteryTiles(live) }
                }
                connectedCard
                pairedCard
                controllerCard
            }
            .padding(EdgeInsets(top: 0, leading: 40, bottom: 20, trailing: 40))   // 위는 툴바가 이미 띄워 준다
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)   // 스크롤 영역은 창 폭 전체 — 툴바 밑 띠가 1200 에서 끊기지 않게
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sampling(every: { AppSettings.interval(AppPreferences.bluetoothInterval) }) { await monitor.sample(full: true, runner: model.runner) }
    }

    private var controller: BluetoothController? { monitor.snapshot?.controller }
    private var isOn: Bool { controller?.on == true }

    // MARK: 머리글

    private var header: some View {
        let health = monitor.health
        return LocalHeader(title: "Bluetooth", subtitle: subtitle, tone: health.level?.tone ?? .muted,
                           conclusion: monitor.at == nil ? "확인 중…" : health.text, checkedAt: monitor.at,
                           interval: monitor.readFailed ? "새로 읽지 못했습니다" : "\(Int(AppPreferences.bluetoothInterval.resolve(interval)))초 간격")
    }

    private var subtitle: String {
        guard let controller else { return monitor.readFailed ? "블루투스 정보를 읽지 못했습니다" : "이 Mac 의 블루투스" }
        return [controller.chipset, controller.transport, controller.firmware.map { "펌웨어 \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: 배터리 타일

    private func batteryTiles(_ snapshot: BluetoothSnapshot) -> some View {
        MetricGrid(minimum: 170) {
            ForEach(snapshot.connected) { device in
                let lowest = device.lowestBattery
                let level = lowest.map(BluetoothHealth.batteryLevel) ?? .good
                MetricTile(title: device.name, value: lowest.map(String.init) ?? "–", unit: lowest == nil ? nil : "%",
                           caption: [BluetoothParser.typeName(device.minorType), device.batteries.count > 1 ? BluetoothHealth.batteryText(device.batteries) : nil,
                                     lowest == nil ? "배터리 정보 없음" : nil].compactMap { $0 }.joined(separator: " · "),
                           tone: level.valueTone, systemImage: symbol(device)) {
                    if let lowest {
                        MeterBar(level: Double(lowest) / 100, tone: level.tone)
                    }
                }
            }
        }
    }

    // MARK: 연결된 기기

    private var connectedCard: some View {
        InfoCard(title: "연결된 기기") {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot = monitor.snapshot, isOn {
                    if snapshot.connected.isEmpty {
                        Text("연결된 기기가 없습니다.").foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.connected) { device in deviceRow(device) }
                    }
                } else {
                    Text(monitor.snapshot == nil ? (monitor.readFailed ? "블루투스 정보를 읽지 못했습니다." : "확인 중…") : "블루투스가 꺼져 있습니다.")
                        .foregroundStyle(.secondary)
                }
                if monitor.gattDenied, isOn {
                    HStack(spacing: 8) {
                        Text("블루투스 권한이 없어 일부 기기의 배터리를 읽지 못했습니다 · 시스템 설정 > 개인정보 보호 및 보안 > 블루투스")
                            .font(.caption).foregroundStyle(StatusTone.warn.color)
                        Button("설정 열기") { openBluetoothPrivacy() }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    // MARK: 페어링된 기기

    private var pairedCard: some View {
        InfoCard(title: "페어링된 기기") {
            if let snapshot = monitor.snapshot {
                if snapshot.paired.isEmpty {
                    Text("연결 안 된 페어링 기기가 없습니다.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.paired) { device in deviceRow(device) }
                    }
                }
            } else {
                Text(monitor.readFailed ? "블루투스 정보를 읽지 못했습니다." : "확인 중…").foregroundStyle(.secondary)
            }
        }
    }

    private func deviceRow(_ device: BluetoothDevice) -> some View {
        let open = expanded.contains(device.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary).frame(width: 10)
                Image(systemName: symbol(device)).foregroundStyle(.secondary).frame(width: 18)
                Text(device.name).fontWeight(.medium).lineLimit(1)
                if let type = BluetoothParser.typeName(device.minorType) { Text(type).foregroundStyle(.secondary) }
                Spacer()
                if let rssi = device.rssi {
                    Text(device.connected ? "\(rssi) dBm · \(BluetoothHealth.signalText(rssi))" : "근처 \(rssi) dBm")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                if let text = BluetoothHealth.batteryText(device.batteries) {
                    let level = BluetoothHealth.batteryLevel(device.lowestBattery ?? 100)
                    Text(text).font(.callout).monospacedDigit().foregroundStyle(level == .good ? Color.primary : level.tone.color)
                }
                actionButton(device)
            }
            .contentShape(Rectangle())
            .onTapGesture { if open { expanded.remove(device.id) } else { expanded.insert(device.id) } }
            if open { details(device).padding(.leading, 38) }
        }
    }

    @ViewBuilder
    private func actionButton(_ device: BluetoothDevice) -> some View {
        if let address = device.address, monitor.busy == address {
            ProgressView().controlSize(.small).frame(width: 52)
        } else {
            Button(device.connected ? "끊기" : "연결") { model.setBluetoothConnection(device, connect: !device.connected) }
                .buttonStyle(CompactButtonStyle())
                .disabled(device.address == nil || !isOn || monitor.busy != nil)
        }
    }

    private func details(_ device: BluetoothDevice) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            InfoRow("주소", device.address ?? "–")
            if let vendor = device.vendorID { InfoRow("제조사 ID", vendor) }
            if let product = device.productID { InfoRow("제품 ID", product) }
            if let firmware = device.firmware { InfoRow("펌웨어", firmware) }
            if let caseVersion = device.caseVersion { InfoRow("케이스 펌웨어", caseVersion) }
            if !device.services.isEmpty { InfoRow("서비스", device.services.joined(separator: " ")) }
            ForEach(device.serials.sorted { $0.key < $1.key }, id: \.key) { part, serial in
                InfoRow(part.isEmpty ? "일련번호" : "일련번호 (\(part))", serial)
            }
        }
        .font(.callout)
    }

    // MARK: 컨트롤러

    private var controllerCard: some View {
        InfoCard(title: "컨트롤러") {
            if let controller {
                // 전원 버튼은 상태 줄이 있는 카드 오른쪽 (Wi-Fi·Intranet·Tailscale·VPN 과 같은 자리)
                HStack(alignment: .top) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        InfoRow("상태", controller.on ? "켜짐" : "꺼짐")
                        InfoRow("주소", controller.address ?? "–")
                        InfoRow("칩셋", [controller.chipset, controller.vendor].compactMap { $0 }.joined(separator: " · "))
                        InfoRow("Transport", controller.transport ?? "–")
                        InfoRow("펌웨어", controller.firmware ?? "–")
                        InfoRow("검색 허용", controller.discoverable.map { $0 ? "켜짐" : "꺼짐" } ?? "–")
                        InfoRow("지원 프로필", controller.services.isEmpty ? "–" : controller.services.joined(separator: " "))
                    }
                    Spacer()
                    if monitor.busy == "power" {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(isOn ? "끄기" : "켜기") { model.toggleBluetoothPower() }
                            .buttonStyle(CompactButtonStyle())
                            .disabled(!BluetoothActions.canSetPower || monitor.busy != nil)
                    }
                }
            } else {
                Text(monitor.readFailed ? "블루투스 정보를 읽지 못했습니다." : "확인 중…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 도우미

    private func symbol(_ device: BluetoothDevice) -> String {
        switch device.minorType {
        case "Keyboard": return "keyboard"
        case "Mouse": return "computermouse"
        case "Magic Trackpad", "Trackpad": return "rectangle.and.hand.point.up.left"
        case "Headphones", "Headset": return "headphones"
        case "Speaker": return "hifispeaker"
        case "Gamepad": return "gamecontroller"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    private func openBluetoothPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}
