// 브라우저 시작 페이지의 "웹인가" 확인 (2026-11-17): 열린 포트에 HTTP 로 한 번 물어 응답하면 웹, 그 페이지 제목(<title>)을 타일 이름으로 쓴다.
// 번호로 아는 비웹 포트(22 ssh · 5432 postgres …)는 묻지 않는다 — 그 서비스 로그에 잘못된 접속으로 남지 않게.
// 요청은 브라우저 탭과 같은 길로 간다: 앱 안 SOCKS 중계 → ssh -D → 서버 (루프백은 별칭으로 — BrowserPolicy.proxied).
// 판정·제목 뽑기는 순수 함수(테스트 대상), 요청은 URLSession (테스트는 이 Mac 의 가짜 서버로).
// 앱에서는 전송 보안(ATS)이 별칭 이름으로의 평문 HTTP 를 막는다(-1022) — Info.plist 의 server.localhost 예외가 풀어 준다.
// 테스트 실행기에는 ATS 가 없어 이 차이가 테스트에 안 잡힌다 (2026-11-17 설치 뒤 전부 "그 밖"으로 나와 발견).
// 제목이 있는 페이지(시작 페이지의 타일이 되는 것)는 아이콘도 받는다: <link rel="icon"> → 없으면 /favicon.ico, 같은 호스트·포트의 것만, 64KB 미만의 그림만.
// 받은 그림은 data: 주소로 시작 페이지에 심는다 — 페이지가 직접 받게 하면 루프백 주소는 이 Mac 으로 간다 (BrowserPolicy).

import Foundation
import Network

public struct WebProbeResult: Sendable, Equatable {
    /// 응답한 스킴 ("http" · "https") — 타일을 누르면 이 스킴으로 연다
    public let scheme: String
    public let title: String?
    /// 마지막 응답의 상태 코드 (같은 호스트·포트 안의 리다이렉트는 따라간 뒤). 응답은 못 받았지만 웹으로 본 경우(TLS 포트 추정)는 nil.
    public let status: Int?
    /// 페이지 아이콘 (data: 주소). 제목이 있는 페이지에서만 받는다. 없으면 nil.
    public let icon: String?
    public init(scheme: String, title: String?, status: Int? = nil, icon: String? = nil) {
        self.scheme = scheme; self.title = title; self.status = status; self.icon = icon
    }
}

public enum WebProbe {
    /// 번호로 아는 비웹 포트: 알려진 포트 중 이름에 http 가 없는 것 (ssh·dns·smb·mysql·postgres·redis·rdp·etcd …)
    public static let nonWebPorts: Set<Int> = Set(RemoteInfo.knownPorts.filter { !$0.value.contains("http") }.keys)

    /// 물어볼 포트인가: 서버 자신이 닿을 수 있고(tunnelAddress) 비웹으로 알려지지 않은 것
    public static func isCandidate(_ item: PortItem) -> Bool {
        item.tunnelAddress != nil && !nonWebPorts.contains(item.port)
    }

    /// https 를 먼저 물을 포트 (나머지는 http 먼저)
    static func schemes(for port: Int) -> [String] {
        [443, 8443].contains(port) ? ["https", "http"] : ["http", "https"]
    }

    /// HTML 의 <title>. 공백은 한 칸으로, 기본 엔티티만 풀고, 길면 자른다. 없거나 비면 nil.
    public static func title(inHTML html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title", options: .caseInsensitive, range: openEnd.upperBound..<html.endIndex) else { return nil }
        var text = String(html[openEnd.upperBound..<close.lowerBound])
        for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty { return nil }
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }

    /// 평문 HTTP 를 TLS 포트에 보냈을 때의 답인가 (nginx "The plain HTTP request was sent to HTTPS port" 등) — https 로 다시 묻는다
    static func isPlainToTLS(status: Int, body: String) -> Bool {
        status == 400 && body.range(of: "https", options: .caseInsensitive) != nil
    }

    /// 한 포트: 스킴 순서대로 물어 처음 HTTP 로 답한 것. 답이 없으면 nil. host 는 서버에서 본 주소 (localhost · 특정 IP).
    public static func probe(host: String, port: Int, proxyPort: Int, timeout: TimeInterval = 2.5) async -> WebProbeResult? {
        var fallback: WebProbeResult?
        for scheme in schemes(for: port) {
            guard let url = URL(string: "\(scheme)://\(host):\(port)/") else { continue }
            let page = BrowserPolicy.proxied(url)
            guard let answer = await fetch(page, proxyPort: proxyPort, timeout: timeout) else { continue }
            // http 로 물었는데 "TLS 포트"라는 답이면 https 를 마저 본다 (https 도 안 되면 이 답을 쓴다)
            if scheme == "http", isPlainToTLS(status: answer.status, body: answer.body) { fallback = WebProbeResult(scheme: "https", title: nil); continue }
            // 오류 응답(4xx·5xx)의 제목은 서비스 이름이 아니라 오류 문구("404 Not Found")라 쓰지 않는다 — 상태 코드가 말한다
            let title = answer.status < 400 ? title(inHTML: answer.body) : nil
            let icon = title == nil ? nil : await icon(inHTML: answer.body, page: answer.url ?? page, proxyPort: proxyPort, timeout: timeout)
            return WebProbeResult(scheme: scheme, title: title, status: answer.status, icon: icon)
        }
        return fallback
    }

    /// 여러 포트를 함께 묻는다. 답한 포트만 담긴다.
    public static func probeAll(_ targets: [(port: Int, host: String)], proxyPort: Int, timeout: TimeInterval = 2.5) async -> [Int: WebProbeResult] {
        await withTaskGroup(of: (Int, WebProbeResult?).self) { group in
            for target in targets {
                group.addTask { (target.port, await probe(host: target.host, port: target.port, proxyPort: proxyPort, timeout: timeout)) }
            }
            var out: [Int: WebProbeResult] = [:]
            for await (port, result) in group { if let result { out[port] = result } }
            return out
        }
    }

    // MARK: 아이콘

    /// 받을 크기의 끝 (본문·아이콘 공통). 아이콘이 여기에 닿으면 잘린 것이라 버린다.
    static let readLimit = 65536

    /// HTML 의 <link rel="icon" href="…"> (rel 에 icon 토큰이 있는 첫 번째 — "shortcut icon" 포함, apple-touch-icon·mask-icon 은 아님). 없으면 nil.
    public static func iconHref(inHTML html: String) -> String? {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: "([a-zA-Z][a-zA-Z-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))") else { return nil }
        let text = html as NSString
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            var found: [String: String] = [:]
            let inner = text.substring(with: tag.range) as NSString
            for match in attributes.matches(in: inner as String, range: NSRange(location: 0, length: inner.length)) {
                let value = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { inner.substring(with: $0) } ?? ""
                found[inner.substring(with: match.range(at: 1)).lowercased()] = value
            }
            guard let rel = found["rel"], rel.lowercased().split(whereSeparator: \.isWhitespace).contains("icon"),
                  let href = found["href"]?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "&amp;", with: "&"), !href.isEmpty else { continue }
            return href
        }
        return nil
    }

    /// 아이콘을 받을 주소들: 페이지가 적은 것(같은 호스트·포트일 때만 — 바깥 주소로는 묻지 않는다) 다음에 /favicon.ico
    static func iconURLs(href: String?, page: URL) -> [URL] {
        var out: [URL] = []
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        if let href, let resolved = URL(string: href, relativeTo: page)?.absoluteURL {
            let url = BrowserPolicy.proxied(resolved)
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased() == page.host?.lowercased(), port(url) == port(page) { out.append(url) }
        }
        if let root = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL, !out.contains(root) { out.append(root) }
        return out
    }

    /// 그림 바이트 → data: 주소. 종류는 머리 바이트로 정한다 (없는 favicon.ico 에 HTML 을 200 으로 주는 서버가 흔하다). 그림이 아니면 nil.
    public static func imageDataURI(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        let mime: String
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { mime = "image/png" }
        else if head.starts(with: [0x00, 0x00, 0x01, 0x00]) { mime = "image/x-icon" }
        else if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { mime = "image/gif" }
        else if head.starts(with: [0xFF, 0xD8, 0xFF]) { mime = "image/jpeg" }
        else if head.count == 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8...]) == [0x57, 0x45, 0x42, 0x50] { mime = "image/webp" }
        else if String(decoding: data.prefix(1024), as: UTF8.self).range(of: "<svg", options: .caseInsensitive) != nil { mime = "image/svg+xml" }
        else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// 그 페이지의 아이콘 (data: 주소). 페이지가 data: 로 적어 둔 것은 그대로, 아니면 받아 본다. 없거나 크거나 그림이 아니면 nil.
    static func icon(inHTML html: String, page: URL, proxyPort: Int, timeout: TimeInterval) async -> String? {
        let href = iconHref(inHTML: html)
        if let href, href.lowercased().hasPrefix("data:") {
            return href.lowercased().hasPrefix("data:image/") && href.utf8.count < readLimit * 2 ? href : nil
        }
        for url in iconURLs(href: href, page: page) {
            guard let answer = await fetch(url, proxyPort: proxyPort, timeout: timeout, accept: "image/*,*/*;q=0.5"),
                  answer.status == 200, answer.data.count < readLimit, let uri = imageDataURI(answer.data) else { continue }
            return uri
        }
        return nil
    }

    // MARK: 요청

    struct Answer {
        let status: Int
        /// 본문 앞부분 (readLimit 까지)
        let data: Data
        /// 리다이렉트를 따라간 뒤의 주소
        let url: URL?
        var body: String { String(decoding: data, as: UTF8.self) }
    }

    /// GET 한 번 (SOCKS 경유). 응답이 HTTP 면 상태와 본문 앞부분(64KB)을 돌려준다.
    static func fetch(_ url: URL, proxyPort: Int, timeout: TimeInterval, accept: String = "text/html,*/*;q=0.5") async -> Answer? {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxyPort)) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        let session = URLSession(configuration: configuration, delegate: ProbeDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= readLimit { break }
            }
            return Answer(status: http.statusCode, data: data, url: http.url)
        } catch {
            return nil
        }
    }

    /// 제목만 읽는 요청이라: 인증서는 따지지 않고(내부 서버는 사설 인증서가 흔하다), 다른 호스트·포트로의 리다이렉트는 따라가지 않는다
    private final class ProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        }

        /// bytes(for:) 는 서버 인증서 확인을 세션이 아니라 작업 쪽 콜백으로만 묻는다 — 이것이 없으면 https 가 전부 -1202 로 끝난다
        /// (별칭 이름으로 붙으므로 공인 인증서도 이름이 안 맞는다. 2026-11-17 docker 가짜 서버로 확인)
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            await urlSession(session, didReceive: challenge)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            guard let from = task.originalRequest?.url, let to = request.url, from.host == to.host, from.port == to.port, from.scheme == to.scheme else { return nil }
            return request
        }
    }
}
