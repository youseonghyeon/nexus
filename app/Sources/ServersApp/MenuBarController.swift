// 메뉴바 상태 항목 (AppKit). 아이콘을 누르면 메뉴 대신 패널이 뜬다 — 본창과 같은 면·선·상태 점으로 그린 작은 화면 (MenuBarPanelView).
// 이 Mac 에서 일어나는 것만: 망 스위치(Wi-Fi·Tailscale·Intranet) · 시스템 VPN 켜기/끄기 · 서버 상태(누르면 본창의 그 서버 화면) ·
// 터널 끊기/다시 연결. 서버 전원(Wake/Shutdown)·SSH·전송·터널 열기는 원격 조작이거나 입력창이 필요해 창에서 한다 ([Open Nexus]).
// 아이콘은 Intranet 이 켜져 있으면 채운 모양. 블루투스는 제어 센터와 겹쳐 뺐다 (2026-11-14) — 본창 Bluetooth 화면에서 한다.
//
// 패널 내용(SwiftUI)은 열려 있는 동안만 있다 — 닫으면 뷰를 떼어 모델 관찰도 끝난다.
// 자리는 ServersCore `MenuBarPanelPlacement`, 스위치 판정은 `MenuBarSwitch`.
// (2026-11-14 까지는 NSMenu 였다. SwiftUI MenuBarExtra 는 .window 가 각지고 .menu 는 갱신마다 서브메뉴가 닫혀 쓰지 않는다.)

import AppKit
import Combine
import ServersCore
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private unowned let model: AppModel
    private let openWindow: () -> Void
    private let openSettings: () -> Void

    private let panel = MenuBarPanel()
    /// 내용이 원하는 높이 (열려 있는 동안 VPN·터널이 생기고 사라지면 바뀐다)
    private var contentHeight: CGFloat = 0
    /// 패널 밖을 누르면 닫는다 — 다른 앱(global)과 이 앱의 다른 창(local)
    private var monitors: [Any] = []
    private var spaceWatch: NSObjectProtocol?

    init(model: AppModel, openWindow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown])   // 메뉴처럼 누르는 순간 뜬다
        }
        panel.onCancel = { [weak self] in self?.close() }
        panel.onShortcut = { [weak self] shortcut in
            switch shortcut {
            case .settings: self?.act { $0.openSettings() }
            case .quit: NSApp.terminate(nil)
            }
        }
        watchIcon()
    }

    /// 아이콘은 패널이 닫혀 있어도 Intranet 상태를 따라간다 (상태 확인이 끝날 때마다 한 번 — 같으면 그대로).
    private func watchIcon() {
        let image = withObservationTracking {
            model.status.lan == .up ? MenuBarIcon.intranetOnImage : MenuBarIcon.image
        } onChange: { [weak self] in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { self?.watchIcon() }
            }
        }
        if statusItem.button?.image !== image { statusItem.button?.image = image }
    }

    // MARK: 열기·닫기

    @objc private func togglePanel() {
        if panel.isVisible { close() } else { open() }
    }

    private func open() {
        let actions = MenuPanelActions(
            toggleNetwork: { [weak self] in self?.toggleNetwork($0) },
            toggleVPN: { [weak self] id in
                guard let self, let vpn = model.vpns?.first(where: { $0.id == id }) else { return }
                model.toggleVPN(vpn)
            },
            openServer: { [weak self] key in
                self?.act { controller in
                    // 본창을 열어 그 서버 화면으로 (접속·전원 같은 원격 동작은 하지 않는다)
                    guard let server = controller.model.config?.server(key) else { return }
                    controller.model.select(server)
                    controller.openWindow()
                }
            },
            toggleTunnel: { [weak self] id in
                guard let self, let tunnel = model.tunnels.first(where: { $0.id == id }) else { return }
                if tunnel.isActive { model.stopTunnel(id) } else { model.reconnectTunnel(id) }
            },
            openWindow: { [weak self] in self?.act { $0.openWindow() } },
            openSettings: { [weak self] in self?.act { $0.openSettings() } },
            quit: { NSApp.terminate(nil) })

        // 처음 크기는 미리 재서 잡는다 (뜬 뒤에 늘어나 보이지 않게). 그 뒤 바뀌는 높이는 내용이 알려 준다.
        let measuring = NSHostingController(rootView: MenuBarPanelView(content: model.menuPanelContent, actions: actions))
        contentHeight = measuring.sizeThatFits(in: CGSize(width: MenuBarPanelView.width, height: 10_000)).height

        let root = MenuBarPanelRoot(model: model, wifi: model.wifi, actions: actions) { [weak self] height in
            // 그리는 도중에 창 크기를 바꾸지 않게 다음 차례에
            DispatchQueue.main.async { self?.contentHeightChanged(height) }
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []   // 창 크기는 place() 가 정한다
        panel.contentView = hosting
        place()
        panel.makeKeyAndOrderFront(nil)
        setHighlighted(true)

        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: downs) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            NSEvent.addLocalMonitorForEvents(matching: downs) { [weak self] event in
                MainActor.assumeIsolated {
                    // 아이콘을 누른 것은 togglePanel 이 닫는다 (여기서 닫으면 곧바로 다시 열린다)
                    guard let self, event.window !== self.panel, event.window !== self.statusItem.button?.window else { return }
                    self.close()
                }
                return event
            },
        ].compactMap { $0 }
        spaceWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
    }

    private func close() {
        guard panel.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let spaceWatch { NSWorkspace.shared.notificationCenter.removeObserver(spaceWatch) }
        spaceWatch = nil
        panel.orderOut(nil)
        panel.contentView = nil   // 닫혀 있는 동안은 모델을 관찰하지 않는다
        setHighlighted(false)
    }

    /// 패널을 닫고 나서 실행 (창을 열거나 인증·확인 창이 뜨는 동작)
    private func act(_ run: @escaping @MainActor (MenuBarController) -> Void) {
        close()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            run(self)
        }
    }

    private func place() {
        guard let button = statusItem.button, let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = MenuBarPanelPlacement.frame(anchor: anchor,
                                                content: CGSize(width: MenuBarPanelView.width, height: contentHeight),
                                                visible: screen.visibleFrame)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()   // 그림자는 둥근 내용 모양을 따라 진다 (크기가 바뀌면 다시)
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard panel.isVisible, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        place()
    }

    /// 열려 있는 동안 아이콘을 눌린 모양으로. 누르고 있던 마우스를 떼면 버튼이 제 강조를 풀어서 한 번 더 건다.
    private func setHighlighted(_ on: Bool) {
        statusItem.button?.highlight(on)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusItem.button?.highlight(panel.isVisible)
        }
    }

    // MARK: 동작

    /// 스위치를 누름. 인증·본창 확인이 따르는 동작은 패널을 닫은 뒤 실행하고, 나머지는 열어 둔 채 값이 바뀌는 걸 보여 준다.
    private func toggleNetwork(_ id: String) {
        guard let row = model.menuBarSwitches.first(where: { $0.kind.panelID == id }), row.isEnabled else { return }
        let run: @MainActor (MenuBarController) -> Void = { controller in
            if row.confirmsInWindow { controller.openWindow() }   // 끄기 확인 창은 본창에 뜬다
            switch row.kind {
            case .wifi: controller.model.toggleWiFi()
            case .tailscale: controller.model.toggleTailscale()
            case .lan: controller.model.toggleLan()
            }
        }
        if row.closesMenuOnToggle { act(run) } else { run(self) }
    }
}

// MARK: 패널 창

/// 테두리 없는 패널. 앱을 앞으로 가져오지 않고(nonactivating) 키 입력만 받는다 — Esc 로 닫고 ⌘, · ⌘Q 를 받는다.
private final class MenuBarPanel: NSPanel {
    enum Shortcut { case settings, quit }
    var onCancel: (() -> Void)?
    var onShortcut: ((Shortcut) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear   // 둥근 면은 내용이 그린다 (menuPanelChrome)
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// 앱이 앞에 있지 않으면 주 메뉴의 단축키가 듣지 않아 여기서 받는다. 글자 대신 키 자리로 본다 (한글 입력 중에도).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 43: onShortcut?(.settings); return true   // ,
        case 12: onShortcut?(.quit); return true       // Q
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// 패널 내용: 모델을 읽어 값으로 바꿔 그린다. AppModel(@Observable)은 읽은 값이 바뀌면, Wi-Fi 모니터(ObservableObject)는 발행하면 다시 그린다.
private struct MenuBarPanelRoot: View {
    let model: AppModel
    @ObservedObject var wifi: WiFiMonitor
    let actions: MenuPanelActions
    let onHeight: (CGFloat) -> Void

    var body: some View {
        // 화면보다 길 때만 스크롤된다 (보통은 내용 높이 그대로)
        ScrollView {
            MenuBarPanelView(content: model.menuPanelContent, actions: actions)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .menuPanelChrome()
    }
}

private extension MenuBarSwitch.Kind {
    var panelID: String {
        switch self {
        case .wifi: return "wifi"
        case .tailscale: return "tailscale"
        case .lan: return "lan"
        }
    }
}

extension AppModel {
    /// 패널의 망 스위치 (설정에 있는 망만). 순서는 사이드바 Network 와 같다.
    var menuBarSwitches: [MenuBarSwitch] {
        let busy = busyAction != nil
        var rows = [MenuBarSwitch.wifi(powerOn: wifi.info?.powerOn, associated: wifi.info?.associated ?? false)]
        guard let config else { return rows }
        if config.showsTailscale(status.tailscale, checked: status.tailscaleChecked) {
            rows.append(.tailscale(status.tailscale, busy: busy, changing: busyAction?.kind == .tailscale))
        }
        if config.lan != nil, let row = MenuBarSwitch.lan(status.lan, busy: busy, changing: busyAction?.kind == .lan) {
            rows.append(row)
        }
        return rows
    }

    /// 패널에 그릴 값 (읽기만)
    var menuPanelContent: MenuPanelContent {
        var content = MenuPanelContent()
        content.networks = menuBarSwitches.map { row in
            let title: String, tone: StatusTone
            switch row.kind {
            case .wifi: title = "Wi-Fi"; tone = wifiTone(wifi.info)
            case .tailscale: title = networkName(.tailscale); tone = tailscaleTone
            case .lan: title = networkName(.lan); tone = lanTone
            }
            return .init(id: row.kind.panelID, title: title, subtitle: row.subtitle, tone: tone, isOn: row.isOn, isEnabled: row.isEnabled)
        }
        content.vpns = (vpns ?? []).map { vpn in
            .init(id: vpn.id, title: vpn.name, subtitle: vpn.kind,
                  tone: vpn.state == .connected ? .good : (vpn.isOn ? .warn : .muted),
                  isOn: vpn.isOn, isEnabled: vpn.canToggle && !vpnBusy.contains(vpn.id))
        }
        if let config {
            content.groups = config.groups.map { group in
                .init(name: group, servers: config.servers(in: group).map { .init(key: $0.key, tone: remoteTone($0)) })
            }.filter { !$0.servers.isEmpty }
        }
        content.tunnels = sortedTunnels.map { tunnel in
            .init(id: tunnel.id, title: tunnel.title, mapping: tunnel.spec.portMapping, tone: tunnel.tone,
                  isActive: tunnel.isActive, canReconnect: isReachable(tunnel.server))
        }
        return content
    }
}
