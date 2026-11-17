// 터미널 탭의 ⌘C / ⌘V 와 탭 이동 ⌘⇧[ / ⌘⇧], 전체화면 ⌘⇧Enter 를 입력기와 무관하게 처리한다.
// Ghostty 뷰는 키 이벤트의 문자로 단축키를 판정하는데 한글 입력기에서는 ⌘C 가 "ㅊ" 로 와서 복사로 안 잡히고, 그 뷰가 키를 먼저
// 삼켜 편집 메뉴에도 닿지 않는다. 그래서 이벤트가 창에 가기 전에 잡아 터미널에 직접 시킨다 — 글자 판정은 ShortcutKey
// (라틴 배열은 찍히는 글자, 한글 입력기는 키 위치).
// ⌘⇧[ / ⌘⇧] 는 Ghostty 의 기본 탭 이동 키라 터미널 뷰가 가져가 메뉴 단축키로는 안 된다 — 같은 자리에서 잡는다 (브라우저 탭·Dashboard 에서도).
// ⌘⇧Enter 도 Ghostty 기본 키(분할 확대)라 같은 이유로 여기서 잡아 창 전체화면을 켜고 끈다.
// ⌘P(명령 모음)도 여기서 — 한글 입력기에서는 "ㅔ" 로 와서 메뉴 단축키로는 안 잡힌다.
// ⌘V 는 파일 넣기를 먼저 묻는다 (pasteFiles — 클립보드 이미지·파일을 경로로, SSH 탭은 이미지·문서를 서버로 올려서). 안 받으면 Ghostty 기본 붙여 넣기.
// ⌘W 도 같다: 터미널 뷰가 먼저 가져가면 탭이 아니라 창이 닫힌다. ⌘W 는 모든 창에서 여기서만 처리한다 — 판정은 CloseCommand
// (본창: 보이는 탭 → 없으면 창 숨기기(전체 화면이면 그대로) · 시트·팝오버·모달 패널: 무시 · 설정 창: 그 창 닫기). 메뉴 [Close Tab] 의 ⌘W 까지 가지 않는다.
// ⌘1–⌘9(사이드바 번호의 서버 고르기)도 여기서 — Ghostty 기본 키(탭 이동)라 터미널 뷰가 가져간다. ⌘ 만 누르고 있으면 번호를 보인다
// (flagsChanged → QuickSelectState, 판정은 ServersCore QuickSelect). 숫자는 키 위치로 (한글 입력기·AZERTY 와 무관).

import AppKit
import GhosttyTerminal
import ServersCore

@MainActor
enum TerminalShortcuts {
    private static var monitor: Any?
    private static var flagsMonitor: Any?
    private static let keyLeftBracket: UInt16 = 33    // kVK_ANSI_LeftBracket
    private static let keyRightBracket: UInt16 = 30   // kVK_ANSI_RightBracket
    private static let keyReturn: UInt16 = 36         // kVK_Return
    private static let keyKeypadEnter: UInt16 = 76    // kVK_ANSI_KeypadEnter

    /// stepTab(forward): ⌘⇧] 면 true, ⌘⇧[ 면 false 로 부른다. toggleSnippets: ⌘P — 본창에서 열고, 열려 있으면(팝오버가 키 창) 닫는다.
    /// hasVisibleTab·closeTab: ⌘W — 본창에 보이는 탭이 있는가 · 그 탭(그 셸)만 닫기. pasteFiles: ⌘V — 처리했으면 true (AppModel.pasteIntoTerminal).
    /// selectNumber: ⌘1–⌘9 — 그 번호의 서버를 골랐으면 true (번호가 없는 자리면 흘린다).
    static func install(stepTab: @escaping (Bool) -> Void, toggleSnippets: @escaping () -> Void, snippetsOpen: @escaping () -> Bool,
                        hasVisibleTab: @escaping () -> Bool, closeTab: @escaping () -> Void, pasteFiles: @escaping (AppTerminalView) -> Bool,
                        selectNumber: @escaping (Int) -> Bool) {
        guard monitor == nil else { return }
        // 번호 보이기: 본창이 키 창일 때 ⌘ 만 누르고 있으면. 다른 앱으로 가면(⌘Tab) 뗌 이벤트가 오지 않으니 거기서 지운다.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let commandOnly = QuickSelect.commandOnly(command: modifiers.contains(.command), shift: modifiers.contains(.shift),
                                                      option: modifiers.contains(.option), control: modifiers.contains(.control))
            QuickSelectState.shared.modifiersChanged(commandOnly: commandOnly && NSApp.keyWindow?.delegate is AppDelegate)
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickSelectState.shared.reset() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let number = QuickSelect.number(keyCode: event.keyCode)
            if modifiers.contains(.command) { QuickSelectState.shared.keyDown(isNumber: number != nil) }   // ⌘C 등이면 이번 누름엔 번호를 안 보인다
            if let number, modifiers.intersection([.command, .shift, .option, .control]) == .command,
               let window = event.window, window.delegate is AppDelegate, selectNumber(number) {
                return nil
            }
            func key(_ letter: Character) -> Bool {
                // ⌘ 를 반영한 글자 — Dvorak-QWERTY⌘ 처럼 ⌘ 를 누르면 배열이 바뀌는 경우도 메뉴와 같게
                ShortcutKey.matches(letter, keyCode: event.keyCode, characters: event.characters(byApplyingModifiers: .command))
            }
            // 탭 이동·전체화면은 본창에서만 (시트·메뉴바 패널은 본창 delegate 가 아니다). Caps Lock 은 보지 않는다.
            if modifiers.intersection([.command, .shift, .option, .control]) == [.command, .shift], let window = event.window, window.delegate is AppDelegate {
                switch event.keyCode {
                case keyLeftBracket: stepTab(false); return nil
                case keyRightBracket: stepTab(true); return nil
                case keyReturn, keyKeypadEnter: window.toggleFullScreen(nil); return nil
                default: break
                }
            }
            if modifiers.intersection([.command, .shift, .option, .control]) == .command, key("w") {
                let window = event.window ?? NSApp.keyWindow
                switch CloseCommand.action(window: closeTarget(window), hasVisibleTab: hasVisibleTab()) {
                case .closeTab: closeTab()
                case .hideMain, .closeWindow: window?.performClose(nil)   // 본창은 AppDelegate 가 숨기기로 바꾼다
                case .ignore: break
                }
                return nil   // 흘리면 메뉴 [Close Tab ⌘W] 가 시트 뒤의 탭을 닫는다
            }
            if modifiers.intersection([.command, .shift, .option, .control]) == .command, key("p"),
               let window = event.window, window.delegate is AppDelegate || snippetsOpen() {
                toggleSnippets()
                return nil
            }
            guard modifiers.intersection([.command, .shift, .option, .control]) == .command, let view = NSApp.keyWindow?.firstResponder as? AppTerminalView else { return event }
            if key("c") { return view.copySelectedTextToPasteboard() ? nil : event }   // 선택이 없으면 원래대로 (Ctrl-C 등과 무관)
            if key("v") {
                if pasteFiles(view) { return nil }
                return view.performBindingAction("paste_from_clipboard") ? nil : event
            }
            return event
        }
    }

    /// ⌘W 를 받은 창의 종류 (CloseCommand)
    private static func closeTarget(_ window: NSWindow?) -> CloseCommand.Window {
        guard let window else { return .none }
        if window.delegate is AppDelegate { return window.styleMask.contains(.fullScreen) ? .mainFullScreen : .main }
        if window.sheetParent != nil { return .sheet }
        if window === NSApp.modalWindow { return .other }   // runModal 패널(열기·저장) — 창만 닫으면 모달 세션이 남는다
        return window.styleMask.contains(.closable) ? .closable : .other
    }
}
