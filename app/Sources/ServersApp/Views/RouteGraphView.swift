// 경로 그림 (this Mac 의 Routes 카드 · 서버 Network 탭): 뿌리(이 Mac·서버)에서 장치마다 한 갈래, 갈래 끝에 그 장치로 나가는 목적지. 표·목록을 대신하지 않고 곁에서 한눈에.
// 갈래·판정은 ServersCore RouteGraph — 여기는 그리기만. 인터넷이 타는 갈래는 초록, 주소를 넣으면 그 주소가 타는 갈래가 또렷해진다.

import ServersCore
import SwiftUI

struct RouteGraphView: View {
    let graph: RouteGraph
    /// 뿌리 마디 ("이 Mac" · 서버 이름)
    var root = "이 Mac"
    var rootImage = "laptopcomputer"
    /// 주소 → 타는 길. nil 이면 입력칸을 두지 않는다 (정책 라우팅이 있어 주소만으로 판정할 수 없는 서버)
    var lookup: ((String) -> RouteGraph.Hit?)?
    /// "이 주소는 어디로" 입력
    @State private var query = ""

    private static let rowHeight: CGFloat = 34

    /// 이 Mac 의 라우팅 표로
    init(table: RouteTable) {
        graph = RouteGraph(table)
        lookup = { RouteGraph.hit($0, in: table) }
    }

    /// 서버(리눅스·OpenWrt)의 경로로. excluding: 그리지 않을 장치 (컨테이너 배선)
    init(routing: OpenWrtRouting, root: String, details: [String: String], excluding: Set<String> = []) {
        graph = RouteGraph(routing: routing, details: details, excluding: excluding)
        self.root = root
        rootImage = "server.rack"
        lookup = RouteGraph.supportsLookup(routing) ? { RouteGraph.hit($0, in: routing) } : nil
    }

    var body: some View {
        let matched = lookup?(query)
        VStack(alignment: .leading, spacing: 10) {
            if lookup != nil { lookupField(matched) }
            HStack(alignment: .center, spacing: 0) {
                node(root, systemImage: rootImage, strong: true)
                connectors(matched)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(graph.lanes) { lane in row(lane, matched: matched) }
                }
            }
        }
        .fixedSize()
    }

    /// 주소 입력칸 + 결과 한 줄 ("→ utun6 · 10.1.0.0/24")
    private func lookupField(_ matched: RouteGraph.Hit?) -> some View {
        HStack(spacing: 8) {
            TextField("IP 로 경로 조회", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .frame(width: 170)
                .fieldSurface()
                .accessibilityLabel("경로를 확인할 IP")
            if let matched {
                Text(matched.text)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("맞는 경로가 없습니다").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// 그 갈래를 또렷하게 그릴 색. nil 이면 보통 선. 주소를 넣었으면 그 주소가 타는 갈래(무채색), 아니면 인터넷이 타는 갈래(초록)
    private func emphasis(_ lane: RouteGraph.Lane, _ matched: RouteGraph.Hit?) -> Color? {
        if let matched { return matched.devices.contains(lane.device) ? Color.primary.opacity(0.7) : nil }
        return lane.carriesInternet ? StatusTone.good.color.opacity(0.85) : nil
    }

    /// 뿌리에서 갈래까지의 선을 한 번에 그린다: 뿌리 → 줄기 → 둥글게 꺾어 갈래. 굵기는 모두 같고(1pt), 또렷한 갈래만 뿌리부터 끝까지 한 색으로 덧그린다.
    /// 갈래마다 선을 따로 그리면 줄기와 가지가 만나는 곳에서 굵기·색이 끊겨 보였다 (2026-11-10 사용자 지적).
    private func connectors(_ matched: RouteGraph.Hit?) -> some View {
        let lanes = graph.lanes
        let height = Self.rowHeight * CGFloat(lanes.count)
        return Canvas { context, size in
            let trunk: CGFloat = 12
            let origin = CGPoint(x: 0, y: size.height / 2)
            func path(to index: Int) -> Path {
                let y = Self.rowHeight * (CGFloat(index) + 0.5)
                var path = Path()
                path.move(to: origin)
                path.addLine(to: CGPoint(x: trunk, y: origin.y))
                if abs(y - origin.y) > 0.5 {
                    // 줄기에서 갈래로 꺾이는 모서리를 둥글게
                    let radius = min(6, abs(y - origin.y))
                    let direction: CGFloat = y > origin.y ? 1 : -1
                    path.addLine(to: CGPoint(x: trunk, y: y - direction * radius))
                    path.addQuadCurve(to: CGPoint(x: trunk + radius, y: y), control: CGPoint(x: trunk, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: y))
                return path
            }
            let style = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            for index in lanes.indices where emphasis(lanes[index], matched) == nil {
                context.stroke(path(to: index), with: .color(Color.secondary.opacity(0.35)), style: style)
            }
            for index in lanes.indices {
                if let color = emphasis(lanes[index], matched) { context.stroke(path(to: index), with: .color(color), style: style) }
            }
        }
        .frame(width: 28, height: height)
    }

    private func row(_ lane: RouteGraph.Lane, matched: RouteGraph.Hit?) -> some View {
        let color = emphasis(lane, matched)
        let dimmed = matched != nil && color == nil
        return HStack(spacing: 0) {
            node(lane.device, detail: lane.ip, strong: color != nil, border: color)
            // VPN 터널이면 타고 나가는 물리 장치를 경유 마디로 — 암호화한 패킷이 그 장치를 거쳐 나가는 순서 그대로 (2026-11-10)
            ForEach(lane.egress, id: \.self) { device in
                Rectangle().fill(color ?? Color.secondary.opacity(0.35)).frame(width: 14, height: 1)
                node(device, strong: false, border: color)
            }
            Rectangle().fill(color ?? Color.secondary.opacity(0.35)).frame(width: 14, height: 1)
            HStack(spacing: 5) {
                ForEach(lane.destinations) { destination in
                    chip(destination, hit: matched?.destinationID == destination.id)
                }
            }
        }
        .frame(height: Self.rowHeight)
        .opacity(dimmed ? 0.4 : 1)
    }

    /// 마디 (이 Mac · 장치): 조작부 면 + 선
    private func node(_ title: String, systemImage: String? = nil, detail: String? = nil, strong: Bool, border: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            Text(title).font(.system(size: 12, weight: strong ? .semibold : .medium))
            if let detail { Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
        }
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(border?.opacity(0.6) ?? (strong ? Color.primary.opacity(0.28) : Palette.hairline)))
    }

    /// 목적지: 인터넷 길은 초록 면, 대기 중인 default 는 흐리게, 대역은 우묵한 면
    private func chip(_ destination: RouteGraph.Destination, hit: Bool) -> some View {
        let internet = destination.role == .internet
        return HStack(spacing: 4) {
            if destination.text == "default" { Image(systemName: "globe").font(.system(size: 9.5)) }
            Text(destination.text == "default" ? (internet ? "인터넷" : "default · 대기") : destination.text)
                .font(.system(size: 11, weight: internet || hit ? .semibold : .regular)).monospacedDigit()
        }
        .lineLimit(1).fixedSize()   // 대역 글자는 줄이지 않는다 — 공인 대역("203.0.113.0/24")이 "…" 로 잘렸다 (2026-11-10 사용자 지적)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(internet ? StatusTone.good.color : (destination.role == .standby ? Color.secondary.opacity(0.7) : Color.primary.opacity(0.85)))
        .background(internet ? StatusTone.good.color.opacity(0.14) : Palette.well, in: Capsule())
        .overlay(Capsule().strokeBorder(hit ? Color.primary.opacity(0.6) : (internet ? Color.clear : Palette.hairline)))
    }

}
