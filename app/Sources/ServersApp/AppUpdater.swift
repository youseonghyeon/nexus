// 앱 안 업데이트: Sparkle 이 확인·받기·서명 검증·교체·재시작을 맡고, 화면은 Sparkle 기본 창 대신 사이드바 띠(UpdateBanner)다.
// 이 클래스는 Sparkle 의 화면 요청(SPUUserDriver)을 AppUpdate 이벤트로 옮기기만 한다 — 상태 판정은 ServersCore AppUpdate.
// 피드 주소·공개 키는 Info.plist (SUFeedURL · SUPublicEDKey), 릴리스 서명은 `make dist`.

import AppKit
import ServersCore
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUserDriver {
    private var updater: SPUUpdater?
    /// 띠의 상태. 보이는 것이 바뀔 때만 publish 로 화면에 알린다 (받는 중 알림은 조각마다 온다)
    private(set) var state: AppUpdate = .none
    private let publish: (AppUpdate) -> Void
    /// 토스트 (직접 확인한 결과 · 띠가 있던 과정의 실패 이유)
    private let notice: (String) -> Void
    /// 설치 준비가 끝났을 때 바로 다시 시작해도 되는가 — 받는 사이 새 탭·터널·전송이 생겼으면 false (AppModel 이 센다)
    private let canRestartNow: () -> Bool
    /// "새 버전 발견"에 대한 답 — 띠의 [업데이트]를 누를 때까지 쥐고 있는다
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    /// "설치 준비 끝"에 대한 답 — 다시 시작을 미뤘을 때만 쥔다 (띠의 [다시 시작])
    private var restartReply: ((SPUUserUpdateChoice) -> Void)?
    /// 메뉴의 [업데이트 확인…] 으로 시작한 확인 — 결과(최신·실패)를 알린다. 주기 확인은 조용히.
    private var userInitiated = false
    /// 실패·중단 뒤 띠의 버튼 — 다시 확인해 발견되면 묻지 않고 바로 받는다
    private var installWhenFound = false
    /// 앱이 안 꺼져 설치가 멈춰 있을 때 종료를 다시 시키는 것 (Sparkle 이 준다) · 그 반복
    private var retryTermination: (() -> Void)?
    private var terminationRetries: Task<Void, Never>?

    init(publish: @escaping (AppUpdate) -> Void, notice: @escaping (String) -> Void, canRestartNow: @escaping () -> Bool) {
        self.publish = publish
        self.notice = notice
        self.canRestartNow = canRestartNow
    }

    /// 켤 때 한 번 확인하고, 그 뒤로는 Sparkle 이 주기(SUScheduledCheckInterval)로 확인한다. 개발 중 띄운 디버그 빌드는 확인하지 않는다 —
    /// 같은 피드를 보므로 공개 버전이 더 높으면 빌드 폴더의 앱이 공개판으로 바뀐다.
    func start() {
        #if DEBUG
        return
        #else
        guard updater == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            self.updater = updater
            // Sparkle 의 주기 확인은 마지막 확인에서 하루가 지나야 돈다 — 켤 때마다 한 번은 바로 본다 (새 버전이 있을 때만 띠가 뜬다).
            // 자동 확인을 꺼 둔 경우(defaults 의 SUEnableAutomaticChecks)는 따른다
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch {
            NSLog("업데이트 확인을 시작하지 못했습니다: %@", error.localizedDescription)
        }
        #endif
    }

    /// 메뉴의 [업데이트 확인…]. 이미 띠가 떠 있으면(받는 중·실패 포함) 다시 확인하는 대신 그 상태를 알린다 — 띠를 못 본 경우
    func check() {
        guard let updater else {
            notice("업데이트를 확인할 수 없습니다 (이 빌드는 업데이트 확인을 하지 않습니다)")
            return
        }
        if let reminder = state.reminder {
            notice(reminder)
        } else if updater.canCheckForUpdates {
            userInitiated = true
            updater.checkForUpdates()
        }
    }

    /// 띠의 버튼: [업데이트] · [다시 시작] · [다시 시도]
    func install() {
        if let reply = restartReply {
            restartReply = nil
            send(.installing)
            reply(.install)
        } else if let reply = installReply {
            installReply = nil
            reply(.install)
        } else if let updater, updater.canCheckForUpdates {
            // 실패했거나 중간에 닫힌 뒤 — 과정을 처음부터. 발견되면 묻지 않고 받는다
            installWhenFound = true
            send(.retrying)
            updater.checkForUpdates()
        }
    }

    private func send(_ event: AppUpdate.Event) {
        let next = state.applying(event)
        let redraw = !next.looksSame(as: state)
        state = next
        if redraw { publish(next) }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 묻지 않는다 — 자동 확인은 Info.plist(SUEnableAutomaticChecks)로 켜 두고, 시스템 정보는 보내지 않는다
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        userInitiated = false
        send(.found(version: appcastItem.displayVersionString))
        if installWhenFound {
            installWhenFound = false
            reply(.install)
        } else {
            installReply = reply
        }
    }

    /// 띠가 떠 있는데 또 확인을 시켰다 (Sparkle 이 새 확인 대신 이걸 부른다) — 어디를 누를지 알린다
    func showUpdateInFocus() {
        if let reminder = state.reminder { notice(reminder) }
    }

    // 변경 내용은 띠에 보이지 않는다 (CHANGELOG · 릴리스 페이지)
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if userInitiated { notice("최신 버전입니다 (\(AppUpdater.currentVersion))") }
        finishCheck()
        send(.notFound)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // 주기 확인의 실패(망 없음 등)는 조용히. 직접 확인했거나 띠가 있던 과정(받기·설치·다시 시도)의 실패는 이유를 알린다 — 띠엔 "업데이트 실패"만 남는다
        if userInitiated {
            notice("업데이트 확인 실패: \(error.localizedDescription)")
        } else if state.version != nil {
            notice("업데이트 실패: \(error.localizedDescription)")
        }
        finishCheck()
        send(.failed)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { send(.downloadStarted) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { send(.expected(expectedContentLength)) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { send(.received(length)) }
    func showDownloadDidStartExtractingUpdate() { send(.extracting) }
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // 사용자는 이미 [업데이트]를 눌렀다 — 다시 묻지 않고 설치·재시작. 다만 받는 사이 새 작업이 생겼으면 미루고 띠에 [다시 시작]
        if canRestartNow() {
            reply(.install)
        } else {
            restartReply = reply
            send(.readyHeld)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        send(.installing)
        guard !applicationTerminated else { return }
        // Sparkle 은 종료를 한 번 요청할 뿐이다 — 그 순간 파일 선택 창 같은 것이 떠 있어 앱이 안 꺼지면 설치가 멈춘다. 꺼질 때까지 다시 요청한다
        retryTermination = retryTerminatingApplication
        terminationRetries?.cancel()
        terminationRetries = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let retry = self?.retryTermination else { return }
                retry()
            }
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        finishCheck()
        installReply = nil
        restartReply = nil
        retryTermination = nil
        terminationRetries?.cancel()
        send(.dismissed)
    }

    private func finishCheck() {
        userInitiated = false
        installWhenFound = false
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
