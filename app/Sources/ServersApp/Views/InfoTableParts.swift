// 원격 정보 탭(OpenWrtViews · LinuxInfoViews · ServicesView)이 같이 쓰는 표 부품:
// 원문 출력(RawLines) · 구역 제목(infoSection) · 한 줄(OpenWrtRow) · 받음/보냄 글자 · 경로 줄 · 상세 격자의 한 줄.

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

/// 한 줄: 점 · 내용 · 오른쪽 열. 누를 수 있으면 마우스를 올렸을 때 옅은 면
struct OpenWrtRow<Leading: View, Trailing: View>: View {
    let dot: Color
    var help: String?
    var action: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            leading
            Spacer(minLength: 8)
            HStack(spacing: 0) { trailing }.foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(action != nil && hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
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
