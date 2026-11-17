// servers-askpass — ssh(SSH_ASKPASS)·sudo(SUDO_ASKPASS)가 터미널 없이 비밀번호·호스트 키 확인을 물을 때 부르는 헬퍼.
// $1 = 프롬프트 문구, SERVERS_ASKPASS_TITLE = 창 제목, SERVERS_ASKPASS_ICON = network 면 시스템 네트워크 아이콘(기본은 앱 아이콘),
// SERVERS_ASKPASS_PASSWORD = 세션 비밀번호(있으면 첫 비밀번호 물음에 창 없이 대입, 틀려서 다시 물으면 창. 키 파일 암호 물음엔 대입하지 않는다).
// macOS 표준 경고창(NSAlert)에 아이콘·가림 입력칸으로 받아
// 표준출력으로 돌려준다. 취소하면 1 로 끝나고, 부모가 ssh 면 부모도 끝낸다 (AskPassHelper 참고).
// 번들에서는 Contents/MacOS/servers-askpass, 개발 중에는 .build/debug/servers-askpass.

import AppKit
import ServersCore

let environment = ProcessInfo.processInfo.environment
let prompt = CommandLine.arguments.dropFirst().first ?? "Password:"
let title = environment["SERVERS_ASKPASS_TITLE"] ?? "Nexus"
let kind = AskPassHelper.kind(of: prompt)
/// 세션 비밀번호가 거부돼 다시 묻는 경우 (창에 표시)
var sessionPasswordRejected = false

func cancel() -> Never {
    if AskPassHelper.parentIsSSH(pid: getppid()) { kill(getppid(), SIGTERM) }
    exit(1)
}

/// 아이콘. network: 시스템의 네트워크 아이콘(파란 지구본). 그 외: 앱 아이콘 — 번들(../Resources/AppIcon.icns) 또는
/// 소스 트리(.build/<config>/ → Resources/icon/AppIcon.icns)
func icon() -> NSImage? {
    if environment["SERVERS_ASKPASS_ICON"] == "network" {
        return NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericNetworkIcon.icns")
            ?? NSImage(named: NSImage.networkName)
    }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let dir = exe.deletingLastPathComponent()
    for candidate in [dir.appendingPathComponent("../Resources/AppIcon.icns"),
                      dir.appendingPathComponent("../../Resources/icon/AppIcon.icns")] {
        if let image = NSImage(contentsOf: candidate.standardizedFileURL) { return image }
    }
    return nil
}

/// 비밀번호 칸: 포커스되면 입력기를 로마자로 강제한다 (한글 상태에서 아무것도 안 쳐지는 것 방지). 창을 닫으면 원래 입력기로 돌아간다.
final class RomanSecureTextField: NSSecureTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        let restrict: () -> Void = { [weak self] in self?.currentEditor()?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier] }
        restrict()
        DispatchQueue.main.async { restrict() }   // 필드 에디터가 한 박자 늦게 붙는 경우
        return ok
    }
}

/// 다이얼로그를 띄우고 답을 돌려준다. nil 은 취소.
@MainActor func ask() -> String? {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = (sessionPasswordRejected ? "Saved password was rejected.\n" : "") + prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if let icon = icon() { alert.icon = icon }
    var field: NSSecureTextField?
    switch kind {
    case .yesNo:
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
    case .secret:
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        // 260pt 가 NSAlert 창의 최소 폭. 입력칸이 200 을 넘으면 창이 그만큼 넓어진다.
        let input = RomanSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "Password"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        field = input
    }
    alert.buttons[1].keyEquivalent = "\u{1b}"   // esc = Cancel/No ("Cancel" 은 자동이지만 "No" 는 아니다)
    alert.window.level = .modalPanel
    app.activate(ignoringOtherApps: true)
    // 백그라운드 프로세스의 활성화는 macOS 14+ 에서 거부될 수 있다. 창이 키가 안 됐으면 한 번 더 앞으로 끌어온다 (입력칸 포커스).
    // 포커스는 입력칸에만: 예/아니오 창에서 본문 텍스트가 첫 응답자가 되면 전체 선택돼 보이므로 창으로 돌린다.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        if !alert.window.isKeyWindow { app.activate(ignoringOtherApps: true); alert.window.makeKey() }
        alert.window.makeFirstResponder(field)
    }
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    switch kind {
    case .yesNo: return "yes"
    case .secret: return field?.stringValue ?? ""
    }
}

if AskPassHelper.usesSessionPassword(for: prompt), let session = environment["SERVERS_ASKPASS_PASSWORD"], !session.isEmpty {
    if AskPassHelper.claimFirstUse(marker: AskPassHelper.markerURL(parent: getppid())) {
        print(session)
        exit(0)
    }
    sessionPasswordRejected = true
}

let answer: String?
#if DEBUG
// 테스트 훅 (디버그 빌드만): 창을 띄우지 않고 정해진 답을 낸다. "cancel" 이면 취소.
if let canned = environment["SERVERS_ASKPASS_TEST_RESPONSE"] {
    answer = canned == "cancel" ? nil : canned
} else {
    answer = ask()
}
#else
answer = ask()
#endif

guard let answer else { cancel() }
print(AskPassHelper.reply(kind, answer: answer))
exit(0)
