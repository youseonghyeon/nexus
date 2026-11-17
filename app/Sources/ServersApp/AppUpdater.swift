// 앱 안 업데이트: Sparkle 이 확인·받기·서명 검증·교체·재시작을 맡고, 화면은 Sparkle 기본 창 대신 사이드바 띠(UpdateBanner)다.
// 이 클래스는 Sparkle 의 화면 요청(SPUUserDriver)을 AppUpdate 이벤트로 옮기기만 한다 — 상태 판정은 ServersCore AppUpdate.
// 피드 주소·공개 키는 Info.plist (SUFeedURL · SUPublicEDKey), 릴리스 서명은 `make dist`.

import AppKit
import ServersCore
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUserDriver {
    private var updater: SPUUpdater?
    private let apply: (AppUpdate.Event) -> Void
    /// 사용자가 직접 확인했을 때의 결과 문구 (토스트)
    private let notice: (String) -> Void
    /// "새 버전 발견"에 대한 답 — 띠의 [업데이트]를 누를 때까지 쥐고 있는다
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    /// 메뉴의 [업데이트 확인…] 으로 시작한 확인 — 결과(최신·실패)를 알린다. 주기 확인은 조용히.
    private var userInitiated = false
    /// 실패 띠의 [다시 시도] — 다시 확인해 발견되면 묻지 않고 바로 받는다
    private var installWhenFound = false

    init(apply: @escaping (AppUpdate.Event) -> Void, notice: @escaping (String) -> Void) {
        self.apply = apply
        self.notice = notice
    }

    /// 피드 주소가 없는 빌드는 확인하지 않는다. 시작하면 Sparkle 이 켤 때 한 번 · 그 뒤 주기(SUScheduledCheckInterval)로 확인한다.
    func start() {
        guard updater == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            NSLog("업데이트 확인을 시작하지 못했습니다: %@", error.localizedDescription)
        }
    }

    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    /// 메뉴의 [업데이트 확인…]
    func check() {
        guard let updater, updater.canCheckForUpdates else { return }
        userInitiated = true
        updater.checkForUpdates()
    }

    /// 띠의 [업데이트] · [다시 시도]
    func install() {
        if let reply = installReply {
            installReply = nil
            reply(.install)
        } else if let updater, updater.canCheckForUpdates {
            installWhenFound = true
            updater.checkForUpdates()
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 묻지 않는다 — 자동 확인은 Info.plist(SUEnableAutomaticChecks)로 켜 두고, 시스템 정보는 보내지 않는다
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        userInitiated = false
        apply(.found(version: appcastItem.displayVersionString))
        if installWhenFound {
            installWhenFound = false
            reply(.install)
        } else {
            installReply = reply
        }
    }

    // 변경 내용은 띠에 보이지 않는다 (CHANGELOG · 릴리스 페이지)
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if userInitiated { notice("최신 버전입니다 (\(AppUpdater.currentVersion))") }
        finishCheck()
        apply(.notFound)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // 주기 확인의 실패(망 없음 등)는 조용히 — 띠가 있던 과정의 실패만 띠에 남는다 (AppUpdate.failed)
        if userInitiated { notice("업데이트 확인 실패: \(error.localizedDescription)") }
        finishCheck()
        apply(.failed)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { apply(.downloadStarted) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { apply(.expected(expectedContentLength)) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { apply(.received(length)) }
    func showDownloadDidStartExtractingUpdate() { apply(.extracting) }
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // 사용자는 이미 [업데이트]를 눌렀다 — 다시 묻지 않고 설치·재시작
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        apply(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        finishCheck()
        installReply = nil
        apply(.dismissed)
    }

    private func finishCheck() {
        userInitiated = false
        installWhenFound = false
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
