// 파일 전송(scp): 업로드·다운로드 입력창과 진행률 세션.

import AppKit
import Foundation
import ServersCore

extension AppModel {
    // MARK: 파일 전송 (scp, 목록 항목으로 관리)

    /// Upload… : 파일 선택창 → 원격 경로 입력창
    func chooseUpload(_ server: Server) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "업로드"
        panel.message = "\(server.key) 서버로 보낼 파일·폴더"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        promptUpload(server, localPaths: panel.urls.map(\.path))
    }

    /// 떨어뜨린 파일도 여기로 온다
    func promptUpload(_ server: Server, localPaths: [String]) {
        guard !localPaths.isEmpty else { return }
        uploadPrompt = UploadPromptRequest(server: server, localPaths: localPaths, initialPath: lastUploadPath[server.accountID])
    }

    func promptDownload(_ server: Server) {
        downloadPrompt = DownloadPromptRequest(server: server)
    }

    func startUpload(_ server: Server, localPaths: [String], remotePath: String) {
        lastUploadPath[server.accountID] = remotePath
        startTransfer(TransferSpec(server: server, direction: .upload, localPaths: localPaths, remotePath: remotePath, bindInterface: bindInterface(for: server)))
    }

    func startDownload(_ server: Server, remotePaths: [String], localDirectory: String) {
        guard !remotePaths.isEmpty else { return }
        startTransfer(TransferSpec(server: server, direction: .download, localPaths: [localDirectory], remotePaths: remotePaths, bindInterface: bindInterface(for: server)))
    }

    /// onFinish: 끝났을 때(완료·실패·취소 — 상태는 session.state) 한 번 (터미널 파일 넣기가 완료 뒤 경로를 입력한다)
    func startTransfer(_ spec: TransferSpec, onFinish: (@MainActor (TransferSession) -> Void)? = nil) {
        guard !vpnBindMissing(spec.server) else { return }
        requestNotifyAuthorizationIfNeeded()   // 끝날 때 알림 (AppModel+Notify) — 권한은 미리
        let session = TransferSession(spec: spec)
        let environment = askPassEnvironment(for: spec.server, title: "\(spec.server.key) · \(spec.server.target) · 전송", always: true) ?? [:]
        let id = session.id
        // 진행률 줄마다 메인으로 가 두 번 갱신하면 scp 출력이 빠를 때 화면이 따라가지 못한다 — 줄은 모아 두고 0.1초에 한 번만 반영한다.
        // 반영 때 쌓인 줄을 모두 meter 에 넣어 파일 바뀜 판정은 그대로, 화면 갱신(@Published)만 줄어든다.
        let coalescer = ProgressCoalescer()
        let flush: @MainActor () -> Void = { [weak self] in
            let batch = coalescer.drain()
            guard let self, let last = batch.last, let s = self.transfers.first(where: { $0.id == id }), s.isActive else { return }
            var meter = s.meter
            for progress in batch { meter.record(progress) }
            s.meter = meter
            s.state = .running(last)
            if !s.sizeRequested, s.spec.direction == .download {
                s.sizeRequested = true
                self.measureDownload(s)
            }
        }
        session.process.onProgress = { progress in
            guard coalescer.push(progress) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                flush()
            }
        }
        session.process.onLine = { [weak self] line in
            Task { @MainActor in
                guard let self, let s = self.transfers.first(where: { $0.id == id }) else { return }
                s.log.append(line)
                if s.log.count > TransferSession.maxLog { s.log.removeFirst(s.log.count - TransferSession.maxLog) }
            }
        }
        session.process.onExit = { [weak self] code, message in
            Task { @MainActor in
                flush()   // 아직 반영 안 된 마지막 진행률을 끝 상태보다 먼저
                guard let self, let s = self.transfers.first(where: { $0.id == id }) else { return }
                if s.process.stopRequested {
                    s.state = .cancelled
                    self.statusMessage = "전송 취소: \(s.title)"
                } else if code == 0 {
                    s.state = .done
                    self.statusMessage = "전송 완료: \(s.title)"
                } else {
                    s.state = .failed(exitCode: code, message: message)
                    self.statusMessage = "전송 실패: \(s.title) · \(message.split(separator: "\n").last ?? "exit \(code)")"
                }
                self.notifyTransferFinished(s)
                onFinish?(s)
            }
        }
        do {
            try session.process.start(arguments: spec.arguments(), environment: environment)
        } catch {
            session.state = .failed(exitCode: 126, message: "\(error)")
            notifyTransferFinished(session)
            onFinish?(session)
        }
        transfers.append(session)
        // 업로드는 전체 크기를 이 Mac 에서 바로 잰다 (큰 폴더는 오래 걸릴 수 있어 메인 밖에서)
        if spec.direction == .upload {
            let paths = spec.localPaths
            Task {
                let total = await Task.detached { TransferMeter.localSize(paths) }.value
                session.meter.totalBytes = total
            }
        }
    }

    /// 업로드 대상 폴더에 쓸 수 있는가. 창을 띄우지 않고 한 번만 시도한다 (공유 연결·키·저장된 비밀번호로 되는 경우만).
    /// 모르면(연결 실패·시간 초과) nil — 시트는 막지 않는다.
    func uploadTargetAccess(_ server: Server, path: String) async -> RemoteCommands.WriteAccess? {
        let script = RemoteCommands.writableCommand(path: path, type: server.type)
        let result = await runRemote(server, command: script.command, stdin: script.stdin, timeout: 10, allowPrompt: false)
        return result.ok ? RemoteCommands.parseWriteAccess(result.stdout) : nil
    }

    /// 로그인 홈의 절대 경로 (탐색 창과 같은 형식). 창 없이 한 번만 묻고 서버별로 기억한다. 모르면 nil.
    func remoteHome(_ server: Server) async -> String? {
        if let cached = remoteHomes[server.accountID] { return cached }
        let result = await runRemote(server, command: RemoteCommands.homeCommand(type: server.type), timeout: 10, allowPrompt: false)
        guard result.ok, let home = RemoteCommands.parseHome(result.stdout, type: server.type) else { return nil }
        remoteHomes[server.accountID] = home
        return home
    }

    /// 받을 원본들의 전체 크기를 원격에서 잰다. 첫 진행률 뒤에 부른다 — 인증이 끝나 scp 가 연 공유 연결(ControlMaster)을 타므로 창이 다시 뜨지 않는다.
    /// 실패하면 전체 진행률 없이 파일별로 보인다.
    private func measureDownload(_ session: TransferSession) {
        let script = RemoteCommands.sizeCommand(paths: session.spec.remotePaths, type: session.server.type)
        Task {
            let result = await runRemote(session.server, command: script.command, stdin: script.stdin, timeout: 60, allowPrompt: false)
            guard result.ok, let total = RemoteCommands.parseSize(result.stdout) else { return }
            session.meter.totalBytes = total
        }
    }

    func cancelTransfer(_ id: UUID) {
        transfers.first(where: { $0.id == id })?.process.stop()
    }

    /// 끝난 항목을 목록에서 지운다. 진행 중이면 먼저 취소한다.
    func removeTransfer(_ id: UUID) {
        guard let session = transfers.first(where: { $0.id == id }) else { return }
        session.process.stop()
        transfers.removeAll { $0.id == id }
    }

    func showTransferInfo(_ session: TransferSession) {
        transferInfo = session
    }
}
