// 앱 업데이트: Sparkle 연결(AppUpdater)을 시작하고, 띠의 [업데이트] 전에 끊길 것을 확인받는다.

import Foundation
import ServersCore

extension AppModel {
    /// 창이 처음 뜰 때 한 번. 검증용 지정 목록(--conf)으로 띄운 인스턴스는 확인하지 않는다.
    func startUpdater() {
        guard updater == nil, AppModel.configOverride == nil else { return }
        let updater = AppUpdater(apply: { [weak self] event in
            guard let self else { return }
            let next = appUpdate.applying(event)
            if next != appUpdate { appUpdate = next }   // 받는 중 알림은 잦다 — 값이 같으면 화면을 깨우지 않는다
        }, notice: { [weak self] message in self?.statusMessage = message })
        updater.start()
        self.updater = updater
    }

    /// 메뉴 Nexus ▸ 업데이트 확인…
    func checkForUpdates() { updater?.check() }

    /// 띠의 [업데이트] · [다시 시도]. 받아서 바꾼 뒤 앱이 다시 시작된다 — 끊길 탭·터널·전송이 있으면 먼저 확인받는다.
    func installUpdate() {
        let running = transfers.filter { if case .running = $0.state { true } else { false } }.count
        guard let warning = AppUpdate.restartWarning(tabs: tabs.count, tunnels: tunnels.count, transfers: running) else {
            updater?.install()
            return
        }
        pendingConfirm = PendingConfirm(title: "업데이트하고 다시 시작", message: warning) { [weak self] in
            self?.updater?.install()
        }
    }
}
