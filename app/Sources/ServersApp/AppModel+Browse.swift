// 원격 폴더 탐색: sftp 배치를 한 번 돌려 목록을 받는다 (RemoteBrowser). 전송과 같은 공유 연결·비밀번호 팝업.

import Foundation
import ServersCore

/// 탐색 실패 이유 (없는 경로·연결 실패·인증 취소)
struct BrowseError: Error { let reason: String }

extension AppModel {
    /// path 가 nil 이면 홈.
    func browseRemote(_ server: Server, path: String?) async -> Result<RemoteBrowser.Listing, BrowseError> {
        if status.lacksVPNBind(server) { return .failure(BrowseError(reason: "\(server.vpn ?? "VPN") 이 연결돼 있지 않습니다")) }
        let environment = askPassEnvironment(for: server, title: "\(server.key) · \(server.target) · 폴더 탐색", always: true) ?? [:]
        let result = await runner.run("sftp", RemoteBrowser.arguments(server: server, bindInterface: bindInterface(for: server)), stdin: RemoteBrowser.batchScript(path: path),
                                      environment: environment, timeout: 60)
        if result.exitCode == CommandResult.timedOutExitCode { return .failure(BrowseError(reason: "응답이 없습니다 (60초)")) }
        let stdout = result.stdout
        // 큰 폴더는 줄이 수천 개 — 해석·정렬은 메인 밖에서
        let outcome = await Task.detached(priority: .userInitiated) { RemoteBrowser.parse(stdout) }.value
        if let error = outcome.error { return .failure(BrowseError(reason: error)) }
        if let listing = outcome.listing {
            // 목록은 비었는데 읽지 못한 줄이 있으면 서버의 ls 형식이 다른 것 — 그 줄을 보여 줘야 고칠 수 있다
            if listing.entries.isEmpty, !outcome.unparsed.isEmpty {
                return .failure(BrowseError(reason: "목록 형식을 읽지 못했습니다 · 예: " + outcome.unparsed.prefix(2).joined(separator: " ⏎ ")))
            }
            return .success(listing)
        }
        let lines = RemoteCommands.cleanOutput(result.stdout + result.stderr, type: .linux)
            .filter { !$0.isEmpty && !$0.hasPrefix("sftp>") }
        return .failure(BrowseError(reason: lines.last ?? "exit \(result.exitCode)"))
    }
}
