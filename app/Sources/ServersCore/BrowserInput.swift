// 브라우저 탭에 친 글자 → 열 주소 (위쪽 주소창 · 시작 페이지 입력칸이 같이 쓴다, 2026-11-19).
// 주소로 보이면 그 주소, 아니면 Google 검색. 숫자만이면 그 서버의 localhost:<포트>.
//   ://  가 있음 → 그대로 (http·https 만)        띄어쓰기 → 검색        ? 로 시작 → 그 뒤를 검색
//   호스트:포트 · IP · localhost · [IPv6] → 주소   점이 있고 끝 이름이 글자 2자 이상(도메인 꼴) → 주소
//   점 없는 한 단어는 검색 — 서버 안쪽 이름(docker 서비스·hosts)은 끝에 / 를 붙이면 주소 (jenkins/)
// 검색도 탭의 다른 요청처럼 그 서버를 거쳐 나간다 (BrowserPolicy).

import Foundation

public enum BrowserInput {
    public static func resolve(_ text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.hasPrefix("?") { return search(String(input.dropFirst())) }
        if let port = Int(input), input.allSatisfy(\.isASCII), input.count <= 5, (1...65535).contains(port) {
            return URL(string: "http://localhost:\(port)/")
        }
        if input.contains(where: \.isWhitespace) { return search(input) }
        if input.contains("://") {
            guard let url = URL(string: input), BrowserPolicy.isWeb(url), url.host?.isEmpty == false else { return search(input) }
            return url
        }
        if input.lowercased() == "about:blank" { return URL(string: "about:blank") }
        return looksLikeAddress(input) ? URL(string: "http://" + input) : search(input)
    }

    /// Google 검색 주소. + · & · = 같은 글자도 검색어 그대로 가게 직접 인코딩한다 (URLComponents 는 + 를 그대로 둬 공백이 된다)
    public static func search(_ query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.google.com/search?q=" + encoded)
    }

    /// 띄어쓰기 없고 :// 없는 글자가 주소 꼴인가
    static func looksLikeAddress(_ input: String) -> Bool {
        // 호스트 부분: / ? # 앞까지
        let head = input.prefix { !"/?#".contains($0) }
        let trailingPath = head.count < input.count
        var host = String(head)
        if host.hasPrefix("[") { return host.contains("]") && URL(string: "http://" + input)?.host != nil }   // [IPv6]
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber), let n = Int(port), (1...65535).contains(n) else { return false }
            host = String(host[..<colon])
            guard !host.isEmpty else { return false }
            return URL(string: "http://" + input)?.host != nil   // 호스트:포트 — 점이 없어도 주소 (db:5432)
        }
        guard !host.isEmpty, URL(string: "http://" + input)?.host != nil else { return false }
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") { return true }
        if isIPv4(lower) { return true }
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let last = labels.last, last.count >= 2, last.allSatisfy(\.isLetter) { return true }
        // 점 없는 한 단어: 끝에 / 가 있으면 주소 (서버 안쪽 이름)
        return labels.count == 1 && trailingPath && input.dropFirst(head.count).hasPrefix("/")
    }

    static func isIPv4(_ s: String) -> Bool {
        IPv4.isDotted(s)
    }
}
