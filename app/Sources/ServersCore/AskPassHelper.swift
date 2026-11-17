// 비밀번호 팝업 헬퍼(servers-askpass)의 UI 없는 부분. ssh(SSH_ASKPASS)와 sudo(SUDO_ASKPASS)가 프롬프트를 $1 로 넘겨 부르고,
// 표준출력 한 줄을 답으로 받는다. 취소하면 1 로 끝난다.
//   kind(of:)        프롬프트 종류: 호스트 키 확인("(yes/no…)") 은 예/아니오, 그 외는 비밀번호
//   reply(_:answer:) 표준출력에 쓸 답 (예/아니오 → "yes"/"no")
//   usesSessionPassword  세션 비밀번호를 대입해도 되는 물음인지 (키 파일 암호 물음은 아니다)
//   claimFirstUse    세션 비밀번호(SERVERS_ASKPASS_PASSWORD)를 쓸 수 있는 첫 호출인지. ssh 는 틀리면 같은 프롬프트로 다시 부르므로
//                    같은 부모(ssh pid)의 두 번째 호출은 "저장된 비밀번호가 틀렸다" 로 보고 창을 띄운다. 호출 사이 상태는 마커 파일뿐.
//   parentIsSSH      취소 시 부모 ssh 를 끝낼지. ssh 는 취소해도 다음 프롬프트(재시도·keyboard-interactive)로 넘어가므로
//                    부모를 SIGTERM 으로 끝내야 팝업이 다시 뜨지 않는다. sudo 는 취소를 실패로 처리하므로 건드리지 않는다.

import Foundation

public enum AskPassHelper {
    public enum Kind: Sendable, Equatable { case secret, yesNo }

    public static func kind(of prompt: String) -> Kind {
        prompt.contains("(yes/no") ? .yesNo : .secret
    }

    /// 세션 비밀번호(서버 계정 비밀번호)를 대입해도 되는 물음인가. 암호 걸린 키 파일의 "Enter passphrase for key …" 는 아니다 —
    /// 서버 비밀번호를 키 암호로 넣으면 틀리고, 마커가 찍혀 뒤따르는 진짜 비밀번호 물음에는 대입되지 않는다.
    public static func usesSessionPassword(for prompt: String) -> Bool {
        kind(of: prompt) == .secret && !prompt.lowercased().contains("passphrase")
    }

    /// 헬퍼가 표준출력에 쓸 답. 호스트 키 확인은 ssh 가 알아듣는 yes/no 로 (Yes 버튼 → yes, 그 외 → no).
    public static func reply(_ kind: Kind, answer: String) -> String {
        switch kind {
        case .secret: return answer
        case .yesNo: return answer.lowercased() == "yes" ? "yes" : "no"
        }
    }

    /// 부모 pid 별 마커 파일 (임시 디렉터리, 사용자 전용).
    public static func markerURL(parent: pid_t, directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) -> URL {
        directory.appendingPathComponent("servers-askpass-\(parent)")
    }

    /// 마커가 없거나 staleAfter 보다 오래됐으면 새로 찍고 true (첫 호출). 최근 마커가 있으면 false (재시도 → 창).
    /// 창을 띄운 뒤에도 마커를 지우지 않는다: 세 번째 호출에서 틀린 세션 비밀번호를 다시 대입하면 안 되기 때문.
    public static func claimFirstUse(marker: URL, now: Date = Date(), staleAfter: TimeInterval = 120) -> Bool {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
           let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) < staleAfter {
            return false
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        return true
    }

    /// 실행 파일 이름(comm) 또는 스크립트 경로(args 의 두 번째 토큰, 테스트의 가짜 ssh)가 ssh 이면 부모로 본다.
    public static func isSSH(comm: String, args: String) -> Bool {
        let name = (comm as NSString).lastPathComponent
        let script = args.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).dropFirst().first.map { ($0 as NSString).lastPathComponent } ?? ""
        return name == "ssh" || script == "ssh"
    }

    public static func parentIsSSH(pid: pid_t) -> Bool {
        isSSH(comm: ps("comm=", pid: pid), args: ps("args=", pid: pid))
    }

    private static func ps(_ format: String, pid: pid_t) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", format, "-p", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
