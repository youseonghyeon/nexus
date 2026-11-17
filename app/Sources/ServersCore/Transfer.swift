// 파일 전송: scp 를 앱이 붙잡고 진행률을 읽는다. 터널처럼 목록 항목(TRANSFERS)으로 보인다.
//   TransferSpec      방향·경로 → scp 인자 (공유 연결 재사용, 세션 비밀번호·팝업은 ssh 와 같은 환경)
//   TransferProgress  scp 진행률 줄 파싱 ("file  45%  123MB  10.1MB/s  00:12 ETA")
//   TransferMeter     여러 파일(폴더·다중 선택)의 전체 진행률 — scp 는 파일마다 0→100% 를 새로 찍는다
//   TransferProcess   scp 를 `script -q /dev/null` 아래서 띄운다. scp 의 진행률은 "stdout 이 tty" 만으로는 안 나오고
//                     자기가 그 터미널의 전경 프로세스 그룹이어야 찍는다 (progressmeter.c can_output: getpgrp() == tcgetpgrp(stdout)).
//                     Process 로는 pty 를 제어 터미널로 만들 수 없어 scp 가 백그라운드라 판단하고 침묵했다 — script 가 자기 pty 안에서
//                     scp 를 전경으로 띄워 준다. 취소는 프로세스 트리 종료 (script → scp → ssh).

import Foundation

public enum TransferDirection: Sendable, Equatable { case upload, download }

public struct TransferSpec: Sendable, Equatable {
    public let server: Server
    public let direction: TransferDirection
    /// upload: 보낼 로컬 파일·폴더들. download: 받을 로컬 폴더 하나.
    public let localPaths: [String]
    /// upload: 원격 대상 하나(빈 문자열 = 홈). download: 받을 원격 원본들 (한 번의 scp 로 받는다).
    public let remotePaths: [String]
    /// 내부망 서버면 그 서비스의 장치 — 연결을 거기 묶는다 (ConnectPolicy.bindOptions)
    public let bindInterface: String?

    public init(server: Server, direction: TransferDirection, localPaths: [String], remotePaths: [String], bindInterface: String? = nil) {
        self.server = server
        self.direction = direction
        self.localPaths = localPaths
        self.remotePaths = remotePaths
        self.bindInterface = bindInterface
    }

    public init(server: Server, direction: TransferDirection, localPaths: [String], remotePath: String, bindInterface: String? = nil) {
        self.init(server: server, direction: direction, localPaths: localPaths, remotePaths: [remotePath], bindInterface: bindInterface)
    }

    /// upload 대상, 또는 download 의 첫 원본
    public var remotePath: String { remotePaths.first ?? "" }

    public var title: String {
        switch direction {
        case .upload:
            let names = localPaths.map { ($0 as NSString).lastPathComponent }
            let shown = names.count <= 2 ? names.joined(separator: ", ") : "\(names[0]) 외 \(names.count - 1)개"
            return "↑ \(shown) → \(server.key)"
        case .download:
            guard remotePaths.count > 1 else { return "↓ \(server.key):\(remotePath)" }
            return "↓ \(server.key): \(Self.name(remotePath)) 외 \(remotePaths.count - 1)개"
        }
    }

    /// 원격 경로의 마지막 이름 (끝 / 무시)
    static func name(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p.split(separator: "/").last.map(String.init) ?? p
    }

    public var remoteTarget: String { remoteTarget(remotePath) }
    public func remoteTarget(_ path: String) -> String { "\(server.target):\(path)" }

    /// scp 인자 ("scp" 제외). 디렉터리도 되게 항상 -r. OpenSSH 9+ 는 SFTP 모드라 원격 경로를 셸이 해석하지 않는다 (공백 안전, Windows 도 됨).
    public func arguments(home: String = NSHomeDirectory()) -> [String] {
        var args = ConnectPolicy.sharedArguments(port: server.port, portFlag: "-P", bindInterface: bindInterface, home: home, identity: server.identityFile) + AskPass.options + ["-r"]
        switch direction {
        case .upload: args += localPaths + [remoteTarget]
        case .download: args += remotePaths.map(remoteTarget) + [localPaths.first ?? home]
        }
        return args
    }
}

public struct TransferProgress: Sendable, Equatable {
    public let file: String
    public let percent: Int
    public let transferred: String
    public let rate: String
    public let eta: String

    /// 줄마다 컴파일하지 않도록 한 번만 (scp 는 진행률을 초당 여러 줄 찍는다)
    private static let lineRegex = try? NSRegularExpression(pattern: #"^(.*?)\s+(\d{1,3})%\s+(\S+)\s+(\S+/s)\s+(\S+)(?:\s+ETA)?\s*$"#)

    /// scp 진행률 한 줄: "<파일>  <NN>%  <크기>  <속도>  <남은 시간|경과>[ ETA]". 아니면 nil.
    public static func parse(_ line: String) -> TransferProgress? {
        guard let m = lineRegex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
        guard let percent = Int(group(2)) else { return nil }
        // 로케일이 없으면 scp 가 한글을 8진수로 찍는다 — 되돌리고, macOS 파일명(NFD)은 합쳐서(NFC) 보여준다
        let file = RemoteBrowser.unescapeOctal(group(1).trimmingCharacters(in: .whitespaces)).precomposedStringWithCanonicalMapping
        return TransferProgress(file: file, percent: percent, transferred: group(3), rate: group(4), eta: group(5))
    }
}

/// 진행률 줄을 모아 두었다가 한 번에 넘긴다 (임의 스레드에서 push, 메인에서 drain).
/// push 가 true 를 돌려주면 "비어 있다가 처음 쌓인 것" — 그때만 일정 시간 뒤 drain 을 예약하면 UI 갱신이 그 간격당 한 번으로 줄고,
/// drain 은 쌓인 줄을 모두 돌려주므로 TransferMeter 의 파일 바뀜 판정은 모든 줄을 본다. 끝날 때 drain 하면 마지막 값도 빠지지 않는다.
public final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [TransferProgress] = []

    public init() {}

    /// 새 갱신 예약이 필요하면 true
    public func push(_ progress: TransferProgress) -> Bool {
        lock.withLock {
            pending.append(progress)
            return pending.count == 1
        }
    }

    public func drain() -> [TransferProgress] {
        lock.withLock {
            defer { pending = [] }
            return pending
        }
    }
}

/// 여러 파일 전송의 전체 진행률. scp 는 파일마다 진행률 줄을 새로 찍으므로(0→100%), 파일이 바뀌면 앞 파일의 마지막 바이트를
/// 완료분에 더하고 "완료분 + 지금 파일" 을 전체 크기로 나눈다. 전체 크기는 따로 잰다 (RemoteCommands.sizeCommand) — 모르면 fraction 이 nil.
public struct TransferMeter: Sendable, Equatable {
    public var totalBytes: Int64?
    /// 지금까지 본 파일 수 (지금 받는 파일 포함)
    public private(set) var fileCount = 0
    private var completedBytes: Int64 = 0
    private var current: TransferProgress?
    private var currentBytes: Int64 = 0

    public init(totalBytes: Int64? = nil) { self.totalBytes = totalBytes }

    public mutating func record(_ progress: TransferProgress) {
        let bytes = Self.bytes(progress.transferred) ?? 0
        // 같은 파일이 이어지는 경우: 이름이 같고, 아직 100% 전이고, % 와 바이트가 줄지 않았다. 아니면 새 파일
        // (이름만으론 부족하다 — 폴더가 달라도 scp 는 파일 이름만 찍어 a/index.html 과 b/index.html 이 같게 보인다)
        if let last = current, last.file == progress.file, last.percent < 100, progress.percent >= last.percent, bytes >= currentBytes {
            // 같은 파일
        } else {
            completedBytes += currentBytes
            fileCount += 1
        }
        current = progress
        currentBytes = bytes
    }

    /// 지금까지 받은(보낸) 바이트 (scp 표시가 반올림이라 근삿값)
    public var doneBytes: Int64 { completedBytes + currentBytes }

    /// 0...1. 전체 크기를 모르면 nil.
    public var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(doneBytes) / Double(total))
    }

    private static let bytesRegex = try? NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)\s*([KMGTP]?)i?B?$"#)

    /// scp 의 크기 표시("123MB", "12KB", "1040MB", "512", "0.0KB") → 바이트 (1024 단위). 못 읽으면 nil.
    public static func bytes(_ text: String) -> Int64? {
        guard let m = bytesRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(m.range(at: 1), in: text), let number = Double(text[numberRange]) else { return nil }
        let unit = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? ""
        let power = ["", "K", "M", "G", "T", "P"].firstIndex(of: unit) ?? 0
        return Int64(number * pow(1024, Double(power)))
    }

    /// 업로드 전체 크기: 로컬 파일·폴더들의 파일 크기 합 (링크는 따라간다 — scp -r 처럼). 0 이면 nil.
    public static func localSize(_ paths: [String], fileManager: FileManager = .default) -> Int64? {
        var total: Int64 = 0
        for path in paths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory == true else { total += Int64(values?.fileSize ?? 0); continue }
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let items = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) else { continue }
            for case let item as URL in items {
                let v = try? item.resourceValues(forKeys: Set(keys))
                let target = v?.isSymbolicLink == true ? try? item.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) : v
                if target?.isRegularFile == true { total += Int64(target?.fileSize ?? 0) }
            }
        }
        return total > 0 ? total : nil
    }

    /// 바이트 → "1.2 GB" (scp 처럼 1024 단위)
    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

public enum TransferState: Sendable, Equatable {
    case running(TransferProgress?)
    case done
    case failed(exitCode: Int32, message: String)
    case cancelled
}

/// scp 하나. 콜백은 임의 스레드에서 온다 (호출자가 메인으로 넘긴다).
public final class TransferProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var lastLines: [String] = []
    private var started = false
    public private(set) var stopRequested = false

    public var onProgress: (@Sendable (TransferProgress) -> Void)?
    public var onLine: (@Sendable (String) -> Void)?
    public var onExit: (@Sendable (Int32, String) -> Void)?

    public init() {}

    /// script 래퍼. 자식의 종료 코드를 그대로 돌려주고(exit 3 → 3), 트리째 SIGTERM 을 받으면 자신도 신호로 죽어 128+15 가 된다.
    static let scriptWrapper = "/usr/bin/script"
    /// 실제로 띄울 래퍼 (테스트가 없는 경로를 넣어 실행 실패를 만든다)
    var wrapper = TransferProcess.scriptWrapper
    private var commandFile: String?

    /// 명령줄을 임시 스크립트 파일에 쓴다. Foundation 의 Process 는 arguments 를 fileSystemRepresentation 으로 넘겨 한글이 NFD(자모 분리)로
    /// 바뀐다 — Windows(NTFS)는 NFC 파일을 못 찾고 Linux 엔 '깨진' 중복 폴더가 생겼다. 파일 경로는 ASCII 라 안전하고 내용은 쓴 바이트 그대로 실행된다.
    static func writeCommandFile(executable: String, arguments: [String]) throws -> String {
        let path = NSTemporaryDirectory() + "servers-transfer-\(UUID().uuidString).sh"
        let line = "exec " + ([executable] + arguments).map(shellQuote).joined(separator: " ") + "\n"
        try line.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    /// executable 은 절대 경로 또는 PATH 이름 (기본 scp). script 가 만든 pty 안에서 돌고, 그 출력이 우리 pty 로 온다.
    public func start(executable: String = "scp", arguments: [String], environment: [String: String]) throws {
        var master: Int32 = 0, slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NSError(domain: "Transfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "pty 를 열지 못했습니다."])
        }
        let path = executable.hasPrefix("/") ? executable : (ProcessRunner.resolve(executable) ?? executable)
        // 여기서부터 실패하면 pty 양쪽(과 임시 스크립트)을 치우고 던진다 — 두면 시도마다 fd 둘·파일 하나가 남는다
        let file: String
        do {
            file = try Self.writeCommandFile(executable: path, arguments: arguments)
        } catch {
            close(master); close(slave)
            throw error
        }
        commandFile = file
        process.executableURL = URL(fileURLWithPath: wrapper)
        process.arguments = ["-q", "/dev/null", "/bin/sh", file]
        process.environment = ProcessLocale.environment(adding: environment)
        process.standardInput = FileHandle.nullDevice
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        let finished = Completion(needed: 2) { [weak self] in
            guard let self else { return }
            if let file = self.commandFile { try? FileManager.default.removeItem(atPath: file) }
            let message = self.lock.withLock { self.lastLines.suffix(5).joined(separator: "\n") }
            // 신호로 죽으면 셸 관례대로 128+신호 (취소 = 143)
            let code: Int32 = self.process.isRunning ? 128 + SIGTERM
                : (self.process.terminationReason == .uncaughtSignal ? 128 + self.process.terminationStatus : self.process.terminationStatus)
            self.onExit?(code, message)
        }
        process.terminationHandler = { _ in
            finished.step()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finished.force() }
        }
        do {
            try process.run()
        } catch {
            close(master); close(slave)
            try? FileManager.default.removeItem(atPath: file)
            commandFile = nil
            throw error
        }
        close(slave)   // 부모 쪽 슬레이브를 닫아야 자식이 끝났을 때 마스터 읽기가 EOF 로 끝난다
        started = true
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        blockingThread("transfer.read") { [weak self] in
            var buffer = Data()
            while true {
                let chunk = masterHandle.availableData   // 자식 종료 후 EIO 는 빈 데이터로 온다
                if chunk.isEmpty { break }
                buffer.append(chunk)
                // 진행률은 \r 로, 일반 출력은 \n 으로 끝난다. 둘 다 줄 경계로 본다.
                while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = String(decoding: buffer[..<end], as: UTF8.self)
                    buffer.removeSubrange(...end)
                    self?.handle(line)
                }
            }
            if !buffer.isEmpty { self?.handle(String(decoding: buffer, as: UTF8.self)) }
            finished.step()
        }
    }

    private func handle(_ raw: String) {
        // script 가 stdin EOF 를 pty 에 ^D 로 넣고 tty 가 그걸 지우는 ^H 를 찍는다 — 제어문자는 걷어낸다 (탭은 남김)
        let cleaned = String(raw.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" })
        let line = cleaned.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if let progress = TransferProgress.parse(line) {
            onProgress?(progress)
        } else {
            lock.withLock { lastLines.append(line); if lastLines.count > 50 { lastLines.removeFirst() } }
            onLine?(line)
        }
    }

    public var isRunning: Bool { started && process.isRunning }

    /// 프로세스 트리(scp·ssh·비밀번호 팝업)에 SIGTERM, 2초 안에 안 죽으면 SIGKILL.
    public func stop() {
        guard started, process.isRunning else { return }
        stopRequested = true
        ProcessTree.terminate(process.processIdentifier) { [weak self] in self?.process.isRunning == true }
    }
}

/// 전송이 끝났을 때의 macOS 알림 문구 (AppModel+Notify). 실패는 항상 — 놓치면 올라간 줄 안다.
/// 완료는 오래 걸린 것만 — 몇 초짜리는 보고 있던 화면의 상태줄로 충분하다. 취소는 직접 한 일이라 알리지 않는다.
public enum TransferNotice {
    /// 완료를 알리는 최소 소요 시간
    public static let minimumDuration: TimeInterval = 10

    public static func content(for state: TransferState, spec: TransferSpec, elapsed: TimeInterval) -> (title: String, body: String)? {
        switch state {
        case .done:
            return elapsed >= minimumDuration ? ("전송 완료", spec.title) : nil
        case let .failed(exitCode, message):
            let reason = message.split(separator: "\n").last.map(String.init) ?? "exit \(exitCode)"
            return ("전송 실패", "\(spec.title)\n\(reason)")
        case .running, .cancelled:
            return nil
        }
    }
}
