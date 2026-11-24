// tcpdump · sudo 인자와 그 출력 읽기 (장치 목록 · 실패 이유 · 하드웨어 포트 이름). 프로세스는 CaptureProcess, 필터 도우미는 CaptureFilterAssist.

import Foundation

/// tcpdump 실행 인자. 장치 이름은 영문·숫자·점만 (sudo 로 도는 명령이라 인자 하나로만 넘긴다 — 셸 없음)
public enum CaptureCommand {
    /// 잡는 바이트: 헤더 + TLS ClientHello 전체(SNI 가 맨 뒤에 올 수 있다). 목록엔 앞 256 바이트만 남긴다
    public static let snaplen = 4096   // lo0·utun 은 조각이 커 1.5KB 넘는 ClientHello 가 한 조각에 온다

    public static func isValidDevice(_ device: String) -> Bool {
        !device.isEmpty && device.count <= 32 && device.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
    }

    /// tcpdump 인자 (sudo 뒤에 붙인다). 필터는 tcpdump 표현식 그대로 — 낱말로 나눠 넘긴다 (tcpdump 가 이어 붙여 읽는다)
    public static func arguments(device: String, filter: String) -> [String]? {
        guard isValidDevice(device) else { return nil }
        let words = filter.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        // "-" 로 시작하는 낱말은 tcpdump 옵션으로 읽힐 수 있어 막는다
        guard !words.contains(where: { $0.hasPrefix("-") }) else { return nil }
        return ["-i", device, "-n", "-U", "-s", String(snaplen), "-w", "-"] + words
    }

    /// `tcpdump -D` → 캡처할 수 있는 장치 ("Up, Running" 이고 연결 끊김이 아닌 것). 순서 그대로
    public static func parseDevices(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let dot = line.firstIndex(of: ".") else { return nil }
            let rest = line[line.index(after: dot)...]
            let name = String(rest.prefix { $0 != " " })
            guard isValidDevice(name), rest.contains("Up, Running"), !rest.contains("Disconnected"), !rest.contains("Not associated") else { return nil }
            return name
        }
    }

    /// sudo 인자: 지문 단계는 -A 없이, 비밀번호 창 단계는 -A
    public static func sudoArguments(_ tcpdumpArguments: [String], askPass: Bool) -> [String] {
        (askPass ? ["-A"] : []) + ["/usr/sbin/tcpdump"] + tcpdumpArguments
    }

    /// 지문 단계가 인증을 못 받고 끝났는가 (지문 취소·지문 없음 → sudo 가 비밀번호를 물으려다 터미널이 없어 실패) → 비밀번호 창으로 다시
    public static func needsPasswordFallback(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        guard text.contains("sudo:") else { return false }
        return text.contains("terminal is required") || text.contains("password is required") || text.contains("no tty present")
    }

    /// tcpdump 표준 오류에서 화면에 보일 이유 한 줄 ("syntax error" · "permission denied" …). 시작 안내 줄은 뺀다
    public static func failureReason(_ stderr: String) -> String? {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("listening on") && !$0.contains("forcing exit") && !$0.contains("packets captured")
                && !$0.contains("packets received") && !$0.contains("packets dropped") }
        return lines.last
    }

    /// `networksetup -listallhardwareports` → 장치 → 이름 ("en11" → "TPlink 2.5G Ethernet")
    public static func parseHardwarePorts(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var port: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") { port = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("Device:"), let name = port {
                let device = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                if !device.isEmpty { out[device] = name }
                port = nil
            }
        }
        return out
    }
}

extension CaptureCommand {
    /// 캡처가 스스로 끝났을 때 화면에 보일 문장. 먼저 받은 데이터의 문제(pipelineFailure), 다음 tcpdump 표준 오류의 이유, 없으면 종료 코드
    public static func endText(pipelineFailure: String?, stderr: String, code: Int32) -> String {
        if let pipelineFailure { return pipelineFailure }
        if let reason = failureReason(stderr) {
            return reason.contains("password") || reason.contains("sudo") ? "관리자 인증을 받지 못했습니다 (\(reason))" : reason
        }
        return "캡처가 끝났습니다 (종료 코드 \(code))"
    }
}
