// servers.conf 위치. 기본은 앱 저장소(~/Library/Application Support/Servers/servers.conf) — 앱 번들만 받아도 쓰도록.
// 없으면 첫 실행 때 만든다: 옛 위치(~/.config/servers/servers.conf)에 있으면 복사, 없으면 형식 설명만 든 빈 목록(서버 0개).

import Foundation

public enum ConfigLocation {
    public static var defaultPath: String { AppSupport.baseURL.appendingPathComponent("servers.conf").path }
    /// 앱 저장소로 옮기기 전 위치 (저장소 clone 자리). 복사만 하고 지우지 않는다.
    public static var legacyPath: String { NSHomeDirectory() + "/.config/servers/servers.conf" }

    public enum Prepared: Equatable, Sendable {
        case existing
        case copied(from: String)
        case created
    }

    /// `--conf <경로>` · 환경변수 SERVERS_CONF 가 있으면 그 경로 (테스트용, 만들지 않음). 없으면 nil — 기본 경로를 쓴다.
    public static func override(arguments: [String], environment: [String: String]) -> String? {
        if let i = arguments.firstIndex(of: "--conf"), arguments.indices.contains(i + 1) { return arguments[i + 1] }
        if let env = environment["SERVERS_CONF"], !env.isEmpty { return env }
        return nil
    }

    /// path 가 없으면 만든다. legacy 에 파일이 있으면 그대로 복사, 없으면 template.
    public static func prepare(path: String, legacy: String?, template: String = ConfigLocation.template,
                               fileManager: FileManager = .default) throws -> Prepared {
        if fileManager.fileExists(atPath: path) { return .existing }
        do {
            try fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if let legacy, fileManager.fileExists(atPath: legacy) {
                try fileManager.copyItem(atPath: legacy, toPath: path)
                return .copied(from: legacy)
            }
            try template.write(toFile: path, atomically: true, encoding: .utf8)
            return .created
        } catch {
            throw ConfigError(problem: "서버 목록 파일을 만들지 못했습니다: \(error.localizedDescription)",
                              fix: "폴더 권한을 확인하세요.", reference: path)
        }
    }

    /// 새로 만드는 servers.conf — 형식 설명(header)만. 서버는 없다 — 앱의 서버 추가(사이드바의 [서버 추가] 행)로 넣는다.
    public static var template: String { header }

    /// 형식 설명 (저장소 servers.conf 머리 주석과 같게)
    public static let header = #"""
# 서버 목록 (Nexus.app 이 읽는 유일한 입력). 서버 추가·편집·제거는 앱에서(서버 ▸ 서버 추가… · 그룹 머리 + · 서버 우클릭) — 이 파일을 직접 고쳐도 된다(⌘⇧R 다시 읽기).
#
# [키]          소문자 영문·숫자·밑줄. 앱 화면에 보이는 이름.
#   group=      사이드바 묶음. 같은 group끼리 한 섹션에 모인다. (예: home, acme)
#   network=    도달 경로. tailscale | lan | vpn | direct (선택 — 줄을 빼면 direct)
#               tailscale: 이 Mac의 Tailscale 상태 → 피어 online 여부 → SSH 확인
#               lan:       [network:lan] 서비스 활성 여부 → TCP 포트 확인
#               vpn:       시스템 설정의 VPN(vpn=) 연결 여부 → 그 VPN 의 utun 에 묶어 TCP 포트 확인. ssh·전송·터널도 그 utun 으로만 —
#                          꺼져 있으면 비활성(같은 사설 대역의 다른 장비로 새지 않게). 서버 IP 가 그 VPN 의 AllowedIPs 안이어야 닿는다
#               direct:    Direct(망 설정 없음) — 망 조건 없이 이 Mac 의 기본 경로로 바로 확인 (VPN 너머·공인 IP 장비)
#               확인 결과 색: 응답 초록 · 실패 빨강 · 꺼짐 회색. 확인이 실패하면 linux 는 ping 한 번 — 응답하면 실패(켜졌는데 SSH 안 됨), 없으면 꺼짐.
#               windows 는 ping 을 막는 게 기본이라 확인 실패를 곧 꺼짐으로 본다
#   vpn=        network=vpn 의 VPN 이름 (선택, scutil --nc list 의 이름 — Tailscale 제외). 빼면 연결된 첫 VPN. 다른 망에는 쓸 수 없다
#   type=       linux | windows | openwrt  (접속 셸, 종료 명령, services/ports 조회 방식이 다르다)
#               openwrt: OpenWrt 공유기 — 셸은 ash(테마 프롬프트 없음), 원격 정보에 Network · Firewall · Clients · WireGuard 탭.
#               전송·탐색은 SFTP 라 공유기에 sftp-server(openssh-sftp-server)가 있어야 한다
#   ip= user= port=   필수 (group= type= 도 필수)
#   extra_users= 같은 장비의 다른 계정 (선택, 쉼표 구분). 사이드바엔 한 줄 — 서버 정보의 사용자 칸에서 고르고([+] 추가 · 우클릭 제거·기본 계정) SSH·전송·터널·원격 정보에 쓴다.
#               user= 가 기본 계정이고 상태 확인은 늘 기본 계정으로. 비밀번호·키 파일은 앱에서 계정마다 따로. 예: extra_users=k3s-master,deploy
#   check=      원격 확인 방식 (선택). ssh: BatchMode 로그인(키 인증 필요) · tcp: SSH 포트 열림
#               기본값: linux+tailscale 은 ssh, windows·openwrt·lan·vpn·direct 는 tcp (Windows 는 비밀번호 인증이라 ssh 확인이 항상 실패)
#   role=       역할 — 서버가 하는 일 설명 (선택, 표시만). 예: CI/CD
#   env=        태그 (선택, 쉼표로 여러 개 — 태그 안 공백은 그대로). 예: PROD, DB · DEV, Forward Proxy · HOST. 태그마다 배지 색 (대소문자 무시):
#                 빨강 PROD PRD PRODUCTION LIVE REAL DR CANARY — 하나라도 있으면 운영 서버(목록에서 뺄 때 경고·빨간 프롬프트)
#                 파랑 STG STAGE STAGING PREPROD PRE QA UAT SIT TEST TST PERF LOAD BETA
#                 그 밖(DEV HOST PC VM DB …)은 색 없음. 표는 app/Sources/ServersCore/ServerTags.swift
#   wol_mac=    Windows 부팅(WOL)용 MAC (선택)
#   wol_via=    부팅(WOL) 명령을 실행할 다른 서버의 키 (wol_mac과 함께). 쉼표로 여러 경로 — 어느 경로로 보낼지는 앱 설정 창(⌘,)에서 고름(기본 첫 번째).
#               "서버:인터페이스" 면 그 서버에서 etherwake -i <인터페이스> <MAC>, 서버만이면 wakeonlan <MAC>. 예: wol_via=brume3:br-lan,nexus
#   proxy_port= SOCKS 프록시(ssh -D) 로컬 포트 (선택). 적으면 서버 정보에 [Chrome] — 이 서버를 거쳐 브라우징하는 Chrome 창(별도 프로필, 이름 풀이도 서버 쪽)
#   notify=     on | off (선택, 기본 off). on 이면 앱이 켜짐·꺼짐을 macOS 알림으로 ("<키> 켜짐" / "<키> 꺼짐")
#
# [network:lan]  내부망 서비스 설정
#   service=       macOS 네트워크 서비스 이름 (networksetup -listallnetworkservices)
#                  앱에서 첫 실행 기본값으로만 쓴다 — 그 뒤엔 ~/Library/Application Support/Servers/lan.json 이 원천
#                  (Ethernet 화면 서비스 카드의 [Intranet 으로 지정]). 기본값으로 되돌리려면 그 파일을 지운다
#                  시스템 경로(분할 라우팅)는 넣지 않는다: 이 앱이 lan 서버로 여는 연결만 이 서비스의 장치에 묶는다(ssh BindInterface).
#                  그래서 다른 프로그램은 내부망에 닿지 않고, 터널(127.0.0.x)은 어디서나 붙는다.
#   wait_attempts= wait_interval=  쓰지 않는다 (예전 켜기의 IP 대기 값 — 남아 있어도 된다)
#
# [group:이름]   그룹 설정
#   db_jump= db_host= db_port= db_local= db_name=   DB 터널 (jump 키의 메뉴에 "DB tunnel"로 표시, db_name 은 URL 안내용)
#
# 값 뒤에 " # 주석" 을 붙일 수 있다.

"""#
}
