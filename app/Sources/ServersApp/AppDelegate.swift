// 창 수명: 닫아도 숨기기만 해서 터미널 세션·터널이 살아 있게 한다. Dock 아이콘으로 다시 연다.

import AppKit
import SwiftUI

/// 창을 닫아도 터미널 세션·터널이 죽지 않도록 창을 숨기기만 한다. Dock 아이콘을 누르면 다시 보인다.
/// (터미널 surface 는 NSView 가 소유하므로 창이 실제로 닫히면 ssh 세션이 모두 끊긴다.)
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var menuBar: MenuBarController?
    private var notificationHandler: PowerNotificationHandler?
    /// SwiftUI 설정 창 열기 (SettingsOpenerHook 이 넣는다 — App 본문은 환경값을 못 읽는다)
    var openSettings: (() -> Void)?

    /// 창이 그려지기 전에 저장된 라이트·다크를 건다 (한 번 시스템 색으로 번쩍이지 않게).
    @MainActor func applicationWillFinishLaunching(_ notification: Notification) {
        AppearanceMode.stored.apply()
        ThinScroller.install()
    }

    /// 메뉴바 항목을 한 번 만든다 (창 onAppear 에서). 앱이 사는 동안 유지.
    @MainActor func installMenuBar(model: AppModel) {
        guard menuBar == nil else { return }
        menuBar = MenuBarController(model: model,
                                    openWindow: { [weak self] in self?.showMainWindow() },
                                    openSettings: { [weak self] in
                                        NSApp.activate(ignoringOtherApps: true)
                                        self?.openSettings?()
                                    })
    }

    /// 켜짐·꺼짐 알림(AppModel+Notify)의 표시·클릭을 받는다 (창 onAppear 에서). 앱이 사는 동안 유지.
    @MainActor func installNotificationHandler(model: AppModel) {
        guard notificationHandler == nil else { return }
        notificationHandler = PowerNotificationHandler(model: model) { [weak self] in self?.showMainWindow() }
    }

    /// 전체 화면을 푸는 중이라 다 풀리면 숨길 창
    private weak var hideAfterFullScreen: NSWindow?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 전체 화면 그대로 숨기면 빈 전체 화면 공간이 검게 남았다 — 먼저 풀고 숨긴다 (다시 열면 일반 창)
        if sender.styleMask.contains(.fullScreen) {
            hideAfterFullScreen = sender
            sender.toggleFullScreen(nil)
        } else {
            sender.orderOut(nil)
        }
        return false
    }

    func windowDidExitFullScreen(_ notification: Notification) { hideIfPending(notification) }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        if window === hideAfterFullScreen { hideAfterFullScreen = nil; window.orderOut(nil) }
    }

    private func hideIfPending(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === hideAfterFullScreen else { return }
        hideAfterFullScreen = nil
        window.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // 숨겨 둔 창(들)을 모두 되살린다. 창이 하나뿐이어도 같은 경로.
            let hidden = sender.windows.filter { $0.delegate === self && !$0.isVisible }
            guard !hidden.isEmpty else { return true }
            for w in hidden { w.makeKeyAndOrderFront(nil) }
            return false
        }
        return true
    }

    /// 메뉴바 [창 열기]: 앱을 앞으로 가져오고 본창(숨겨져 있으면 되살려서)을 키 윈도우로. 본창이 키가 되면 메뉴바 패널은 저절로 닫힌다.
    @MainActor func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.delegate === self { w.makeKeyAndOrderFront(nil) }
    }
}

/// 메뉴바 [Settings…] 가 설정 창을 열 수 있게 openSettings 동작을 AppDelegate 에 넘긴다.
struct SettingsOpenerHook: View {
    let delegate: AppDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear { delegate.openSettings = { openSettings() } }
    }
}

/// 호스팅 NSWindow 를 잡아 delegate 를 붙인다.
struct WindowHook: NSViewRepresentable {
    let delegate: AppDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { attach(nsView) }

    private func attach(_ view: NSView) {
        guard let window = view.window, window.delegate !== delegate else { return }
        window.delegate = delegate
        window.backgroundColor = Palette.contentNS   // 툴바(투명) 뒤로 비치는 창 바탕도 본문 색으로
        // 창을 처음 열면 AppKit 이 첫 입력칸(비밀번호)에 포커스를 준다 — 커서가 깜빡이지 않게 처음 한 번만 푼다 (클릭하면 평소대로 입력)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
        }
    }
}
