// 앱 업데이트: Sparkle 연결(AppUpdater)을 시작하고, 다시 시작으로 끊길 것(탭·터널·전송)을 확인받는다.

import Foundation
import ServersCore

extension AppModel {
    /// 창이 처음 뜰 때 한 번. 검증용 지정 목록(--conf)으로 띄운 인스턴스는 확인하지 않는다.
    func startUpdater() {
        guard updater == nil, AppModel.configOverride == nil else { return }
        let updater = AppUpdater(
            publish: { [weak self] state in self?.appUpdate = state },
            notice: { [weak self] message in self?.statusMessage = message },
            canRestartNow: { [weak self] in
                guard let self else { return true }
                return AppUpdate.restartsImmediately(confirmed: updateConfirmedWork, now: restartCuts.total)
            })
        updater.start()
        self.updater = updater
    }

    /// 메뉴 Nexus ▸ 업데이트 확인…
    func checkForUpdates() { updater?.check() }

    /// 다시 시작하면 끊기는 것: 열린 터미널 탭 · 연결된 터널 · 진행 중인 전송
    private var restartCuts: (tabs: Int, tunnels: Int, transfers: Int, total: Int) {
        let running = transfers.filter { if case .running = $0.state { true } else { false } }.count
        let open = tunnels.filter { $0.state == .open || $0.state == .connecting }.count   // 기록만 남은(닫힌·아직 안 연) 터널은 끊길 게 없다
        return (tabs.count, open, running, tabs.count + open + running)
    }

    /// 띠의 버튼 ([업데이트] · [다시 시작] · [다시 시도]). 받아서 바꾼 뒤 앱이 다시 시작된다 — 끊길 것이 있으면 먼저 확인받고,
    /// 확인한 개수를 적어 둔다: 받는 사이 더 늘면 설치 직전에 멈춰 [다시 시작]으로 한 번 더 묻는다 (AppUpdate.restartsImmediately).
    func installUpdate() {
        let cuts = restartCuts
        guard let warning = AppUpdate.restartWarning(tabs: cuts.tabs, tunnels: cuts.tunnels, transfers: cuts.transfers) else {
            updateConfirmedWork = 0
            updater?.install()
            return
        }
        pendingConfirm = PendingConfirm(title: "업데이트하고 다시 시작", message: warning) { [weak self] in
            self?.updateConfirmedWork = cuts.total
            self?.updater?.install()
        }
    }
}
