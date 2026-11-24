// 원격 정보 Services 탭: 실패(맨 위) · 실행 중(기본 서비스는 접음) · 컨테이너(파드는 네임스페이스별, 끝난 작업은 접음). 파싱은 ServersCore ServicesReport.
// 숫자(준비·재시작·가동·나이)는 오른쪽 고정 폭 열로 맞춘다 — 이름 길이에 따라 들쭉날쭉하지 않게. 가동 시간이 맨 오른쪽 (서비스·docker·파드 모두 같은 자리).
// docker 컨테이너는 compose 프로젝트별로 묶고(ContainerGroup), 호스트로 내놓은 포트를 가동 시간 앞에 적는다.
// 리눅스는 서비스 줄을 누르면 최근 로그 시트. Windows 는 로그가 없어 누를 수 없다 (이유 문구 없이).

import ServersCore
import SwiftUI

/// 오른쪽 열 폭 (서비스·파드 공통)
private enum Column {
    static let uptime = InfoColumn.uptime
    static let restarts: CGFloat = 72
    static let ready: CGFloat = 36
    static let status: CGFloat = 140
}

struct ServicesView: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let lines: [String]
    let report: ServicesReport?
    @State private var showBasic = false
    /// 끝난 작업을 펼친 묶음 (네임스페이스 · "docker")
    @State private var openFinished: Set<String> = []

    var body: some View {
        if let report {
            VStack(alignment: .leading, spacing: 16) {
                if !report.failed.isEmpty {
                    section("실패 \(report.failed.count)") {
                        ForEach(report.failed) { unit in
                            ServiceRow(unit: unit, dot: unit.removed ? .muted : .bad, canOpenLog: canOpenLog, openLog: { openLog(unit) }) {
                                Text(ServicesFormat.failure(unit)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                if report.noSystemd {
                    Text("systemd 가 없는 서버라 서비스 목록을 만들지 못했습니다").foregroundStyle(.secondary)
                } else {
                    section("실행 중 \(report.running.count)") {
                        ForEach(report.mainRunning) { unit in runningRow(unit) }
                        if report.mainRunning.isEmpty, report.basicRunning.isEmpty {
                            Text("실행 중인 서비스가 없습니다").foregroundStyle(.secondary)
                        }
                        if !report.basicRunning.isEmpty {
                            FoldButton(title: "기본 서비스 \(report.basicRunning.count)개", open: showBasic) { showBasic.toggle() }
                                .padding(.vertical, 3)
                            if showBasic {
                                ForEach(report.basicRunning) { unit in runningRow(unit) }
                            }
                        }
                    }
                }
                if !report.sources.isEmpty {
                    containers(report)
                }
            }
            .font(.callout)
        } else {
            // 예전 형식·엉뚱한 출력: 원문 그대로
            Text(lines.isEmpty ? "(출력 없음)" : lines.joined(separator: "\n"))
                .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var canOpenLog: Bool { server.type == .linux }

    private func openLog(_ unit: ServiceUnit) { model.showServiceLog(server, unit: unit.name) }

    private func runningRow(_ unit: ServiceUnit) -> some View {
        ServiceRow(unit: unit, dot: (unit.restarts ?? 0) > 0 ? .warn : .good, canOpenLog: canOpenLog, openLog: { openLog(unit) }) {
            Text((unit.restarts ?? 0) > 0 ? "재시작 \(unit.restarts!)" : "").frame(width: Column.restarts, alignment: .trailing)
            Text(unit.uptime.map(ServicesFormat.duration) ?? "").frame(width: Column.uptime, alignment: .trailing)
        }
    }

    // MARK: 컨테이너

    @ViewBuilder
    private func containers(_ report: ServicesReport) -> some View {
        let pods = report.containers.filter { $0.kind == .pod }
        let dockers = report.containers.filter { $0.kind == .docker }
        // 네임스페이스마다 다시 거르지 않게 한 번에 묶는다 (묶음 안 순서는 원래 순서 그대로)
        let podsByNamespace = Dictionary(grouping: pods, by: \.namespace)
        if let state = report.sources["k3s"] {
            section("k3s 파드 \(pods.count)") {
                if let note = sourceNote("k3s", state, empty: pods.isEmpty) { note }
                if let total = report.truncated["k3s"] { Text("파드가 \(total)개라 앞 200개만 보입니다").foregroundStyle(.secondary) }
                // 네임스페이스는 kubectl 이 준 순서대로 (이름 순)
                ForEach(namespaces(pods), id: \.self) { ns in
                    let items = podsByNamespace[ns] ?? []
                    Text("\(ns)  \(items.count)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    group(items, key: "k3s|\(ns)", foldTitle: "끝난 작업")
                }
            }
        }
        if let state = report.sources["docker"] {
            // 포트를 내놓은 컨테이너가 있을 때만 제목 옆에 ⓘ — 딱지·숫자·화살표가 무엇인지 (올리면 바로 뜨는 HoverNote)
            section("docker 컨테이너 \(dockers.count)", legend: dockers.contains { !ServicesFormat.dockerPortList($0.ports).isEmpty }) {
                if let note = sourceNote("docker", state, empty: dockers.isEmpty) { note }
                if let total = report.truncated["docker"] { Text("컨테이너가 \(total)개라 앞 200개만 보입니다").foregroundStyle(.secondary) }
                // compose 프로젝트별 (파드의 네임스페이스처럼) — compose 를 안 쓰는 서버는 머리 없이 한 줄기
                ForEach(ContainerGroup.byProject(dockers)) { project in
                    if let title = project.title {
                        Text("\(title)  \(project.items.count)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    group(project.items, key: "docker|\(project.id)", foldTitle: "멈춘 컨테이너")
                }
            }
        }
    }

    /// 살아 있는 것 → 끝난 것은 "끝난 작업 N개" 로 접기
    @ViewBuilder
    private func group(_ items: [ContainerItem], key: String, foldTitle: String) -> some View {
        let active = items.filter { !$0.finished }
        let finished = items.filter(\.finished)
        ForEach(active) { item in containerRow(item) }
        if !finished.isEmpty {
            FoldButton(title: "\(foldTitle) \(finished.count)개", open: openFinished.contains(key)) {
                if openFinished.contains(key) { openFinished.remove(key) } else { openFinished.insert(key) }
            }
            .padding(.vertical, 3)
            if openFinished.contains(key) {
                ForEach(finished) { item in containerRow(item) }
            }
        }
    }

    /// 리눅스의 docker 컨테이너는 누르면 최근 로그, 파드는 누르면 상태(멈춘 이유) · 최근 로그 (이름 복사는 우클릭 메뉴). Windows 는 누르면 이름 복사
    private func containerRow(_ item: ContainerItem) -> some View {
        ContainerRow(item: item, opensLog: canOpenLog, copy: { model.copy(item.copyName) }) {
            guard canOpenLog else { return model.copy(item.copyName) }
            switch item.kind {
            case .docker: model.showContainerLog(server, container: item.name)
            case .pod: model.showPodLog(server, name: item.name)
            }
        }
    }

    private func namespaces(_ pods: [ContainerItem]) -> [String] {
        var seen: [String] = []
        for ns in pods.compactMap(\.namespace) where !seen.contains(ns) { seen.append(ns) }
        return seen
    }

    private func sourceNote(_ source: String, _ state: ServicesReport.ContainerSource, empty: Bool) -> Text? {
        switch state {
        case .denied: return Text("권한이 없어 읽지 못했습니다").foregroundStyle(.secondary)
        case .off: return Text("응답이 없습니다 (꺼져 있거나 설정이 없음)").foregroundStyle(.secondary)
        case .ok: return empty ? Text(source == "k3s" ? "파드가 없습니다" : "컨테이너가 없습니다").foregroundStyle(.secondary) : nil
        }
    }

    private func section<Content: View>(_ title: String, legend: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                if legend {
                    HoverNote(label: "포트 표시 설명") { DockerPortsLegend() }
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 2)
            content()
        }
    }
}

/// 컨테이너가 호스트로 내놓은 포트: 번호만. 모든 주소(0.0.0.0)에 내놓아 바깥에서 닿는 것만 무채색 딱지(서버 태그의 회색 배지와 같은 면) —
/// 번호마다 밝기를 달리했더니 한 줄 안에서 글자가 덜 그려진 것처럼 보였다 (2026-11-24 사용자 지적). 열린 것은 문제 상태가 아니라 색은 쓰지 않는다.
/// 딱지·숫자의 뜻은 구역 제목 옆 ⓘ 에 올리면 바로 뜨는 설명(HoverNote · DockerPortsLegend)에.
private struct DockerPortsLabel: View {
    let raw: String

    var body: some View {
        let ports = ServicesFormat.dockerPortsShown(raw)
        if !ports.shown.isEmpty {
            HStack(spacing: 5) {
                ForEach(Array(ports.shown.enumerated()), id: \.offset) { index, port in
                    if port.open {
                        PortBadge(text: port.text)
                    } else {
                        // 딱지 없는 번호끼리 이어질 때만 쉼표 (딱지는 면이 갈라 준다)
                        let comma = index + 1 < ports.shown.count && !ports.shown[index + 1].open
                        Text(verbatim: port.text + (comma ? "," : ""))
                    }
                }
                if ports.more > 0 { Text(verbatim: "+\(ports.more)") }
            }
            .fixedSize()
        }
    }
}

/// docker 구역 제목 옆 ⓘ 의 설명: 줄 오른쪽 포트 표시가 무엇인지 — 왼쪽은 줄에 보이는 모양 그대로, 오른쪽은 뜻
private struct DockerPortsLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Published Ports").font(.cardTitle).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
                GridRow { PortBadge(text: "443"); Text("외부 공개 (0.0.0.0)") }
                GridRow { sample("8405"); Text("서버 내부 전용 (127.0.0.1)") }
                GridRow { sample("192.0.2.10:53"); Text("해당 주소 전용") }
                GridRow { sample("8081→8080"); Text("Host → Container") }
            }
        }
        .fixedSize()
    }

    private func sample(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary).monospacedDigit()
    }
}

/// 서비스 한 줄: 점 · 이름 · 설명(남는 폭) · 오른쪽 열들. 리눅스면 마우스를 올리면 옅은 면, 누르면 최근 로그.
private struct ServiceRow<Trailing: View>: View {
    let unit: ServiceUnit
    let dot: StatusTone
    let canOpenLog: Bool
    let openLog: () -> Void
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot.tableRow(dot)
            Text(unit.name).lineLimit(1).layoutPriority(1)
            Text(unit.description).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 0) { trailing }.foregroundStyle(.secondary).monospacedDigit()
        }
        .tableRowSurface(highlighted: canOpenLog && hovering)
        .onHover { hovering = $0 }
        .onTapGesture { if canOpenLog { openLog() } }
        .modifier(LogHelp(enabled: canOpenLog))
    }
}

/// 로그를 열 수 있는 줄에만 도움말 (Windows 줄엔 아무것도 — 이유 문구 없이)
private struct LogHelp: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.help("누르면 최근 로그") } else { content }
    }
}

/// 컨테이너·파드 한 줄: 점 · 이름(꼬리 해시는 흐리게) · 상태(Running 이 아닐 때만) · 준비 · 재시작 · 나이.
/// docker 는 내놓은 포트(DockerPortsLabel) · 상태(healthy 는 점으로 충분해 적지 않는다) · 가동 시간 — 떠 있지 않으면 상태 글 그대로. 누르면 리눅스는 최근 로그(docker) · 상태와 최근 로그(파드 — PodInspect), 그 밖은 전체 이름 복사.
private struct ContainerRow: View {
    let item: ContainerItem
    let opensLog: Bool
    let copy: () -> Void
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        let name = item.displayName
        HStack(spacing: 8) {
            StatusDot.tableRow(StatusTone(item.tone))
            (Text(name.base) + Text(name.hash).foregroundStyle(.tertiary))
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if item.kind == .docker, !item.detail.isEmpty {
                Text(item.detail).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // 서비스 줄과 같은 간격(0)으로 — 재시작·나이 열이 두 구역에서 같은 자리에 오게
            HStack(spacing: 0) {
                if item.kind == .pod {
                    Text(item.statusWorthShowing ? item.status : "").frame(width: Column.status, alignment: .trailing)
                    Text(item.ready ?? "").frame(width: Column.ready, alignment: .trailing)
                    Text((item.restarts ?? 0) > 0 ? "재시작 \(item.restarts!)" : "").frame(width: Column.restarts, alignment: .trailing)
                    Text(ServicesFormat.podAge(item.age)).frame(width: Column.uptime, alignment: .trailing)
                } else {
                    let status = ServicesFormat.dockerStatus(item.status)
                    if !item.ports.isEmpty {
                        DockerPortsLabel(raw: item.ports).padding(.trailing, status.note == nil ? 0 : 14)
                    }
                    if let note = status.note { Text(note) }
                    if let uptime = status.uptime { Text(uptime).frame(width: Column.uptime, alignment: .trailing) }
                }
            }
            .lineLimit(1).truncationMode(.tail)
            .foregroundStyle(.secondary).monospacedDigit()
        }
        .tableRowSurface(highlighted: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: tap)
        .contextMenu { if opensLog { Button("이름 복사", action: copy) } }
        .help(opensLog ? (item.kind == .pod ? "누르면 상태 · 최근 로그" : "누르면 최근 로그") : "누르면 이름 복사")
    }
}
