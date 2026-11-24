// 이 Mac 에서 root 로 돌리는 관리자 스크립트: 인증 경로(Touch ID 시트 → 승인 창)·실행·결과 갈래.
// 서비스 켜기·만들기(NetworkServices) · 터널 주소(HostAlias) · ARP · Wi-Fi 상세가 privilegedScript 로 본문을 감싼다.

import Foundation

/// 내부망(macOS 네트워크 서비스) 제어 스크립트. lib/lan.zsh 를 통째로 불러 같은 함수를 쓴다.
/// root 권한이 필요하다. 인증 경로는 둘:
/// 1) `sudo -v`(askpass 없이) — pam_tid(Touch ID) 시트. 덮개가 열려 있으면 지문 또는 시트의 "암호 사용…". 성공하면 같은 셸에서
///    캐시된 자격으로 `sudo -n` 실행한다 (sudo 의 자격 캐시는 tty 가 없으면 부모 pid 기준이라 인증과 실행이 한 프로세스에 있어야 한다).
///    sudo 를 askpass 모드(-A)로 부르면 안 된다: macOS 27 의 pam_tid 는 "sudo askpass mode, not showing UI" 로 Touch ID 를 건너뛴다.
/// 2) 시트를 취소했거나 못 띄우면(클램셸: pam_tid 가 "Touch ID is not available in closed clamshell mode" 로 UI 없이 실패)
///    macOS 관리자 승인 창(`do shell script … with administrator privileges`)으로 같은 본문을 root 로 실행한다.
///    이 창은 Apple 클라이언트에만 Touch ID 를 주므로 우리 앱에선 항상 암호 입력이다 — 그래서 1) 을 먼저 시도한다.
/// 취소하면 authFailedExitCode 로 끝나며 아무 것도 바꾸지 않는다.
public enum LanCommands {
    public static let authFailedExitCode: Int32 = 77
    /// 관리자 스크립트 시간 한도 — Touch ID 시트 → 승인 창 암호 입력까지 기다리는 시간 포함
    public static let privilegedTimeout: TimeInterval = 180

    /// 관리자 스크립트(privilegedScript 로 만든 것) 실행. 결과는 PrivilegedOutcome 으로 가른다.
    public static func runPrivileged(_ script: String, runner: any CommandRunner) async -> CommandResult {
        await runner.run("/bin/zsh", ["-c", script], stdin: nil, environment: [:], timeout: privilegedTimeout)
    }

    /// Intranet 지정: 그 서비스를 서비스 순서 맨 뒤로 (켜도 기본 경로를 가로채지 않게). 이미 맨 뒤면 앱이 부르지 않는다.
    public static func moveLastScript(_ service: String, libDir: String) -> String {
        privilegedScript(body: "source \(shellQuote(libDir + "/lan.zsh")) || exit 1\n_lan_move_last \(shellQuote(service))",
                         prompt: "\(service) 서비스 순서를 맨 뒤로")
    }

    /// body 를 root 로 실행하는 zsh 스크립트 (인증 경로는 위 주석).
    static func privilegedScript(body: String, prompt: String) -> String {
        // root 로 직접 돌 때는 lan.zsh 의 sudo 접두사를 그대로 통과시킨다.
        let asRoot = "/bin/zsh -c " + shellQuote("sudo() { \"$@\"; }\n" + body)
        // sudo -n true: 자격이 실제로 남았는지 — sudoers 의 timestamp_timeout=0(회사 보안 정책)이면 -v 가 돼도 -n 이 실패해 승인 창으로 간다
        return """
        if env -u SUDO_ASKPASS sudo -v 2>/dev/null && sudo -n true 2>/dev/null; then
            sudo() { command sudo -n "$@"; }
            \(body)
        else
            out=$(osascript -e 'on run argv' -e 'do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges' -e 'end run' \(shellQuote(asRoot)) \(shellQuote(prompt)) 2>&1)
            code=$?
            [[ $code -ne 0 && $out == *'(-128)'* ]] && exit \(authFailedExitCode)
            print -r -- "$out"
            exit $code
        fi
        """
    }
}

/// 관리자 스크립트 결과의 갈래. 취소면 아무 것도 바꾸지 않았다. 시간 초과는 대개 인증 창 대기지만 본문이 멈춘 경우도 있다.
public enum PrivilegedOutcome: Sendable, Equatable {
    case ok, authCancelled, timedOut, failed

    public init(_ result: CommandResult) {
        switch result.exitCode {
        case 0: self = .ok
        case LanCommands.authFailedExitCode: self = .authCancelled
        case CommandResult.timedOutExitCode: self = .timedOut
        default: self = .failed
        }
    }

    /// 취소·시간 초과일 때의 앞 문장 ("… · <무엇을 하지 않았는지>" 로 잇는다). 작업 자체의 실패 문구는 부르는 쪽이 만든다.
    public var authProblem: String? {
        switch self {
        case .authCancelled: return "인증을 취소했거나 실패했습니다"
        case .timedOut: return "인증·실행이 \(Int(LanCommands.privilegedTimeout) / 60)분 안에 끝나지 않았습니다"
        case .ok, .failed: return nil
        }
    }
}

extension LanCommands {
    /// 관리자 스크립트가 실패했을 때 문구에 붙일 꼬리: 출력(표준 출력 + 오류)의 마지막 두 줄을 " · " 로 (빈 줄은 뺀다)
    public static func failureTail(_ result: CommandResult) -> String {
        RemoteCommands.cleanOutput(result.stdout + result.stderr, type: .linux).filter { !$0.isEmpty }.suffix(2).joined(separator: " · ")
    }
}
