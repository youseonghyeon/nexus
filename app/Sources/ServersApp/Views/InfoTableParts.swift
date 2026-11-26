// 원격 정보 탭(OpenWrtViews · LinuxInfoViews · ServicesView)이 같이 쓰는 표 부품:
// 원문 출력(RawLines) · 구역 제목(infoSection) · 한 줄(OpenWrtRow) · 행 면(tableRowSurface) · 접기 버튼(FoldButton) · 같이 쓰는 열 폭(InfoColumn) ·
// 받음/보냄 글자 · 경로 줄 · 상세 격자의 한 줄.

import ServersCore
import SwiftUI

/// 파싱하지 못한 출력: 원문 그대로 (ServicesView 와 같은 처리)
struct RawLines: View {
    let lines: [String]
    var body: some View {
        Text(lines.isEmpty ? "(출력 없음)" : lines.joined(separator: "\n"))
            .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

/// 작은 회색 제목 + 내용
func infoSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption).foregroundStyle(.secondary).padding(.bottom, 2)
        content()
    }
}

/// "↓ 1.2 GB  ↑ 340 MB" (받음 · 보냄)
func transferText(_ rx: UInt64?, _ tx: UInt64?) -> String {
    guard let rx, let tx else { return "" }
    return "↓ \(DiskFormat.bytes(rx))  ↑ \(DiskFormat.bytes(tx))"
}

/// 여러 표가 같은 자리에 맞추는 열 폭 (그 표만 쓰는 폭은 각 파일에)
enum InfoColumn {
    /// 가동 시간 — 서비스 · docker · 파드 · OpenWrt 가 모두 맨 오른쪽 같은 자리
    static let uptime: CGFloat = 92
    static let address: CGFloat = 150
    static let bytes: CGFloat = 150
    static let chevron: CGFloat = 18
    /// 점 뒤 이름 줄에 맞춘 들여쓰기 (행 여백 6 + 점 8 + 간격 8)
    static let indent: CGFloat = 22
}

extension View {
    /// 표 한 줄의 면: 여백 6 · 3, 강조할 때(누를 수 있는 줄에 마우스가 올라감) 옅은 면, 줄 전체가 마우스를 받는다.
    /// 마우스가 올라갔는지는 부르는 행이 따로 든다 — 표가 들면 마우스가 행을 넘을 때마다 모든 행을 다시 그렸다
    func tableRowSurface(highlighted: Bool) -> some View {
        padding(.horizontal, 6).padding(.vertical, 3)
            .background(highlighted ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.smallRadius))
            .contentShape(Rectangle())
            .hoverEase(highlighted)
    }
}

/// "› 기본 서비스 22개" 접기·펼치기. 위아래 여백은 부르는 쪽이 준다 (표마다 다르다)
struct FoldButton: View {
    let title: String
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(title, systemImage: open ? "chevron.down" : "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
    }
}

/// 한 줄: 점 · 내용 · 오른쪽 열. 누를 수 있으면 마우스를 올렸을 때 옅은 면
struct OpenWrtRow<Leading: View, Trailing: View>: View {
    let dot: StatusTone
    var help: String?
    var action: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot.tableRow(dot)
            leading
            Spacer(minLength: 8)
            HStack(spacing: 0) { trailing }.foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .tableRowSurface(highlighted: action != nil && hovering)
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
        .copyFlash(active: action != nil)   // 이 줄의 누름은 늘 복사다 (주소 · 공개키)
        .help(help ?? "")
    }
}

/// 인터페이스 행 아래 경로 한 줄: "default → 203.0.113.1  metric 1  [기본 경로]". 옅게는 main 의 밀린 default 만
struct InfoRouteLine: View {
    let route: OpenWrtRoute
    let routing: OpenWrtRouting?
    /// 점 뒤 이름 줄에 맞춘 들여쓰기
    let indent: CGFloat

    var body: some View {
        let inUse = routing?.defaultRoutes.contains(route) == true
        HStack(spacing: 8) {
            Text("\(route.destination) → \(route.gateway ?? "On-link")")
            if let metric = route.metric { Text("metric \(metric)").foregroundStyle(.tertiary) }
            if inUse { StatusChip(text: "기본 경로") }
        }
        .foregroundStyle(route.destination == "default" && !inUse ? .secondary : .primary)
        .textSelection(.enabled)
        .padding(.leading, indent)
    }
}

/// 펼친 상세의 자기 대역 경로들 ("192.168.8.0/24 → On-link  metric 100")
struct InfoSubnetRoutes: View {
    let routes: [OpenWrtRoute]

    var body: some View {
        ForEach(routes) { route in
            HStack(spacing: 8) {
                Text("\(route.destination) → On-link")
                if let metric = route.metric { Text("metric \(metric)").foregroundStyle(.tertiary) }
            }
            .textSelection(.enabled)
        }
    }
}

/// 펼친 상세 격자(Grid)의 한 줄: 작은 회색 이름 · 내용(여러 줄이면 위아래로)
func infoDetailRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    GridRow {
        Text(label).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
        VStack(alignment: .leading, spacing: 2) { content() }
    }
}
