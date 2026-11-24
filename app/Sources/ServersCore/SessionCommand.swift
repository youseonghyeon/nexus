// 터미널 탭에서 실행할 명령 조립. 원격 셸에는 아무것도 주입하지 않는다 — 그룹 theme=on 의 프롬프트·vim 주입은 2026-11-24 에 뺐다 (색은 서버별 테마로 — ServerTerminalTheme).
// 실제 실행은 GhosttyTerminal 의 .exec 백엔드(PTY)가 맡고, 여기서는 문자열만 만든다.

import Foundation

/// 터미널 색 한 벌: 바탕·글자·커서·16색. 쓰는 곳은 서버별 테마(ServerTerminalTheme) — 예전 Rosé Pine 두 벌(그룹 테마 · 설정의 터미널 색)은 2026-11-24 에 뺐다.
public struct TerminalPalette: Sendable, Equatable {
    public let background: String
    public let foreground: String
    public let cursor: String
    public let colors: [String]

    public init(background: String, foreground: String, cursor: String, colors: [String]) {
        self.background = background; self.foreground = foreground; self.cursor = cursor; self.colors = colors
    }
}

/// POSIX 단일 인용. zsh 의 %q 와 달리 어떤 셸에서도 같은 결과다.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// 터미널 없이 비밀번호를 팝업으로 받는 ssh 설정. ssh 는 SSH_ASKPASS 프로그램을 불러 그 출력으로 비밀번호를 받는다.
public enum AskPass {
    /// ssh 에 넘길 환경변수. REQUIRE=force 로 TTY 유무와 관계없이 헬퍼를 쓴다.
    /// password 는 세션 비밀번호(앱 메모리): 헬퍼가 첫 물음에 창 없이 대입한다 (AskPassHelper 참고).
    public static func environment(helper: String, title: String, password: String? = nil) -> [String: String] {
        var env = ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", "SERVERS_ASKPASS_TITLE": title]
        if let password, !password.isEmpty { env["SERVERS_ASKPASS_PASSWORD"] = password }
        return env
    }
    /// 세션 비밀번호로 한 번만 시도 (틀려도 창을 띄우지 않는다 — 자동 조회용)
    public static let singleAttempt: [String] = ["-o", "NumberOfPasswordPrompts=1"]
    /// 오답 재시도는 두 번까지. 무한히 팝업이 뜨지 않게 한다.
    public static let options: [String] = ["-o", "NumberOfPasswordPrompts=2"]
}

public enum SessionCommand {
    /// 터미널 탭용 래퍼. libghostty 는 종료 코드가 아니라 실행 시간(250ms)으로 정상/비정상을 가르므로,
    /// ssh 자체가 실패(255: 접속 실패·비밀번호 오류·끊김)로 끝나면 오류를 남기고 키 입력을 기다린 뒤 0 으로 끝낸다.
    /// 원격 셸의 마지막 명령 상태(예: grep 불일치 뒤 exit → 1)는 정상 로그아웃이므로 그대로 닫힌다.
    public static func holdOnFailure(_ command: String) -> String {
        let script = command + #"; rc=$?; if [ "$rc" -eq 255 ]; then printf '\n[ssh 연결 실패 (255)] 아무 키나 누르면 탭이 닫힙니다.'; read -r -n 1; exit 0; fi; exit "$rc""#
        return "/bin/bash -c " + shellQuote(script)
    }

    /// 서버 SSH 탭 명령. Windows 는 PowerShell, 그 외는 일반 로그인 셸.
    /// bindInterface: 내부망 서버면 그 서비스의 장치 (ConnectPolicy.bindOptions).
    public static func ssh(to server: Server, config: ServerConfig, home: String = NSHomeDirectory(), bindInterface: String? = nil) -> String {
        holdOnFailure(sshCommandLine(to: server, config: config, home: home, bindInterface: bindInterface))
    }

    /// 래퍼 없이 ssh 명령줄만
    public static func sshCommandLine(to server: Server, config: ServerConfig, home: String = NSHomeDirectory(), bindInterface: String? = nil) -> String {
        var args = ["ssh"] + ConnectPolicy.sharedArguments(port: server.port, bindInterface: bindInterface, home: home, identity: server.identityFile)
        switch server.type {
        case .windows:
            args += ["-t", server.target, "powershell.exe", "-NoLogo"]
        case .linux, .openwrt:
            args += [server.target]   // 일반 로그인 셸 (리눅스 bash · OpenWrt ash)
        }
        return args.map(shellQuote).joined(separator: " ")
    }

    /// ssh 는 LocalCommand 를 퍼센트 토큰(%h, %p …)으로 확장하므로 배너의 % 는 %% 로 피한다.
    /// 모르는 토큰은 접속 전에 fatal 이라 터널이 열리기도 전에 죽는다.
    public static func localCommandBanner(_ banner: String) -> String {
        "LocalCommand=printf '%%s\\n' " + shellQuote(banner.replacingOccurrences(of: "%", with: "%%"))
    }

    /// 터널 공통 ssh 인자. 연결 공유를 쓰지 않는 전용 연결(공유 연결을 거치면 ssh -N 이 즉시 끝난다).
    /// ExitOnForwardFailure: 로컬 포트가 이미 쓰이는 등 포워딩 실패면 조용히 붙어 있지 말고 끝낸다.
    /// ServerAlive: 끊긴 연결을 오래 "열림" 으로 두지 않는다. 5초 × 3회 = 15초 안에 감지 (15초 × 3회는 내부망을 끈 뒤 1분 가까이 "연결됨" 으로 남았다).
    /// 실행 파일(ssh)은 포함하지 않는다. 프로세스 인자로 그대로 쓴다.
    private static func tunnelBase(_ server: Server, banner: String, bindInterface: String?) -> [String] {
        ConnectPolicy.noControlOptions + ConnectPolicy.sshOptions + AskPass.options + ConnectPolicy.bindOptions(bindInterface)
            + ConnectPolicy.identityOptions(server.identityFile)
            + ["-p", "\(server.port)", "-N", "-o", "ExitOnForwardFailure=yes",
               "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
               "-o", "PermitLocalCommand=yes", "-o", localCommandBanner(banner)]
    }

    /// ssh -L 의 호스트에 IPv6 주소가 오면 대괄호로 감싸야 한다
    static func forwardHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// bindAddress 는 로컬 리스너 쪽(127.0.0.x — 어느 앱이나 붙는다), bindInterface 는 서버로 나가는 바깥쪽 연결(내부망 장치)이다.
    public static func tunnelArguments(to server: Server, remotePort: Int, remoteHost: String = "127.0.0.1", localPort: Int, bindAddress: String = "127.0.0.1", banner: String, bindInterface: String? = nil) -> [String] {
        tunnelBase(server, banner: banner, bindInterface: bindInterface) + ["-L", "\(bindAddress):\(localPort):\(forwardHost(remoteHost)):\(remotePort)", server.target]
    }

    public static func dbTunnelArguments(via server: Server, host: String, port: Int, localPort: Int, bindAddress: String = "127.0.0.1", banner: String, bindInterface: String? = nil) -> [String] {
        tunnelBase(server, banner: banner, bindInterface: bindInterface) + ["-L", "\(bindAddress):\(localPort):\(forwardHost(host)):\(port)", server.target]
    }

    /// SOCKS5 프록시 (ssh -D): 로컬 포트로 들어온 연결을 server 가 대신 나간다. Chrome 프록시 모드가 쓴다.
    public static func socksArguments(via server: Server, localPort: Int, bindAddress: String = "127.0.0.1", banner: String, bindInterface: String? = nil) -> [String] {
        tunnelBase(server, banner: banner, bindInterface: bindInterface) + ["-D", "\(bindAddress):\(localPort)", server.target]
    }

    public static func dbBanner(server: Server, host: String, port: Int, localPort: Int, name: String?, localHost: String = "localhost") -> String {
        let db = name ?? "<db>"
        return """
        ✔ DB 터널 열림 — \(localHost):\(localPort) → \(server.key) → \(host):\(port)   (종료: Ctrl-C)

          JDBC   jdbc:postgresql://\(localHost):\(localPort)/\(db)
          psql   psql "postgresql://<user>:<password>@\(localHost):\(localPort)/\(db)"
          Host   \(localHost)    Port   \(localPort)    Database   \(db)
        """
    }
}
