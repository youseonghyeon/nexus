// 서버 추가 창의 [피어에서 고르기]: tailscale status --json 의 Peer 목록 (이 Mac 자신은 빼고). 접속은 하지 않는다 — 로컬 tailscaled 가 아는 값만.

import Foundation

public struct TailscalePeer: Sendable, Hashable {
    public let name: String
    /// TailscaleIPs 중 첫 IPv4
    public let ip: String
    /// linux · windows · macOS · iOS …
    public let os: String
    public let online: Bool

    public init(name: String, ip: String, os: String, online: Bool) {
        self.name = name; self.ip = ip; self.os = os; self.online = online
    }

    /// 종류 칸 값: Windows 피어만 windows, 나머지는 linux (셸·조회 방식)
    public var type: ServerType { os.lowercased() == "windows" ? .windows : .linux }

    /// servers.conf 키로 쓸 수 있게: 소문자, 영문·숫자·밑줄만, 영문으로 시작 ("DESKTOP-AB12" → "desktop_ab12", "3dprinter" → "s3dprinter")
    public var suggestedKey: String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("_") { out.append("_") }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if let first = out.first, !first.isLetter { out = "s" + out }
        return out
    }
}

public enum TailscalePeers {
    /// online 먼저, 그다음 이름순. IPv4 가 없거나 JSON 이 아니면 빈 목록.
    public static func parse(_ json: String) -> [TailscalePeer] {
        let peers = NetworkInfoFetcher.parseTailscaleStatus(json)?.peers ?? []
        let list: [TailscalePeer] = peers.compactMap { peer in
            guard let ip = peer.ips.first(where: { $0.contains(".") }) else { return nil }
            let host = peer.hostName.isEmpty ? nil : peer.hostName
            let dns = peer.dnsName.split(separator: ".").first.map(String.init)
            guard let name = host ?? dns else { return nil }
            return TailscalePeer(name: name, ip: ip, os: peer.os, online: peer.online)
        }
        return list.sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
    }
}
