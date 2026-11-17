// StatusNotice(토스트 경고 분류) — 앱이 실제로 쓰는 문구로 확인한다.

import XCTest
@testable import ServersCore

final class StatusNoticeTests: XCTestCase {
    func testWarnings() {
        for text in [
            "알림 권한이 없습니다 — 시스템 설정 › 알림 › Nexus 에서 허용하세요",
            "인증을 취소했거나 실패했습니다 · 내부망 설정을 바꾸지 않았습니다.",
            "프록시 터널이 열리지 않아 Chrome 을 띄우지 않았습니다.",
            "내부망 설정을 읽지 못해 servers.conf 값을 씁니다: x",
            "전송 실패: ↑ a.zip → nexus · Permission denied",
            "터널 끊김: db.acme:5432 · Connection reset",
            "로컬 포트 80 는 관리자 권한이 필요합니다.",
            "공인 IP 를 가져오지 못했습니다.",
            "Chrome 이 설치돼 있지 않습니다.",
            "nexus Tailscale 인증이 끝나지 않았습니다 (exit 1).",
            "win 에는 wol_mac/wol_via 가 없습니다.",
            "windows 서버가 아니면 shutdown 을 할 수 없습니다.",
            "db.acme 이름은 이미 was 터널(127.0.0.3:5432)이 사용 중이라 고를 수 없습니다. 다른 이름을 고르거나 그 터널을 목록에서 지우세요.",
            "터널 이름으로 쓸 수 없습니다: a_b · 영문·숫자·하이픈(-)·점(.)만 쓸 수 있습니다 (예: api.acme).",
            "acme ethernet 서비스는 지금 인터넷 경로라 끌 수 없습니다.",
        ] {
            XCTAssertTrue(StatusNotice.isWarning(text), text)
        }
    }

    func testInfos() {
        for text in [
            "복사됨: alice@100.101.0.1",
            "전송 완료: ↑ a.zip → nexus",
            "전송 취소: ↑ a.zip → nexus",
            "터널 취소됨: db.acme:5432",
            "로컬 포트 8080 는 사용 중이라 8081 로 열었습니다.",
            "win 부팅 요청을 nexus 에서 보냈습니다.",
            "nexus 서버를 저장했습니다. IP·사용자가 바뀌어 저장한 비밀번호를 지웠습니다.",
            "db.acme 의 hosts 줄은 남겨 두었습니다 (인증 취소).",
            "Tailscale 인증 완료 · 12시간 동안 모든 Tailscale 서버에 SSH 가 됩니다.",
            "브라우저에서 Tailscale 인증을 마치면 자동으로 이어집니다.",
            "Tailscale 을 켰습니다.",
            "Tailscale 을 껐습니다.",
            "acme ethernet 서비스를 켰습니다",
            "acme ethernet 서비스로 전환했습니다",
            "nexus 서버를 추가했습니다.",
            "nexus 서버를 목록에서 지웠습니다.",
        ] {
            XCTAssertFalse(StatusNotice.isWarning(text), text)
        }
    }
}
