// 앱 안 브라우저 탭의 시작 페이지 (2026-11-17 시안 D → 2026-11-19 시안 A): 대표 카드(서버·태그·상태 · 주소칸 · 아래 띠에 웹/제목 없는 응답/그 밖 수)
// + 카드로 묶은 즐겨찾기 타일(BookmarkStore) · 웹 타일 · 제목 없는 응답 칩 | 그 밖 표. 다크 모드에서 배경 그림을 주면 그 위에 반투명 카드 (background).
// 서버에 띄우는 것이 아니라 앱이 그려 탭에 넣는다. 타일을 누르면 그 탭에서 서버 쪽 주소(localhost:<포트>)로 연다 — 탭은 그 서버에서 켠 브라우저처럼 동작한다 (BrowserPolicy).
// 포트 목록은 서버 화면 Ports 탭과 같은 값(PortItem). "웹" 타일은 화면이 있는 것 — 제목이 있는 응답(WebProbe).
// HTTP 로 답했지만 제목이 없는 포트(API·리다이렉트·오류)는 칩 한 줄, 답이 없는 포트는 "그 밖".
// 타일은 아이콘(24) | 제목 · 아랫줄(포트 · https · 상태 코드). 주소는 적지 않는다 — 포트가 이미 말하고 거의 다 127.0.0.1 이라 중복이었다 (특정 주소에 묶인 포트만 그 주소).
// 이 파일은 나누기와 HTML 만들기만 (순수 함수, 테스트 대상).

import Foundation

public enum BrowserStartPage {
    public enum PortsState: Sendable, Equatable {
        case loading
        case loaded([PortItem])
        /// 못 읽음 (인증 필요·접속 실패)
        case failed
    }

    /// 대표 카드에 보일 것 (상태 문구·수준은 본창과 같은 판정 — StatusText)
    public struct Hero: Sendable, Equatable {
        public let key: String
        public let target: String
        public let role: String?
        public let tags: [String]
        public let status: String
        public let level: StatusLevel
        public init(key: String, target: String, role: String?, tags: [String], status: String, level: StatusLevel) {
            self.key = key; self.target = target; self.role = role; self.tags = tags; self.status = status; self.level = level
        }
    }

    public struct Tile: Sendable, Equatable {
        public let port: Int
        /// 큰 글씨: 페이지 제목
        public let title: String
        public let url: String
        /// 웹 확인이 받은 상태 코드 — 2xx 가 아닐 때만 보인다 (badge)
        public var status: Int? = nil
        /// 페이지 아이콘 (data: 주소). 없으면 무채색 자리 그림
        public var icon: String? = nil
        /// 특정 주소에만 묶인 포트의 그 주소 (localhost·127.0.0.1 이면 빈 문자열 — 적지 않는다)
        public var address: String = ""

        public var badge: (text: String, warn: Bool)? { BrowserStartPage.badge(status) }
        public var isHTTPS: Bool { url.hasPrefix("https://") }
    }

    /// HTTP 로 답했지만 제목이 없는 포트 (또는 아직 묻는 중인 포트) — 칩 한 줄
    public struct Chip: Sendable, Equatable {
        public let port: Int
        /// 알려진 서비스 이름 (http · https-alt …), 없으면 빈 문자열
        public let label: String
        public let url: String
        public var status: Int? = nil

        public var badge: (text: String, warn: Bool)? { BrowserStartPage.badge(status) }
        public var isHTTPS: Bool { url.hasPrefix("https://") }
    }

    /// 상태 코드 표시: 2xx·모름은 없음, 5xx 만 경고색 (301 다른 주소로 넘김 · 401 인증 필요 · 404 루트 없음 · 502 뒤쪽 서비스 죽음을 가르는 정보)
    static func badge(_ status: Int?) -> (text: String, warn: Bool)? {
        guard let status, !(200..<300).contains(status) else { return nil }
        return (String(status), status >= 500)
    }

    public struct Other: Sendable, Equatable {
        public let port: Int
        public let label: String
        public let addresses: String
    }

    /// 웹 타일 · 제목 없는 응답 칩 · 그 밖 목록으로 나눈다.
    ///   물어볼 포트(WebProbe.isCandidate): 제목과 함께 답했으면 타일, 제목 없이 답했거나 아직 묻는 중이면 칩, 다 물었는데 답이 없으면 그 밖.
    ///   번호로 아는 비웹 포트와 서버 자신도 닿지 못하는 대기는 그 밖.
    public static func sections(ports: [PortItem], probes: [Int: WebProbeResult], probed: Bool) -> (web: [Tile], bare: [Chip], other: [Other]) {
        var seen: Set<Int> = []
        var web: [Tile] = [], bare: [Chip] = [], other: [Other] = []
        func host(_ item: PortItem?) -> String { item.flatMap(host(for:)) ?? "localhost" }
        func url(_ port: Int, _ item: PortItem?) -> String { "\(probes[port]?.scheme ?? "http")://\(host(item)):\(port)/" }
        func address(_ item: PortItem?) -> String { ["localhost", "127.0.0.1"].contains(host(item)) ? "" : host(item) }
        for item in ports.sorted(by: { $0.port < $1.port }) where seen.insert(item.port).inserted {
            if WebProbe.isCandidate(item), let result = probes[item.port] {
                if let title = result.title {
                    web.append(Tile(port: item.port, title: title, url: url(item.port, item), status: result.status, icon: result.icon, address: address(item)))
                } else {
                    bare.append(Chip(port: item.port, label: item.label ?? "", url: url(item.port, item), status: result.status))
                }
            } else if WebProbe.isCandidate(item), !probed {
                bare.append(Chip(port: item.port, label: item.label ?? "", url: url(item.port, item)))
            } else {
                other.append(Other(port: item.port, label: [item.label, item.process].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                   addresses: item.addressText))
            }
        }
        return (web, bare, other)
    }

    /// 서버에서 본 호스트: 모든 주소 대기면 localhost, 특정 주소에만 묶였으면 그 주소 (IPv6 는 대괄호). 닿을 주소가 없으면 nil.
    public static func host(for item: PortItem) -> String? {
        guard let address = item.tunnelAddress else { return nil }
        return address == "*" ? "localhost" : (address.contains(":") ? "[\(address)]" : address)
    }

    /// 물어볼 대상 (WebProbe.probeAll 에 넘긴다)
    public static func probeTargets(ports: [PortItem]) -> [(port: Int, host: String)] {
        var seen: Set<Int> = []
        var out: [(port: Int, host: String)] = []
        for item in ports where WebProbe.isCandidate(item) && seen.insert(item.port).inserted { out.append((item.port, host(for: item) ?? "localhost")) }
        return out
    }

    /// 포트 부분 (<div id="ports"> 안) — 포트 목록·확인 결과가 올 때마다 이 부분만 갈아 끼운다 (주소칸에 치던 글자가 지워지지 않게)
    public static func portsHTML(state: PortsState, probes: [Int: WebProbeResult], probed: Bool) -> String {
        let ports: [PortItem]
        if case let .loaded(items) = state { ports = items } else { ports = [] }
        let (web, bare, other) = sections(ports: ports, probes: probes, probed: probed)
        func marks(https: Bool, badge: (text: String, warn: Bool)?) -> String {
            (https ? "<span class=\"k\">https</span>" : "") + (badge.map { "<span class=\"s\($0.warn ? " warn" : "")\">\($0.text)</span>" } ?? "")
        }
        // 대표 카드 아래 띠의 수 — 포트 부분과 함께 오고, 페이지 스크립트가 띠 자리(#band)로 옮긴다
        let counted: Bool
        if case .loaded = state { counted = true } else { counted = false }
        func metric(_ label: String, _ count: Int) -> String {
            "<div class=\"m\"><div class=\"l\">\(label)</div><div class=\"v\">\(counted ? String(count) : "—")</div></div>"
        }
        var out = "<div class=\"band\">" + metric("웹", web.count) + metric(probed ? "제목 없는 응답" : "확인 중", bare.count) + metric("그 밖", other.count) + "</div>"
        if !web.isEmpty {
            out += "<section class=\"card sec\"><h2>웹</h2><div class=\"grid\">" + web.map { tile in
                let icon = tile.icon.map { "<img class=\"i\" src=\"\(escape($0))\" alt=\"\">" } ?? placeholderIcon
                let extra = tile.address.isEmpty ? "" : "<span class=\"e\">\(escape(tile.address))</span>"
                return "<a class=\"tile\" href=\"\(escape(tile.url))\">\(icon)<div class=\"x\"><div class=\"t\">\(escape(tile.title))</div>"
                    + "<div class=\"b\"><span class=\"n\">\(tile.port)</span>\(extra)\(marks(https: tile.isHTTPS, badge: tile.badge))</div></div></a>"
            }.joined() + "</div></section>"
        }
        var lower: [String] = []
        if !bare.isEmpty {
            // 다 묻기 전에는 아직 어느 쪽인지 모른다 — 답이 오면 타일·칩·그 밖으로 갈린다
            lower.append("<section class=\"card sec\"><h2>\(probed ? "제목 없는 응답" : "확인 중…")</h2><div class=\"chips\">" + bare.map { chip in
                "<a class=\"chip\" href=\"\(escape(chip.url))\"><span class=\"n\">\(chip.port)</span>"
                    + (chip.label.isEmpty ? "" : "<em>\(escape(chip.label))</em>") + marks(https: chip.isHTTPS, badge: chip.badge) + "</a>"
            }.joined() + "</div></section>")
        }
        if !other.isEmpty {
            lower.append("<section class=\"card sec\"><h2>그 밖</h2><div class=\"others\"><div class=\"o hd\"><span class=\"n\">Port</span><span>Service</span><span class=\"a\">Address</span></div>"
                + other.map { row in
                    "<div class=\"o\"><span class=\"n\">\(row.port)</span><span>\(escape(row.label))</span><span class=\"a\">\(escape(row.addresses))</span></div>"
                }.joined() + "</div></section>")
        }
        // 칩과 그 밖이 둘 다 있으면 나란히 (좁은 폭에서는 위아래)
        out += lower.count == 2 ? "<div class=\"pair\">" + lower.joined() + "</div>" : lower.joined()
        switch state {
        case .loading: out += "<p class=\"note\">열린 포트를 읽는 중…</p>"
        case .failed: out += "<p class=\"note\">열린 포트를 읽지 못했습니다. ↻ 로 다시 읽습니다.</p>"
        case .loaded: if web.isEmpty && bare.isEmpty && other.isEmpty { out += "<p class=\"note\">열려 있는 포트가 없습니다.</p>" }
        }
        return out
    }

    /// 즐겨찾기 부분 (<div id="marks"> 안) — 넣고 뺄 때마다 이 부분만 갈아 끼운다. 없으면 빈 문자열(줄 자체가 없다).
    /// 타일은 웹 타일과 같은 꼴(아이콘 · 제목 · 아랫줄에 짧은 주소), 마우스를 올리면 ✕ — 누르면 앱에 알린다 (script 의 messageHandlers.nexus).
    public static func bookmarksHTML(_ marks: [BrowserBookmark]) -> String {
        let usable = marks.filter { BookmarkStore.isBookmarkable($0.url) }
        guard !usable.isEmpty else { return "" }
        return "<h2>즐겨찾기</h2><div class=\"grid\">" + usable.map { mark in
            let icon = mark.icon.map { "<img class=\"i\" src=\"\(escape($0))\" alt=\"\">" } ?? placeholderIcon
            return "<a class=\"tile\" href=\"\(escape(mark.url))\">\(icon)<div class=\"x\"><div class=\"t\">\(escape(mark.title))</div>"
                + "<div class=\"b\"><span class=\"u\">\(escape(BookmarkStore.shortAddress(mark.url)))</span></div></div>"
                + "<button class=\"rm\" data-u=\"\(escape(mark.url))\" title=\"즐겨찾기에서 빼기\">✕</button></a>"
        }.joined() + "</div>"
    }

    /// 아이콘이 없는 타일의 자리 그림 (무채색 지구본) — 비워 두면 그 타일만 글자 시작 위치가 어긋난다
    static let placeholderIcon = "<svg class=\"i ph\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.1\"><circle cx=\"8\" cy=\"8\" r=\"4.6\"/>"
        + "<path d=\"M3.4 8h9.2M8 3.4c-1.8 1.4-1.8 7.8 0 9.2M8 3.4c1.8 1.4 1.8 7.8 0 9.2\"/></svg>"

    /// background: 다크 모드에서 깔 배경 그림 (data: 주소 — 시작 페이지는 baseURL 없이 그려 파일 주소를 못 읽는다). nil 이면 무채색 바탕.
    /// 라이트 모드는 늘 무채색 바탕 (배경 그림은 어두운 것 하나뿐이다).
    public static func html(hero: Hero, bookmarksHTML: String = "", portsHTML: String, background: String? = nil) -> String {
        let tags = hero.tags.map { tag -> String in
            let tone: String
            switch ServerTags.tone(tag) { case .production: tone = " prod"; case .staging: tone = " stg"; case .plain: tone = "" }
            return "<span class=\"tag\(tone)\">\(escape(tag))</span>"
        }.joined()
        let level: String
        switch hero.level { case .good: level = "good"; case .warn: level = "warn"; case .bad: level = "bad"; case .muted: level = "muted" }
        let subtitle = ([escape(hero.target)] + (hero.role.map { [escape($0)] } ?? [])).joined(separator: " · ")
        // 배경 그림은 data: 주소만 받는다 — url( ) 안에서 끊기거나 다른 주소를 부르지 못하게
        let wall = background.flatMap { $0.hasPrefix("data:image/") && !$0.contains(where: { "()'\"\\ \n".contains($0) }) ? $0 : nil }
        let wallCSS = wall.map { """
            @media(prefers-color-scheme:dark){
              body.wall{background:#07080C url(\($0)) center/cover fixed no-repeat}
              body.wall .card,body.wall #marks:not(:empty){background:rgba(18,19,23,.55);-webkit-backdrop-filter:blur(30px) saturate(1.5);border-color:rgba(255,255,255,.14)}
              body.wall .tile,body.wall .chip,body.wall .box{background:rgba(255,255,255,.07)}
              body.wall .i.ph{background:rgba(255,255,255,.08)}
              body.wall h2{color:rgba(255,255,255,.78)}
            }
            """ } ?? ""
        return """
        <!doctype html><html lang="ko"><meta charset="utf-8"><title>\(escape(hero.key))</title>
        <style>
        :root{--bg:#F4F4F2;--card:#FFFFFF;--raised:#F7F7F5;--well:#ECECEA;--line:rgba(0,0,0,.09);--text:#1d1d1f;--dim:rgba(0,0,0,.5);--faint:rgba(0,0,0,.34);
          --good:#1F9D57;--warn:#B8730A;--bad:#D63F36;--stg:#2F6FD0}
        @media(prefers-color-scheme:dark){:root{--bg:#141517;--card:#1B1C1F;--raised:#222327;--well:#27282C;--line:rgba(255,255,255,.08);--text:#ECECEE;--dim:rgba(255,255,255,.5);--faint:rgba(255,255,255,.32);
          --good:#3FD68A;--warn:#F2BE4A;--bad:#FF6B60;--stg:#5B9BF0}}
        *{box-sizing:border-box}
        body{margin:0;min-height:100vh;background:var(--bg);color:var(--text);font:13px -apple-system,system-ui;-webkit-font-smoothing:antialiased}
        main{max-width:860px;margin:0 auto;padding:32px 24px 48px}
        .card,#marks:not(:empty){background:var(--card);border:1px solid var(--line);border-radius:14px;margin-bottom:12px}
        .hero{overflow:hidden}
        .top{display:flex;align-items:flex-start;padding:20px 22px 16px}
        .hero h1{font-size:26px;font-weight:700;letter-spacing:-.4px;margin:0;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
        .sub{font:12px ui-monospace,Menlo,monospace;color:var(--dim);margin-top:6px}
        .right{margin-left:auto;padding-left:16px;white-space:nowrap}
        .tag{font:700 9.5px -apple-system;letter-spacing:.3px;padding:2px 6px;border-radius:4px;background:var(--well);color:var(--text)}
        .tag.prod{background:var(--bad);color:#fff}.tag.stg{background:var(--stg);color:#fff}
        .pill{display:inline-flex;align-items:center;gap:6px;font-weight:600;font-size:12px;padding:4px 10px;border-radius:999px;background:var(--well);color:var(--dim)}
        .pill i{width:7px;height:7px;border-radius:50%;background:currentColor;display:inline-block}
        .pill.good{color:var(--good)}.pill.warn{color:var(--warn)}.pill.bad{color:var(--bad)}
        form{margin:0;padding:0 22px 18px}
        .box{display:flex;gap:10px;align-items:center;background:var(--raised);border:1px solid var(--line);border-radius:10px;padding:0 14px;color:var(--faint)}
        .box input{flex:1;border:0;outline:0;background:transparent;color:var(--text);font:14px ui-monospace,Menlo,monospace;padding:11px 0}
        .box input::placeholder{color:var(--faint)}
        #band:empty{display:none}
        #band{display:grid;grid-template-columns:repeat(3,1fr);border-top:1px solid var(--line)}
        .m{padding:12px 22px;border-left:1px solid var(--line);min-width:0}.m:first-child{border-left:0}
        .m .l{font-size:11px;color:var(--dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.m .v{font-size:20px;font-weight:700;margin-top:3px;letter-spacing:-.3px}
        #ports>.band{display:none}
        .sec,#marks:not(:empty){padding:14px 16px 16px}
        h2{font-size:11px;font-weight:700;color:var(--dim);margin:0 0 12px}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:8px}
        .tile{position:relative;display:flex;align-items:center;gap:12px;background:var(--raised);border:1px solid var(--line);border-radius:10px;padding:10px 12px;color:inherit;text-decoration:none;min-width:0}
        .tile:hover,.chip:hover{background:color-mix(in srgb,var(--raised),var(--text) 5%)}
        .i{width:24px;height:24px;border-radius:5px;flex:none;object-fit:contain}
        .i.ph{background:var(--well);color:var(--faint);padding:4px}
        .x{min-width:0;flex:1}
        .tile .t{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .tile .b{display:flex;gap:6px;align-items:center;margin-top:4px;color:var(--dim);min-width:0}
        .n{font:600 12px ui-monospace,Menlo,monospace}
        .tile .e{font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
        .tile .e::before{content:"· ";color:var(--faint)}
        .k{font:600 9.5px ui-monospace,Menlo,monospace;color:var(--dim);border:1px solid var(--line);border-radius:4px;padding:1px 4px;flex:none}
        .s{font:600 11px ui-monospace,Menlo,monospace;color:var(--dim);flex:none}.s.warn{color:var(--warn)}
        .tile .s{margin-left:auto}
        .tile .u{font:11.5px ui-monospace,Menlo,monospace;color:var(--faint);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
        .rm{position:absolute;top:7px;right:7px;width:20px;height:20px;border:0;border-radius:6px;background:var(--well);color:var(--dim);font-size:10px;line-height:20px;padding:0;cursor:pointer;opacity:0}
        .tile:hover .rm{opacity:1}.rm:hover{color:var(--text)}
        .chips{display:flex;flex-wrap:wrap;gap:6px}
        .chip{display:flex;gap:7px;align-items:center;background:var(--raised);border:1px solid var(--line);border-radius:6px;padding:5px 9px;color:inherit;text-decoration:none}
        .chip em{font-style:normal;font-size:12px;color:var(--dim)}
        .pair{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}.pair .card{margin-bottom:0}
        @media(max-width:700px){.pair{grid-template-columns:1fr}}
        .o{display:flex;gap:14px;padding:9px 0;border-top:1px solid var(--line);color:var(--dim)}
        .o.hd{border-top:0;padding-top:0;font-size:11px;font-weight:600;color:var(--faint)}.o.hd .n{font:inherit;color:inherit}
        .o.hd+.o{border-top:1px solid var(--line)}
        .o .n{min-width:48px;color:var(--text)}.o .a{margin-left:auto;text-align:right}
        .note{color:var(--dim);margin:0 4px}
        \(wallCSS)
        </style>
        <body\(wall == nil ? "" : " class=\"wall\"")>
        <main>
        <div class="card hero"><div class="top"><div><h1>\(escape(hero.key)) \(tags)</h1><div class="sub">\(subtitle)</div></div>
        <div class="right"><span class="pill \(level)"><i></i>\(escape(hero.status))</span></div></div>
        <form onsubmit="return go()"><label class="box"><svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14"/></svg>
        <input id="q" placeholder="주소 또는 포트 번호" autocomplete="off" autocapitalize="off" spellcheck="false" autofocus></label></form>
        <div id="band"></div></div>
        <div id="marks">\(bookmarksHTML)</div>
        <div id="ports">\(portsHTML)</div>
        </main>
        <script>
        function go(){var v=document.getElementById('q').value.trim();if(!v)return false;
          if(/^[0-9]{1,5}$/.test(v))v='http://localhost:'+v+'/';else if(!/^[a-z][a-z0-9+.-]*:\\/\\//i.test(v))v='http://'+v;
          location.href=v;return false}
        document.addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('.rm');if(!b)return;e.preventDefault();e.stopPropagation();
          try{window.webkit.messageHandlers.nexus.postMessage({remove:b.dataset.u})}catch(_){}} ,true);
        // 포트 부분이 들고 온 수(.band)를 대표 카드 아래 띠로 — 포트 부분은 앱이 통째로 갈아 끼운다
        (function(){var p=document.getElementById('ports'),d=document.getElementById('band');
          function sync(){var s=p.querySelector(':scope>.band');if(s)d.innerHTML=s.innerHTML}
          sync();new MutationObserver(sync).observe(p,{childList:true})})();
        </script></body></html>
        """
    }

    static func escape(_ s: some StringProtocol) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
