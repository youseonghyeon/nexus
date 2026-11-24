// 앱 안 브라우저 탭의 오류 페이지와 내려받기 이름. 탭(BrowserSession)이 실패한 주소에 띄우는 HTML — 오류 코드 → 제목·설명, 글자 이스케이프.
// 이 파일은 문구와 HTML 만들기만 (순수 함수, 테스트 대상). 어느 오류에 띄우지 않는지(취소 · 다운로드로 돌린 이동)는 탭이 가른다.

import Foundation

public enum BrowserErrorPage {
    /// URL 오류 코드(NSURLError…) → 제목 · 설명. 모르는 코드는 시스템 설명(fallback)을 그대로
    public static func message(code: Int, fallback: String) -> (title: String, detail: String) {
        switch code {
        case NSURLErrorCannotConnectToHost: return ("연결할 수 없습니다", "이 주소에서 응답하는 서버가 없습니다.")
        case NSURLErrorTimedOut: return ("응답이 없습니다", "서버가 제한 시간 안에 응답하지 않았습니다.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return ("주소를 찾을 수 없습니다", "서버 이름을 확인하세요.")
        case NSURLErrorNetworkConnectionLost: return ("연결이 끊어졌습니다", "페이지를 불러오는 중 연결이 끊어졌습니다.")
        default: return ("페이지를 열 수 없습니다", fallback)
        }
    }

    /// 오류 페이지. target: 주소창에 보이는 꼴의 실패한 주소 (없으면 빈 글)
    public static func html(title: String, detail: String, target: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:14px -apple-system,system-ui;color:#333;background:#fafafa;margin:0;display:flex;height:100vh;align-items:center;justify-content:center}
        @media(prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}} .box{max-width:560px;padding:24px} h1{font-size:17px;margin:0 0 6px}
        p{margin:0 0 14px;opacity:.85} code{font:12px ui-monospace,Menlo;word-break:break-all;opacity:.7}</style>
        <div class="box"><h1>\(escape(title))</h1><p>\(escape(detail))</p><code>\(escape(target))</code></div>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

public enum BrowserDownload {
    /// 내려받을 자리: 폴더에 제안된 이름 그대로, 같은 이름이 있으면 " (2)" · " (3)" 식으로 비킨다 (확장자 앞에). exists: 그 자리에 이미 파일이 있는가
    public static func destination(in directory: URL, suggested: String, exists: (URL) -> Bool) -> URL {
        var target = directory.appendingPathComponent(suggested)
        let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
        var n = 2
        while exists(target) {
            target = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return target
    }
}
