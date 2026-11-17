// macOS 알림: 서버 켜짐·꺼짐 (servers.conf notify=on, 판정은 ServersCore.PowerWatch) · 파일 전송 완료·실패 (문구는 TransferNotice).
// 알림을 누르면 창을 열고 그 서버를 고른다 (PowerNotificationHandler — AppDelegate 가 쥔다).

import AppKit
import ServersCore
import UserNotifications

extension AppModel {
    /// 알림 userInfo 의 서버 키
    nonisolated static let notifyServerKey = "serverKey"

    /// 상태 갱신마다 (refreshNow): notify=on 서버의 전원 상태를 먹이고, 확인된 전이만 알린다.
    func notifyPowerChanges() {
        guard let config else { return }
        let watched = config.servers.filter(\.notify)
        powerWatch.retain(keys: Set(watched.map(\.key)))
        guard !watched.isEmpty else { return }
        requestNotifyAuthorizationIfNeeded()
        let now = Date()
        for server in watched {
            let state = PowerWatch.state(of: server, in: status, among: config.servers)
            if let event = powerWatch.observe(server.key, state, at: now) { postPowerNotification(server, event) }
        }
    }

    /// 잠자기에서 깬 직후엔 망이 덜 올라와 확인이 실패한다 — PowerWatch 가 잠시 판단을 쉬게 알린다
    func installWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.powerWatch.noteWake(at: Date()) }
        }
    }

    /// 전송이 끝났을 때 (AppModel+Transfers 의 onExit). 실패는 항상, 완료는 오래 걸린 것만 (TransferNotice).
    func notifyTransferFinished(_ session: TransferSession) {
        let elapsed = Date().timeIntervalSince(session.startedAt)
        guard let text = TransferNotice.content(for: session.state, spec: session.spec, elapsed: elapsed) else { return }
        postNotification(identifier: "transfer-\(session.id)", title: text.title, body: text.body, serverKey: session.server.key)
    }

    /// 알림을 쓸 일이 생기면(notify=on 서버·전송 시작) 한 번만 권한을 묻는다 (시스템은 처음 한 번만 창을 띄운다). 거부돼 있으면 상태줄에 알린다.
    func requestNotifyAuthorizationIfNeeded() {
        guard !notifyAuthRequested else { return }
        notifyAuthRequested = true
        Task {
            do {
                if try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { return }
                statusMessage = "알림 권한이 없습니다 — 시스템 설정 › 알림 › Nexus 에서 허용하세요"
            } catch {
                statusMessage = "알림 권한 요청 실패: \(error.localizedDescription)"
            }
        }
    }

    private func postPowerNotification(_ server: Server, _ event: PowerEvent) {
        // 같은 서버의 이전 알림은 새 것으로 바뀐다 (알림 센터에 쌓이지 않게)
        postNotification(identifier: "power-\(server.key)", title: "\(server.key) " + (event == .booted ? "켜짐" : "꺼짐"),
                         body: [server.role, server.ip].compactMap { $0 }.joined(separator: " · "), serverKey: server.key)
    }

    /// 같은 identifier 의 알림은 교체된다. 누르면 serverKey 의 서버를 고른다 (PowerNotificationHandler).
    private func postNotification(identifier: String, title: String, body: String, serverKey: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [AppModel.notifyServerKey: serverKey]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) } catch {
                statusMessage = "\(title) 알림을 띄우지 못했습니다: \(error.localizedDescription)"
            }
        }
    }
}

/// 알림 센터 delegate: 앱이 앞에 있어도 배너를 띄우고, 알림을 누르면 창을 열어 그 서버를 고른다.
@MainActor
final class PowerNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: AppModel?
    private let showWindow: () -> Void

    init(model: AppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// 기본은 앱이 앞에 있으면 알림 센터에만 넣는다
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo[AppModel.notifyServerKey] as? String
        await MainActor.run {
            showWindow()
            if let key, let model, model.config?.server(key) != nil { model.selectedKey = key }
        }
    }
}
