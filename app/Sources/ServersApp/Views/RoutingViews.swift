// 경로 표 두 개 — OpenWrt · Linux 의 Network 탭이 같이 쓴다 (OpenWrtNetworkView 에서 옮겨 옴, 모양 그대로).

import ServersCore
import SwiftUI

/// 인터페이스에 묶이지 않는 경로 (LOCAL 화면 Routes 카드와 같은 모양). 조건 없는 트래픽이 타는 줄에 딱지
struct OtherRoutesGrid: View {
    let routes: [OpenWrtRoute]
    let routing: OpenWrtRouting

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
            GridRow {
                if routing.hasOtherTables { Text("Table") }
                Text("Destination"); Text("Gateway"); Text("Interface")
            }
            .font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
            ForEach(routes) { route in
                let inUse = routing.defaultRoutes.contains(route)
                GridRow {
                    if routing.hasOtherTables { Text(route.table) }
                    Text(route.destination)
                    Text(route.kind ?? route.gateway ?? "On-link")
                    HStack(spacing: 8) {
                        if let device = route.device {
                            Text(route.interface ?? device)
                            if let name = route.interface, name != device { Text(device).foregroundStyle(.tertiary) }
                        }
                        if let metric = route.metric { Text("metric \(metric)").foregroundStyle(.tertiary) }
                        if inUse { StatusChip(text: "기본 경로") }
                    }
                }
                // 옅게는 main 의 밀린 default 만 — 다른 테이블의 default 는 규칙에 맞는 트래픽이 실제로 탄다
                .foregroundStyle(route.table == "main" && route.destination == "default" && !inUse ? .secondary : .primary)
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 6)
    }
}

/// 기본 규칙 말고 추가된 규칙: 조건 → 테이블(경로 수) 또는 동작. 비어 있는 테이블을 보는 규칙은 지금 하는 일이 없어 접어 둔다
struct PolicyRulesView: View {
    let routing: OpenWrtRouting
    @State private var showEmptyRules = false

    var body: some View {
        let shown = routing.policyRules.filter { showEmptyRules || !routing.isEmptyLookup($0) }
        let emptyCount = routing.policyRules.filter { routing.isEmptyLookup($0) }.count
        if !shown.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("Priority"); Text("Condition"); Text("Target")
                }
                .font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
                ForEach(shown) { rule in
                    GridRow {
                        Text(String(rule.priority)).monospacedDigit()
                        Text(rule.condition.isEmpty ? "all" : rule.condition)
                        if let table = rule.table {
                            let count = routing.routeCount(inTable: table)
                            Text("table \(table)  ·  \(count == 0 ? "no routes" : count == 1 ? "1 route" : "\(count) routes")")
                        } else {
                            Text(rule.action ?? "")
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 6)
        }
        if emptyCount > 0 {
            Button { showEmptyRules.toggle() } label: {
                Label("경로 없는 테이블을 보는 규칙 \(emptyCount)개", systemImage: showEmptyRules ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 6).padding(.top, shown.isEmpty ? 0 : 4)
        }
    }
}
