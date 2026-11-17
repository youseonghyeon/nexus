// 화면에 띄울 입력창·시트·확인창 요청. AppModel(@Observable) 속성에 올라오면 뷰가 .sheet/.alert 로 보여준다.

import Foundation
import ServersCore

/// 업로드 입력창 요청: 고른(또는 떨어뜨린) 로컬 경로들 → 원격 경로를 묻는다
struct UploadPromptRequest: Identifiable {
    let id = UUID()
    let server: Server
    let localPaths: [String]
    /// 그 서버에 마지막으로 올린 폴더 (없으면 기본 폴더)
    var initialPath: String? = nil
}

/// 다운로드 입력창 요청: 원격 경로와 받을 폴더를 묻는다
struct DownloadPromptRequest: Identifiable {
    let id = UUID()
    let server: Server
}

/// 서버별 원격 정보(spec/services/ports) 캐시. 화면을 오가도 마지막 결과가 남는다.
struct RemoteInfoResult: Equatable {
    var lines: [String] = []
    var fetchedAt: Date?
    var error: String?
    var loading = false
    /// lines 를 받을 때 한 번 파싱한 값 (화면이 그리기마다 파싱하지 않게). lines 를 바꾸면 함께 바꾼다.
    var parsed: ParsedRemoteInfo = .none
}

/// 조회 결과 (로그·명령 오류) — 독립 창에 보인다 (QueryResultWindow)
struct QueryResult: Identifiable {
    let id = UUID()
    let title: String
    let lines: [String]
    let failed: Bool
}

/// 터널 입력창 요청 (미리 채울 값)
struct TunnelPromptRequest: Identifiable {
    let id = UUID()
    let server: Server
    let remotePort: Int?
    let localPort: Int?
    /// 서버 쪽 대상 주소. Ports 목록의 바인딩 주소가 특정 인터페이스면 그 주소로 포워딩한다.
    var remoteHost: String = "127.0.0.1"
    /// DB 터널이면 원격은 servers.conf 값 그대로 고정(수정 불가), 로컬 포트만 고른다.
    var dbTarget: (host: String, port: Int, name: String?)?
}

/// 확인이 필요한 동작
struct PendingConfirm: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// 주 동작 말고 고를 수 있는 다른 동작 (예: 키 파일 [이 자리 그대로]). 없으면 주 동작·취소만.
    var alternative: (title: String, action: @MainActor () -> Void)? = nil
    let action: @MainActor () -> Void
}

/// 서버 추가 입력창 요청 (그룹 헤더의 + — 그 그룹과 망을 미리 채운다)
struct AddServerRequest: Identifiable {
    let id = UUID()
    let group: String
    let network: ServerNetwork
}
