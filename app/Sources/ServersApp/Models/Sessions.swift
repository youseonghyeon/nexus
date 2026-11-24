// 목록에 보이는 세션들: 터미널 탭 · 터널 · 파일 전송. AppModel 이 만들고 배열로 들고 있다.

import Foundation
import GhosttyTerminal
import ServersCore
import SwiftUI

/// 탭의 내용: 터미널(ssh·로컬 셸) 또는 앱 안 브라우저 (그 서버의 터널로만 통신).
enum TabContent {
    case terminal(TerminalViewState)
    case browser(BrowserSession)
}

/// 탭 하나 (이름은 역사적 이유로 TerminalTab). 서버당 여러 개 열 수 있다. 소유자(owner)는 서버 키 또는 AppModel.localKey.
@MainActor
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    let server: Server?
    let title: String
    let content: TabContent
    /// theme=on 그룹의 SSH 탭 — 터미널 색 "미적용"이어도 Rosé Pine (TerminalColorMode.palette)
    let themed: Bool
    /// 터미널 탭이면 그 표면 상태, 브라우저 탭이면 nil
    var terminal: TerminalViewState? { if case let .terminal(t) = content { return t } else { return nil } }
    var browser: BrowserSession? { if case let .browser(b) = content { return b } else { return nil } }
    @Published var isAlive = true
    /// 사용자가 붙인 탭 이름. 있으면 셸이 보내는 제목(OSC) 대신 쓴다. nil 이면 자동 제목.
    @Published var customTitle: String?
    /// 터미널 안 찾기 (⌘F — TerminalFind): 찾기 칸이 열려 있나 · 찾는 글자 · 칸으로 포커스를 옮기라는 신호 (값이 바뀔 때마다)
    @Published var finding = false
    @Published var findText = ""
    @Published var findFocusRequest = 0
    /// surface 가 닫힘을 요청했을 때 (프로세스 종료 후). AppModel 이 탭을 목록에서 뺀다.
    var onClosed: (@MainActor (TerminalTab) -> Void)?
    /// 터미널에 파일을 끌어 놓았을 때 (TerminalDropView). 받았으면 true. canDropFiles 가 false 면 끌기를 받지 않는다.
    var onDropFiles: (@MainActor (TerminalTab, [URL]) -> Bool)?
    var canDropFiles: (@MainActor (TerminalTab) -> Bool)?

    var owner: String { server?.key ?? AppModel.localKey }

    /// 브라우저 탭
    init(server: Server, browser: BrowserSession) {
        self.server = server
        self.title = "\(server.key) web"
        self.content = .browser(browser)
        self.themed = false
    }

    /// command 가 nil 이면 사용자의 기본 로그인 셸을 연다. envVars 는 그 프로세스에만 더해지는 환경변수 (SSH_ASKPASS 등).
    init(server: Server?, title: String, command: String?, theme: Bool, colorMode: TerminalColorMode, envVars: [String: String] = [:]) {
        self.server = server
        self.title = title
        self.themed = theme
        // 글꼴·여백 등은 terminalConfiguration, 색은 theme 으로 나눈다 — 색만 나중에 바꿀 수 있게 (setTheme, 설정의 터미널 색)
        var configuration = TerminalConfiguration.default
            .fontSize(13)
            .windowPaddingX(TerminalScreen.paddingX)
            .windowPaddingY(TerminalScreen.paddingY)
            .custom("shell-integration", "none")
            // 원격에는 xterm-ghostty terminfo 가 없다. 어느 서버에나 있는 값으로 vim·less·top 이 깨지지 않게 한다.
            .custom("term", "xterm-256color")
            // 드래그(두 번 클릭 단어 선택 포함)로 고르면 바로 클립보드로 — iTerm 처럼. ⌘C 는 그대로 된다.
            .custom("copy-on-select", "clipboard")
        // 앱 메뉴의 단축키와 겹치는 Ghostty 기본 키를 푼다 — 안 풀면 터미널이 가져가 ⌘T · ⌘, · ⌘Q 가 눌러도 아무 일도 없다 (TerminalKeys)
        for keybind in TerminalKeys.keybinds { configuration = configuration.custom("keybind", keybind) }
        let terminal = TerminalViewState(theme: Self.colorTheme(colorMode.palette(themed: theme)),
                                         terminalConfiguration: configuration)
        content = .terminal(terminal)
        // 끌어 놓기(Finder 파일·스크린샷 썸네일의 file promise)를 받는 하위 클래스 뷰 — 받은 파일은 onDropFiles 로
        terminal.makePlatformView = { [weak self] in
            let view = TerminalDropView(frame: .zero)
            view.canDrop = { [weak self] in self.map { $0.canDropFiles?($0) ?? false } ?? false }
            view.onDrop = { [weak self] urls in self.map { $0.onDropFiles?($0, urls) ?? false } ?? false }
            view.acceptsDrops = view.canDrop?() ?? false   // 만들 때 보이는 탭이면 바로 — 그 뒤는 TerminalPane.sync 가 맞춘다
            return view
        }
        // .exec: libghostty 가 PTY 를 열고 로그인 셸 대신 이 명령을 실행한다.
        // 정상 종료(exit)면 바로 닫힌다. 비정상 종료(접속 실패 등)는 Ghostty 가 오류 화면을 남기고 키 입력을 기다린다.
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: NSHomeDirectory(),
            envVars: envVars,
            command: command,
            waitAfterCommand: false
        )
        terminal.onClose = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAlive = false
                self.onClosed?(self)
            }
        }
    }
}

extension TerminalTab {
    /// 팔레트 → 터미널 색 설정 (라이트·다크 화면 모두 같은 색). nil 이면 비워 터미널 기본색
    static func colorTheme(_ palette: TerminalPalette?) -> TerminalTheme {
        guard let palette else { return TerminalTheme() }
        var colors = TerminalConfiguration()
            .background(palette.background)
            .foreground(palette.foreground)
            .cursorColor(palette.cursor)
        for (index, color) in palette.colors.enumerated() {
            colors = colors.palette(index, color: color)
        }
        return TerminalTheme(light: colors, dark: colors)
    }

    /// 설정의 터미널 색을 바꾸면 열린 탭에도 바로 (원격 프롬프트 색은 접속 때 정해져 그대로)
    func applyColorMode(_ mode: TerminalColorMode) {
        terminal?.setTheme(Self.colorTheme(mode.palette(themed: themed)))
    }
}

/// 앱이 붙잡고 있는 터널 하나. 목록 항목(표시등)으로 보이고 하나씩 끊는다.
@MainActor
final class TunnelSession: Identifiable, ObservableObject {
    let id = UUID()
    let spec: TunnelSpec
    let startedAt = Date()
    @Published var state: TunnelState = .connecting
    /// 앱이 끊을 때의 이유 ("내부망 끔" 등). nil 이면 사용자가 [끊기]를 누른 것.
    var stopReason: String?
    /// 앱 안 브라우저가 직접 연 SOCKS 터널 — 브라우저 탭이 다 닫히면 함께 내린다 (stopProxyTunnelIfUnused).
    /// 이 세션에만 있는 표시라 기록(recent.json)에는 남지 않는다. [Chrome] 이 같이 쓰기 시작하면 푼다 (openChromeProxy).
    var openedByBrowser = false
    let process = TunnelProcess()

    init(spec: TunnelSpec) {
        self.spec = spec
    }

    var server: Server { spec.server }
    var title: String { spec.sidebarTitle }
    var isActive: Bool {
        switch state {
        case .connecting, .open: return true
        case .idle, .closed: return false
        }
    }
    /// 같은 터널인가 (서버·종류·원격 대상. 로컬 포트는 무시, 계정은 보지 않는다 — 다른 계정으로 연 같은 터널도 같은 항목)
    func matches(_ record: RecentTunnel) -> Bool {
        RecentTunnel(serverKey: spec.server.key, kind: spec.kind, localPort: spec.localPort).id == record.id
    }
}

/// 파일 전송 하나 (scp). TRANSFERS 목록 항목으로 보이고 진행률을 갱신한다.
@MainActor
final class TransferSession: Identifiable, ObservableObject {
    let id = UUID()
    let spec: TransferSpec
    let startedAt = Date()
    @Published var state: TransferState = .running(nil)
    /// 출력 줄 — 마지막 maxLog 줄만 (화면은 "출력 (N줄)" 과 끝 40줄만 쓴다)
    @Published var log: [String] = []
    static let maxLog = 2000
    /// 여러 파일(폴더·다중 선택)의 전체 진행률. 전체 크기는 다운로드면 첫 진행률 뒤 원격에서 잰다.
    @Published var meter = TransferMeter()
    var sizeRequested = false
    let process = TransferProcess()

    init(spec: TransferSpec) { self.spec = spec }

    var server: Server { spec.server }
    var title: String { spec.title }
    var isActive: Bool { if case .running = state { return true } else { return false } }

    /// 막대 값 0...1. 전체 크기를 알면 전체 기준. 모르면 파일이 하나일 때만 그 파일 기준, 여러 개면 nil (움직이는 막대).
    var fraction: Double? {
        guard case let .running(progress) = state, let progress else { return nil }
        if let overall = meter.fraction { return overall }
        return meter.fileCount <= 1 ? Double(progress.percent) / 100 : nil
    }

    /// 진행 중 한 줄 (파일 이름 없이): "45% · 1.2 GB / 2.7 GB · 10MB/s · 12번째 파일".
    /// 전체 크기를 모르는 여러 파일이면 "12번째 파일 · 45% · 10MB/s".
    var progressText: String? {
        guard case let .running(progress) = state, let progress else { return nil }
        let many = meter.fileCount > 1
        if many, meter.fraction == nil {
            return "\(meter.fileCount)번째 파일 · \(progress.percent)% · \(progress.rate)"
        }
        var parts: [String] = []
        if let fraction { parts.append("\(Int(fraction * 100))%") }
        if let total = meter.totalBytes, meter.fraction != nil {
            parts.append("\(TransferMeter.format(meter.doneBytes)) / \(TransferMeter.format(total))")
        } else {
            parts.append(progress.transferred)
        }
        parts.append(progress.rate)
        parts.append(many ? "\(meter.fileCount)번째 파일" : progress.eta)   // scp 의 남은 시간은 파일 기준이라 여러 파일이면 뺀다
        return parts.joined(separator: " · ")
    }
}
