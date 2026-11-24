// ssh·scp·sftp 에 붙이는 연결 옵션: 타임아웃 · 연결 공유(ControlMaster) · 키 파일 · 장치 묶기.

import Foundation

/// 연결 시도 정책 (연결 타임아웃·재시도).
public enum ConnectPolicy {
    public static let timeoutSeconds = 3
    public static var sshOptions: [String] {
        ["-o", "ConnectTimeout=\(timeoutSeconds)", "-o", "ConnectionAttempts=1"]
    }
    /// SSH 탭·전송·상태 확인이 이 소켓으로 연결을 공유한다. 이름 srv-%C 는 삭제된 srv TUI 와 함께 쓰던 때 그대로다.
    public static func controlOptions(home: String = NSHomeDirectory()) -> [String] {
        ["-o", "ControlMaster=auto", "-o", "ControlPath=\(home)/.ssh/srv-%C", "-o", "ControlPersist=10m"]
    }
    /// 공유 연결을 쓰지 않는 전용 연결 (터널: 공유 연결을 거치면 ssh -N 이 즉시 끝난다 · Tailscale 로그인: 새 연결이어야 배너가 온다)
    public static let noControlOptions = ["-o", "ControlMaster=no", "-o", "ControlPath=none"]

    /// ssh·scp·sftp 공통 앞부분: 연결 정책 + 포트 + 연결 공유 + 장치 묶기. scp·sftp 는 portFlag "-P".
    public static func sharedArguments(port: Int, portFlag: String = "-p", bindInterface: String?, home: String = NSHomeDirectory(),
                                       identity: String? = nil) -> [String] {
        sshOptions + [portFlag, "\(port)"] + controlOptions(home: home) + bindOptions(bindInterface) + identityOptions(identity)
    }

    /// 서버별 키 파일 (Server.identityFile). 파일이 없으면 붙이지 않는다 — 지워졌어도 지금처럼 기본 키·비밀번호로 접속한다.
    /// IdentitiesOnly: 기본 키·agent 키를 먼저 시도하다 "Too many authentication failures" 로 끊기지 않게 이 키만 (비밀번호 인증은 그대로).
    public static func identityOptions(_ path: String?, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        guard let path, !path.isEmpty, fileExists(path) else { return [] }
        return ["-i", path, "-o", "IdentitiesOnly=yes"]
    }

    /// 내부망 서버로 가는 연결을 그 서비스의 장치(en10 등)에 묶는다. 시스템 경로 없이 장치의 스코프 기본 경로(내부망 라우터)로 나가고,
    /// 이 옵션이 없는 다른 프로세스는 내부망에 닿지 않는다. 장치를 모르면(nil) 아무 것도 붙이지 않는다.
    public static func bindOptions(_ device: String?) -> [String] {
        guard let device, !device.isEmpty else { return [] }
        return ["-o", "BindInterface=\(device)"]
    }
}
