// 공유 SSH 연결(ControlMaster) 끊기. ControlPersist 로 마지막 사용 뒤에도 남는 연결을 시험용으로 바로 내린다.
// -O stop: 새 연결만 더 받지 않는다 — 이미 이 연결을 타는 SSH 탭·전송은 그대로, 다음 접속은 새로 인증한다 (-O exit 는 탭까지 끊는다).

import CryptoKit
import Darwin
import Foundation

public enum SharedConnection {
    /// ssh 가 ControlPath 의 %C 로 만드는 이름과 같은 소켓 경로 — %C = SHA1(%l 로컬 호스트 이름 + %h 원격 + %p 포트 + %r 사용자 + %j 점프(없음)).
    /// ~/.ssh/config 의 HostName 별칭은 반영하지 않는다 (목록의 ip 를 그대로 쓴다).
    public static func socketPath(for server: Server, home: String = NSHomeDirectory(), localHost: String = localHostName()) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(localHost)\(server.ip)\(server.port)\(server.user)".utf8))
        return "\(home)/.ssh/srv-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 공유 연결 소켓이 있는 계정 (기본 계정 먼저)
    public static func activeAccounts(of server: Server, home: String = NSHomeDirectory(), localHost: String = localHostName(),
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        server.accounts.filter { fileExists(socketPath(for: server.account($0), home: home, localHost: localHost)) }
    }

    /// ssh 인자. 소켓에 요청만 보내므로 망에 나가지 않는다.
    public static func stopArguments(for server: Server, home: String = NSHomeDirectory()) -> [String] {
        ["-p", "\(server.port)", "-o", "ControlPath=\(home)/.ssh/srv-%C", "-O", "stop", server.target]
    }

    /// gethostname — ssh 의 %l 과 같은 값 (ProcessInfo.hostName 은 DNS 이름이 섞일 수 있다)
    public static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
