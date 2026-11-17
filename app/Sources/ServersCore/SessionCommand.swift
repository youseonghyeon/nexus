// 터미널 탭에서 실행할 명령 조립. theme=on 그룹이면 원격 bash 에 이 세션용 프롬프트·vim 설정을 주입한다.
// 실제 실행은 GhosttyTerminal 의 .exec 백엔드(PTY)가 맡고, 여기서는 문자열만 만든다.

import Foundation

/// 터미널 색 한 벌: 바탕·글자·커서·16색 + 원격 프롬프트(태그 색·❯)·.env vim 하이라이트 색.
/// 프롬프트·vim 색은 접속할 때 원격에 보내는 글자라, 열린 뒤 바탕을 바꿔도 따라가지 않는다 — 그래서 바탕마다 한 벌씩.
public struct TerminalPalette: Sendable, Equatable {
    public let background: String
    public let foreground: String
    public let cursor: String
    public let colors: [String]
    /// "r;g;b" — 프롬프트 태그 색 (운영 · 스테이징 · 그 밖) · ❯
    let prodColor: String
    let stagingColor: String
    let devColor: String
    let arrowColor: String
    /// .env vim 하이라이트 (주석 · 키 · 값)
    let vimComment: String
    let vimKey: String
    let vimValue: String

    /// Rosé Pine 바탕의 차분한 변형 — theme=on 그룹의 원래 색
    public static let rosePine = TerminalPalette(
        background: "#191724", foreground: "#ebdbb2", cursor: "#c4a7e7",
        colors: ["#1f1d2e", "#bd788e", "#7f9f98", "#b99c72",
                 "#7f9fb2", "#9f8ab5", "#8eafb5", "#ebdbb2",
                 "#85809c", "#c98299", "#8ca9a2", "#c5a779",
                 "#8aa9bc", "#c4a7e7", "#99bac0", "#ebdbb2"],
        prodColor: "224;107;107", stagingColor: "108;158;224", devColor: "230;161;92", arrowColor: "196;167;231",
        vimComment: "#85809c", vimKey: "#c4a7e7", vimValue: "#99bac0")

    /// Rosé Pine Dawn — 밝은 짝. 프롬프트 색은 밝은 바탕에서 읽히게 한 단계 진하게
    public static let rosePineDawn = TerminalPalette(
        background: "#faf4ed", foreground: "#575279", cursor: "#907aa9",
        colors: ["#f2e9e1", "#b4637a", "#286983", "#ea9d34",
                 "#56949f", "#907aa9", "#d7827e", "#575279",
                 "#9893a5", "#b4637a", "#286983", "#ea9d34",
                 "#56949f", "#907aa9", "#d7827e", "#575279"],
        prodColor: "180;70;90", stagingColor: "40;105;131", devColor: "184;110;30", arrowColor: "144;122;169",
        vimComment: "#9893a5", vimKey: "#907aa9", vimValue: "#286983")
}

public enum SessionTheme {
    static func vimInit(_ p: TerminalPalette) -> String {
        #"set nocursorline nospell termguicolors | syntax off | if expand("%:t") =~# "^\.env" | syntax on | syntax clear | syntax match NexusEnvValue /=\zs.*$/ | syntax match NexusEnvKey /^\s*\zs[A-Za-z_][A-Za-z0-9_]*\ze\s*=/ | syntax match NexusEnvComment /^\s*#.*$/ | highlight NexusEnvComment term=NONE cterm=NONE ctermfg=8 gui=NONE guifg="# + p.vimComment
            + #" | highlight NexusEnvKey term=NONE cterm=NONE ctermfg=13 gui=NONE guifg="# + p.vimKey
            + #" | highlight NexusEnvValue term=NONE cterm=NONE ctermfg=14 gui=NONE guifg="# + p.vimValue + #" | endif"#
    }

    /// 원격 bash 에 이 세션에서만 적용할 rcfile 내용. 원격 파일은 건드리지 않는다.
    /// environment 는 프롬프트에 찍을 태그 글자("PROD,DB"). 색은 가장 센 태그 — 운영 빨강 · 스테이징 파랑 · 그 밖 주황.
    /// palette: 탭 바탕에 맞춘 프롬프트·vim 색 (TerminalColorMode.promptPalette)
    public static func remoteRC(environment: String, palette: TerminalPalette = .rosePine) -> String {
        let color: String
        switch ServerTags.strongest(ServerTags.parse(environment)) {
        case .production: color = palette.prodColor
        case .staging: color = palette.stagingColor
        case .plain: color = palette.devColor
        }
        let label = promptLabel(environment)
        let ps1 = #"\n\[\e[0m\]\u@\h\n\[\e[38;2;"# + color + #"m\]"# + label + #"\[\e[0m\] \w \[\e[38;2;"# + palette.arrowColor + #"m\]❯\[\e[0m\] "#
        return """
        source ~/.bashrc
        unset PROMPT_COMMAND
        PS1='\(ps1)'
        vim() {
          command vim -c '\(vimInit(palette))' "$@"
        }
        """
    }

    /// 프롬프트에 찍히는 태그 글자 (서버 정보의 프롬프트 미리 보기도 이것).
    /// PS1 은 작은따옴표 안이라 ' 가 있으면 rcfile 이 깨지고(운영 빨간 프롬프트가 조용히 빠진다) $( ) 는 원격에서 실행된다 — 글자만 남긴다
    /// 공백은 따옴표 안이라 괜찮다 — "DEV,Forward Proxy" 태그가 붙어 버리지 않게 둔다
    public static func promptLabel(_ environment: String) -> String {
        String(environment.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "_.,- ".unicodeScalars.contains($0) })
    }

    /// ssh 원격 명령: rcfile 을 프로세스 치환으로 넘겨 대화형 bash 를 연다.
    public static func remoteShellCommand(environment: String, palette: TerminalPalette = .rosePine) -> String {
        "exec bash --rcfile <(printf '%s' \(shellQuote(remoteRC(environment: environment, palette: palette)))) -i"
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

    /// 서버 SSH 탭 명령. Windows 는 PowerShell, 테마 그룹은 프롬프트 주입, 그 외는 일반 로그인 셸.
    /// bindInterface: 내부망 서버면 그 서비스의 장치 (ConnectPolicy.bindOptions).
    public static func ssh(to server: Server, config: ServerConfig, home: String = NSHomeDirectory(), bindInterface: String? = nil,
                           palette: TerminalPalette = .rosePine) -> String {
        holdOnFailure(sshCommandLine(to: server, config: config, home: home, bindInterface: bindInterface, palette: palette))
    }

    /// 래퍼 없이 ssh 명령줄만
    public static func sshCommandLine(to server: Server, config: ServerConfig, home: String = NSHomeDirectory(), bindInterface: String? = nil,
                                      palette: TerminalPalette = .rosePine) -> String {
        var args = ["ssh"] + ConnectPolicy.sharedArguments(port: server.port, bindInterface: bindInterface, home: home, identity: server.identityFile)
        switch server.type {
        case .windows:
            args += ["-t", server.target, "powershell.exe", "-NoLogo"]
        case .linux:
            if config.settings(for: server.group)?.theme == true {
                args += ["-t", server.target, SessionTheme.remoteShellCommand(environment: server.promptTag, palette: palette)]
            } else {
                args += [server.target]
            }
        case .openwrt:
            args += [server.target]   // 테마 프롬프트는 bash 로 띄우는데 OpenWrt 에는 bash 가 없다 — 일반 로그인 셸(ash)
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
