// 마우스 옆 버튼(뒤로 · 앞으로) · 쓸어 넘기기 · ⌘[ · ⌘] 를 브라우저 탭의 뒤로 · 앞으로에 잇는다 — 웹 뷰는 어느 것도 스스로 처리하지 않는다.
// 마우스 드라이버는 옆 버튼을 다른 신호로 바꿔 보내서 셋 다 받는다: 버튼 3 · 4번 / 쓸어 넘기기(Logi Options+ — 입력 감시로 확인) / ⌘[ · ⌘] (2026-11-25).
// 버튼은 누름에서 동작하고, 그 버튼의 뗌도 같이 삼킨다(페이지가 반쪽 클릭을 받지 않게). 판정은 ServersCore MouseNavigation.
// 보이는 탭이 브라우저가 아니면 흘린다 — 터미널 탭의 ⌘[ · ⌘] 는 터미널이 그대로 받는다.

import AppKit
import ServersCore

@MainActor
enum MouseShortcuts {
    private static var monitor: Any?

    /// browser: 본창에 지금 보이는 브라우저 탭 (없으면 nil)
    static func install(browser: @escaping () -> BrowserSession?) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp, .keyDown, .swipe]) { event in
            let direction: MouseNavigation.Direction?
            if event.type == .keyDown {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                direction = MouseNavigation.direction(keyCode: event.keyCode, command: modifiers.contains(.command), shift: modifiers.contains(.shift),
                                                      option: modifiers.contains(.option), control: modifiers.contains(.control))
            } else if event.type == .swipe {
                direction = MouseNavigation.direction(swipeDeltaX: Double(event.deltaX))
            } else {
                direction = MouseNavigation.direction(button: event.buttonNumber)
            }
            guard direction != nil else { return event }
            let session = browser()
            let action = MouseNavigation.action(direction, mainWindow: event.window?.delegate is AppDelegate,
                                                sheetOpen: event.window?.attachedSheet != nil, browserVisible: session != nil,
                                                canGoBack: session?.canGoBack ?? false, canGoForward: session?.canGoForward ?? false)
            guard let action else { return event }
            if event.type != .otherMouseUp {
                switch action {
                case .back: session?.goBack()
                case .forward: session?.goForward()
                case .swallow: break
                }
            }
            return nil
        }
    }
}
