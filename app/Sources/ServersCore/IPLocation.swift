// 진단 경로 [주소 검색]: 경로의 공인 IP 홉 위치를 ip-api.com batch 로 한 번에 묻는다 (키 없음, 무료는 HTTP 만 · batch 는 분당 15회).
// 사설·CGNAT·루프백·링크 로컬 홉과 응답 없는 홉(*)은 묻지 않는다. 위치는 DB 추정이라 등록지(본사 주소)로 나올 수 있다.
// 우편번호·좌표는 받지 않는다 — 추정치인데 정확해 보이기만 한다. 응답 모양 (2026-10-15 이 Mac):
//   [{"status":"success","countryCode":"KR","regionName":"Seoul","city":"Jung-gu","isp":"Korea Telecom","org":"KORNET","as":"AS4766 Korea Telecom","query":"198.51.100.185"},
//    {"status":"fail","message":"private range","query":"192.168.0.1"}]

import Foundation

public struct IPLocation: Sendable, Equatable, Decodable {
    public var countryCode: String?
    /// 시·도 ("Seoul")
    public var regionName: String?
    public var city: String?
    public var isp: String?
    /// 그 대역을 쓰는 조직 ("KORNET")
    public var org: String?
    /// "AS4766 Korea Telecom"
    public var `as`: String?

    public init(countryCode: String? = nil, regionName: String? = nil, city: String? = nil, isp: String? = nil, org: String? = nil, as asName: String? = nil) {
        self.countryCode = countryCode; self.regionName = regionName; self.city = city; self.isp = isp; self.org = org; self.as = asName
    }

    /// "Jung-gu, Seoul, KR · AS4766 Korea Telecom · KORNET" — AS 가 없으면 ISP.
    /// 시·도가 도시와 같으면("Seoul, Seoul") 한 번, org 가 AS·ISP 이름에 이미 들어 있으면 뺀다
    public var text: String {
        let value = { (v: String?) in v?.isEmpty == false ? v : nil }
        var place = [value(city)].compactMap { $0 }
        if let region = value(regionName), region.lowercased() != value(city)?.lowercased() { place.append(region) }
        if let country = value(countryCode) { place.append(country) }
        let network = value(`as`) ?? value(isp)
        let known = [`as`, isp].compactMap { $0?.lowercased() }
        let organization = value(org).flatMap { org in known.contains { $0.contains(org.lowercased()) } ? nil : org }
        return [place.isEmpty ? nil : place.joined(separator: ", "), network, organization].compactMap { $0 }.joined(separator: " · ")
    }
}

public enum IPLocate {
    static let url = "http://ip-api.com/batch?fields=status,message,countryCode,regionName,city,isp,org,as,query"

    /// 공인 IPv4 인가 — 사설(10/8 · 172.16/12 · 192.168/16)·CGNAT(100.64/10)·루프백·링크 로컬·0/8·멀티캐스트 이상은 아니다
    public static func isPublic(_ ip: String) -> Bool {
        // 형식 검사는 IPv4.parse 하나로 — 칸을 걸러 낸 뒤 세면 "1.2.x.3.4" 가 네 칸으로 통과했다
        guard let value = IPv4.parse(ip) else { return false }
        let (a, b) = (UInt8(value >> 24), UInt8((value >> 16) & 0xFF))
        switch a {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(b): return false
        case 169 where b == 254: return false
        case 172 where (16...31).contains(b): return false
        case 192 where b == 168: return false
        case 224...255: return false
        default: return true
        }
    }

    /// 물어볼 홉 주소 — 공인 IP 만, 같은 주소는 한 번
    public static func targets(_ hops: [TraceHop]) -> [String] {
        var seen = Set<String>()
        return hops.compactMap(\.address).filter { isPublic($0) && seen.insert($0).inserted }
    }

    /// batch 응답 → IP → 위치 (status 가 success 인 것만). 읽지 못하면 nil
    public static func parseBatch(_ json: String) -> [String: IPLocation]? {
        struct Row: Decodable {
            let status: String
            let query: String
            let countryCode: String?, regionName: String?, city: String?, isp: String?, org: String?, `as`: String?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(json.utf8)) else { return nil }
        var result: [String: IPLocation] = [:]
        for row in rows where row.status == "success" {
            result[row.query] = IPLocation(countryCode: row.countryCode, regionName: row.regionName, city: row.city, isp: row.isp, org: row.org, as: row.as)
        }
        return result
    }

    static let selfURL = "http://ip-api.com/json/?fields=status,message,countryCode,regionName,city,isp,org,as,query"

    /// 주소 없이 물으면 묻는 쪽의 공인 IP 와 그 위치를 한 번에 준다 (query = 내 공인 IP). 읽지 못하거나 status 가 success 가 아니면 nil
    public static func parseSelf(_ json: String) -> (ip: String, location: IPLocation)? {
        struct Row: Decodable {
            let status: String
            let query: String?
            let countryCode: String?, regionName: String?, city: String?, isp: String?, org: String?, `as`: String?
        }
        guard let row = try? JSONDecoder().decode(Row.self, from: Data(json.utf8)), row.status == "success",
              let ip = row.query, IPv4.parse(ip) != nil else { return nil }
        return (ip, IPLocation(countryCode: row.countryCode, regionName: row.regionName, city: row.city, isp: row.isp, org: row.org, as: row.as))
    }

    /// 그 장치로만 나가 본 공인 IP 와 위치 (VPN 화면 — 그 VPN 으로 나가면 바깥에서 보이는 주소). 요청 한 번, 막힌 망이면 2초 안에 연결을 포기하고 길어야 4초
    public static func selfLookup(device: String?, runner: any CommandRunner) async -> (ip: String, location: IPLocation)? {
        guard let bind = NetworkProbe.bindArguments(device, flag: "--interface") else { return nil }
        let result = await runner.run("curl", ["-4", "-fsS", "--connect-timeout", "2", "--max-time", "4"] + bind + [selfURL], timeout: 10)
        guard result.ok else { return nil }
        return parseSelf(result.stdout)
    }

    /// 요청 한 번 (그 화면 장치로, 5초). 실패면 nil
    public static func lookup(_ ips: [String], device: String?, runner: any CommandRunner) async -> [String: IPLocation]? {
        guard !ips.isEmpty, let bind = NetworkProbe.bindArguments(device, flag: "--interface"),
              let body = try? JSONEncoder().encode(ips), let text = String(data: body, encoding: .utf8) else { return nil }
        let result = await runner.run("curl", ["-fsS", "-m", "5", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@-"] + bind + [url],
                                      stdin: text, timeout: 10)
        guard result.ok else { return nil }
        return parseBatch(result.stdout)
    }
}
