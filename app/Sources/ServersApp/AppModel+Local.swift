// LOCAL 의 이 Mac 모니터(시스템·디스크·블루투스): 창이 보일 때만 수집한다. 화면이 떠 있으면 그 화면의 루프(.sampling)가, 아니면 5초 갱신이 사이드바 요약만.

import AppKit
import Foundation
import ServersCore

extension AppModel {
    /// `--sample-hidden` 으로 실행하면 창이 가려져 있어도 수집한다 (화면 확인용 — 다른 Space·앱을 쓰는 중에 창만 캡처할 때)
    private static let sampleWhenHidden = CommandLine.arguments.contains("--sample-hidden")

    /// 본창이 화면에 보이는가 — 숨김(닫기 버튼)·최소화·앱 숨기기·다른 창에 완전히 가려짐·다른 Space 면 false
    static var mainWindowVisible: Bool {
        sampleWhenHidden || NSApp.windows.contains { $0.delegate is AppDelegate && $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// 창이 다시 보이면(숨김·최소화·가려짐 → 보임) 바로 한 바퀴 돈다 — 가려진 동안 건너뛴 선택 화면 정보(fetchNetworkInfoIfSelected)를 기다리지 않게
    func installVisibilityObserver() {
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.screenFetchSkipped, Self.mainWindowVisible else { return }
                self.requestRefresh()
            }
        }
    }

    /// 5초 갱신 끝에서 부른다: 사이드바 요약만 가볍게. 그 화면을 보고 있으면 화면 루프가 전부 읽으므로 건너뛴다.
    func sampleLocalSummaries() async {
        guard Self.mainWindowVisible else { return }
        if selectedKey != Self.systemKey { await system.sample(full: false, runner: runner) }
        if selectedKey != Self.diskKey { await disk.sample(full: false, runner: runner) }
        if selectedKey != Self.bluetoothKey, bluetooth.isStale { await bluetooth.sample(full: false, runner: runner) }
    }

    // MARK: 블루투스 동작 (bt.zsh 처럼 끊는 쪽은 확인을 거친다)

    func toggleBluetoothPower() {
        guard let on = bluetooth.snapshot?.controller?.on, bluetooth.busy == nil else { return }
        if on {
            pendingConfirm = PendingConfirm(title: "블루투스 끄기",
                                            message: "블루투스 키보드·마우스·이어폰 연결이 모두 끊깁니다. 이 Mac 의 내장·유선 입력 장치로 다시 켤 수 있습니다.") { [weak self] in
                self?.runBluetoothPower(false)
            }
        } else {
            runBluetoothPower(true)
        }
    }

    private func runBluetoothPower(_ on: Bool) {
        Task {
            if let error = await bluetooth.setPower(on, runner: runner) {
                statusMessage = error
            } else {
                statusMessage = on ? "블루투스를 켰습니다." : "블루투스를 껐습니다."
            }
        }
    }

    func setBluetoothConnection(_ device: BluetoothDevice, connect: Bool) {
        guard bluetooth.busy == nil else { return }
        if connect {
            runBluetoothConnection(device, connect: true)
        } else {
            pendingConfirm = PendingConfirm(title: "\(device.name) 연결 끊기",
                                            message: "\(device.name) 의 연결을 끊습니다. 다시 연결은 이 화면의 [연결]로 합니다.") { [weak self] in
                self?.runBluetoothConnection(device, connect: false)
            }
        }
    }

    private func runBluetoothConnection(_ device: BluetoothDevice, connect: Bool) {
        Task {
            if let error = await bluetooth.setConnected(device, connect: connect, runner: runner) {
                statusMessage = error
            } else {
                statusMessage = connect ? "\(device.name) 을 연결했습니다." : "\(device.name) 의 연결을 끊었습니다."
            }
        }
    }
}
