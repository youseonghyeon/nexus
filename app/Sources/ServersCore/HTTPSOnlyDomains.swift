// 브라우저가 HTTPS 로만 여는 최상위 도메인 (HSTS preload — Chromium 의 목록을 Safari·Firefox 도 쓴다).
// 이런 이름으로 끝나는 주소는 /etc/hosts 에 적은 이름이어도 브라우저가 http:// 를 https:// 로 바꿔 연다 — 평문 HTTP 터널은 브라우저에서 안 열린다
// (2026-11-18: 서버 이름 `….office` 로 연 터널이 Chrome 에서 안 열렸다). 브라우저 밖(DB 클라이언트·curl)은 상관없다.
// 목록은 Chromium `net/http/transport_security_state_static.json` 에서 점 없는 항목(최상위 도메인 통째)만 추린 것 — 2026-11-18 기준 52개.
// 거의 바뀌지 않는다. 고칠 때는 그 파일에서 mode=force-https · include_subdomains 인 점 없는 이름을 다시 뽑는다.

import Foundation

public enum HTTPSOnlyDomains {
    static let topLevel: Set<String> = [
        "amazon", "android", "app", "audible", "azure", "bank", "bing", "boo", "channel", "chrome", "dad", "day", "dev", "eat", "esq", "fire", "fly", "foo",
        "fujitsu", "gle", "gmail", "google", "hangout", "here", "hotmail", "imdb", "ing", "insurance", "kindle", "meet", "meme", "microsoft", "mov", "new",
        "nexus", "office", "page", "phd", "play", "prime", "prof", "rsvp", "search", "silk", "skype", "windows", "xbox", "xn--cckwcxetd", "xn--jlq480n2rg",
        "youtube", "zappos", "zip",
    ]

    /// 그 이름의 끝 마디가 HTTPS 전용 최상위 도메인이면 그 마디 (소문자). 아니면 nil. 마디가 하나뿐인 이름(`dev`)도 해당한다.
    public static func forcedSuffix(of host: String) -> String? {
        var name = host.trimmingCharacters(in: .whitespaces).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        guard let last = name.split(separator: ".").last.map(String.init), topLevel.contains(last) else { return nil }
        return last
    }

    /// 그 이름으로 연 평문 터널을 브라우저로 열려는 사람에게 줄 경고 한 줄. 해당 없으면 nil.
    public static func browserWarning(host: String) -> String? {
        forcedSuffix(of: host).map { ".\($0) 로 끝나는 이름은 브라우저가 HTTPS 로만 엽니다 — 웹 화면이면 localhost 로 여세요." }
    }
}
