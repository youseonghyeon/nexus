// 패킷 캡처 창의 요약 카드 (PacketCaptureView 본문 맨 위).

import ServersCore
import SwiftUI

/// 요약 카드: 대화 · 문제 · DNS · WireGuard — 누르면 목록을 그것만
struct CaptureSummaryCard: View {
    @ObservedObject var capture: PacketCaptureController
    let localHosts: Set<String>
    let captureFilter: (String) -> Void

    var body: some View {
        let s = capture.snapshot
        VStack(alignment: .leading, spacing: 8) {
            Text("요약").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow(alignment: .top) {
                    Text("대화").font(.fieldLabel).foregroundStyle(.secondary)
                    conversations(s)
                }
                GridRow {
                    Text("문제").font(.fieldLabel).foregroundStyle(.secondary)
                    issues(s)
                }
                GridRow(alignment: .top) {
                    Text("DNS").font(.fieldLabel).foregroundStyle(.secondary)
                    dnsLines(s)
                }
                if !s.wireguard.isEmpty {
                    GridRow(alignment: .top) {
                        Text("WireGuard").font(.fieldLabel).foregroundStyle(.secondary)
                        wireguardLines(s)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// 상대 끝 · 내 끝(옅게) · 이름표 · 패킷 · 바이트 · 연결 시간 — 칸을 맞춘다. 누르면 목록을 그 대화만, 오른쪽 클릭으로 캡처 필터
    private func conversations(_ s: CaptureSnapshot) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
            if s.top.isEmpty { Text("–").foregroundStyle(.secondary) }
            ForEach(s.top) { c in
                let (remote, local) = ends(c)
                let selected = capture.display == .conversation(c.id)
                GridRow {
                    Text(remote).fontWeight(selected ? .semibold : .regular)
                    Text(local).foregroundStyle(.tertiary)
                    Text(c.label ?? c.transport).foregroundStyle(.secondary)
                    Text("\(c.packets.formatted()) 패킷").foregroundStyle(.secondary).monospacedDigit().gridColumnAlignment(.trailing)
                    Text(DiskFormat.bytes(Double(c.bytes))).foregroundStyle(.secondary).monospacedDigit().gridColumnAlignment(.trailing)
                    Text(c.handshake.map { "연결 \(CaptureText.ms($0))" } ?? "").foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture { capture.display = .conversation(c.id) }
                .contextMenu {
                    Button("이 대화의 패킷만 보기") { capture.display = .conversation(c.id) }
                    if let filter = CaptureFilterAssist.fromConversation(c) {
                        Button("이 대화만 캡처 (\(filter))") { captureFilter(filter) }
                    }
                    let host = PacketCaptureView.host(remote)
                    if !host.contains(" ") { Button("상대 주소로 캡처 (host \(host))") { captureFilter("host \(host)") } }
                }
                .help("누르면 이 대화의 패킷만 · 오른쪽 클릭으로 캡처 필터")
            }
        }
    }

    /// (상대, 내 쪽) — 내 주소가 붙은 끝을 뒤로
    private func ends(_ c: Conversation) -> (String, String) {
        c.ends(local: localHosts)
    }

    private func issues(_ s: CaptureSnapshot) -> some View {
        HStack(spacing: 12) {
            ForEach(TCPIssue.allCases, id: \.self) { issue in
                let count = s.issueCounts[issue] ?? 0
                // 0 인 항목도 같은 밝기 (비활성 버튼은 한 단계 더 흐려져 "응답 없는 SYN" 과 어긋났다)
                Text("\(issue.rawValue) \(count)")
                    .foregroundStyle(count == 0 ? Color.secondary : CaptureText.tone(issue).color)
                    .fontWeight(capture.display == .issue(issue) ? .semibold : .regular)
                    .contentShape(Rectangle())
                    .onTapGesture { if count > 0 { capture.display = .issue(issue) } }
                    .help(issue.explanation)
            }
            let unanswered = s.unansweredSYN
            Text("응답 없는 SYN \(unanswered)").foregroundStyle(unanswered == 0 ? Color.secondary : StatusTone.warn.color)
                .help("SYN 을 보내고 3초 넘게 SYN/ACK 가 없는 연결 — 상대가 꺼졌거나 중간에서 버림")
        }
    }

    private func dnsLines(_ s: CaptureSnapshot) -> some View {
        let recent = Array(s.recentDNS.reversed())
        return VStack(alignment: .leading, spacing: 3) {
            if recent.isEmpty { Text("–").foregroundStyle(.secondary) }
            ForEach(recent) { t in
                HStack(spacing: 8) {
                    Text("\(t.type) \(t.name)").lineLimit(1).truncationMode(.middle)
                    Text(t.resultText(now: s.lastTime)).foregroundStyle(t.isFailed(now: s.lastTime) ? StatusTone.warn.color : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { capture.display = .dns }
            }
        }
    }

    private func wireguardLines(_ s: CaptureSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(s.wireguard) { peer in
                HStack(spacing: 8) {
                    Text(peer.id)
                    Text([peer.lastHandshake.map { "마지막 핸드셰이크 \(CaptureText.clock($0))" } ?? "이 캡처엔 핸드셰이크 없음 (약 2분마다)",
                          "핸드셰이크 \(peer.handshakes)회", "데이터 \(peer.dataPackets.formatted())"].joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { capture.display = .wireguard }
            }
        }
    }
}
