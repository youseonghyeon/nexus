// 업로드 시트의 원격 경로 칸: 기본 폴더 이름(download · Downloads)을 홈 아래 절대 경로로 펴고, 쓸 수 있는지 묻는다.
// 자동으로 채운 기본 폴더가 서버에 없으면 이유 없이 막히지 않게 홈으로 바꾼다 — 사용자가 직접 친 경로는 바꾸지 않는다
// (2026-11-10: 직접 친 없는 폴더가 말없이 홈으로 바뀌었다).

import Foundation

public enum UploadPathPlan {
    /// 칸을 어떻게 할지
    public enum Next: Sendable, Equatable {
        /// 칸을 이 값으로 바꾼다 (바뀐 값으로 다시 돈다)
        case fill(String)
        /// 칸은 그대로, 쓰기 확인 결과를 보인다 (nil = 모름 — 막지 않는다)
        case show(RemoteCommands.WriteAccess?)
    }

    /// 홈 아래 기본 폴더 이름: Windows Downloads, 그 밖 download
    public static func defaultName(windows: Bool) -> String { windows ? "Downloads" : "download" }

    /// 칸 값 → 다음 동작. home·access 는 필요할 때만 부른다 (ssh 를 돌리므로).
    ///   1. 칸이 기본 이름 그대로이고 홈을 알면 → 홈/기본 이름
    ///   2. 아니면 쓸 수 있는지 묻는다
    ///   3. 없음(missing)이고 자동으로 채운 값이며 칸이 기본 폴더(이름 또는 홈/이름)면 → 홈 (모르면 빈 칸 = 홈)
    ///   4. 그 밖은 결과를 보인다
    /// 부른 쪽(화면의 메인 액터)에서 그대로 돈다 — home·access 가 AppModel 을 부르므로 클로저를 다른 실행기로 넘기지 않는다.
    public nonisolated(nonsending) static func next(field: String, windows: Bool, autoFilled: Bool,
                            home: () async -> String?, access: (String) async -> RemoteCommands.WriteAccess?) async -> Next {
        let name = defaultName(windows: windows)
        if field == name, let home = await home() { return .fill(RemoteBrowser.child(home, name)) }
        let result = await access(RemoteBrowser.normalizePath(field, windows: windows))
        if result == .missing, autoFilled {
            let home = await home()
            if field == name || field == home.map({ RemoteBrowser.child($0, name) }) { return .fill(home ?? "") }
        }
        return .show(result)
    }
}
