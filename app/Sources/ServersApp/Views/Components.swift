// 여러 화면이 같이 쓰는 작은 부품: 상태 → 색 대응(tone) · 태그 배지(TagBadges) · 제목 있는 카드(InfoCard) · 버튼 스타일 ·
// 무채색 탭 전환(PlainSegmented) · 토스트(StatusToast) · 정보 격자의 한 줄(InfoRow) · 복사 버튼·칩 · 줄바꿈 가로 배치(FlowLayout).
// 색·팔레트는 Theme.swift, 비밀번호 칸은 RomanSecureField.swift.

import ServersCore
import SwiftUI

extension TunnelState {
    var tone: StatusTone {
        switch self {
        case .idle: return .muted
        case .connecting: return .warn
        case .open: return .good
        case .closed: return .bad
        }
    }
}

/// 서버 태그 배지들 (servers.conf env=). 태그마다 ServerTags 표의 색: 운영 빨강 · 스테이징 파랑 · 그 밖 회색.
struct TagBadges: View {
    @Environment(\.colorScheme) private var colorScheme
    let tags: [String]
    /// 서버 정보 머리글용 큰 배지
    var large = false

    var body: some View {
        // 태그가 없으면 아무것도 두지 않는다 — 빈 HStack 도 상위 HStack 의 간격을 먹는다
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    badge(tag)
                }
            }
        }
    }

    private func badge(_ tag: String) -> some View {
        let tone = ServerTags.tone(tag)
        return Text(tag)
            .font(.system(size: large ? 11.5 : 9.5, weight: .bold)).tracking(0.3)
            .lineLimit(1).fixedSize()   // 좁아도 배지 글자가 두 줄로 꺾이지 않게
            .padding(.horizontal, large ? 7 : 5).padding(.vertical, large ? 3 : 2)
            .background(tone == .plain && colorScheme == .light ? Palette.plainBadgeLight : tone.badgeColor, in: RoundedRectangle(cornerRadius: large ? 6 : 4, style: .continuous))
            .foregroundStyle(tone == .plain ? (colorScheme == .light ? Palette.plainBadgeTextLight : Color.primary) : Color.white)
    }
}

extension TagTone {
    var badgeColor: Color {
        switch self {
        case .production: return StatusTone.bad.color.opacity(0.9)
        case .staging: return Color(red: 0.36, green: 0.55, blue: 0.94)
        case .plain: return Color.secondary.opacity(0.22)
        }
    }
}

extension TransferState {
    var tone: StatusTone {
        switch self {
        case .running: return .warn
        case .done: return .good
        case .failed: return .bad
        case .cancelled: return .muted
        }
    }
}

struct InfoCard<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let content: Content
    /// 제목 줄 오른쪽 끝 (카드 자체를 다루는 작은 버튼 자리)
    @ViewBuilder var accessory: Accessory
    /// 나란히 놓인 카드끼리 높이를 맞출 때 (`fillingHeight()`) — 바탕까지 늘어나야 해서 카드 안에서 편다
    var fillsHeight = false

    func fillingHeight() -> Self {
        var card = self
        card.fillsHeight = true
        return card
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.cardTitle).foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            content
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .cardSurface()
    }
}

extension InfoCard where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, accessory: { EmptyView() })
    }
}

/// 보조 버튼 (Browser·Tunnel… 등): 조작부 면 + 머리카락 선. 마우스를 올리면 한 단계 밝아진다.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }

    private struct SecondaryButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .fontWeight(.medium)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(hovering && isEnabled ? Palette.controlHover : Palette.control,
                            in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).strokeBorder(Palette.hairline))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// 작은 보조 버튼 (카드 안 Run·측정·끄기 등): 보조 버튼과 같은 면, 한 단계 작게
struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactButtonBody(configuration: configuration)
    }

    private struct CompactButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(hovering && isEnabled ? Palette.controlHover : Palette.control,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// 주 버튼 (SSH 등): 파랑 대신 무채색 채움 — 색은 상태·경고에만 쓴다. 다크 모드면 밝은 채움에 어두운 글자, 라이트면 반대.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        // 꺼진 주 버튼: 밝은 채움을 흐리게만 하면 회색 판이 켜진 보조 버튼보다 눈에 띈다 — 보조 버튼의 꺼진 모양으로
        if !isEnabled {
            configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Palette.control, in: shape)
                .overlay(shape.strokeBorder(Palette.hairline))
                .opacity(0.4)
        } else {
            configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.primary.opacity(configuration.isPressed ? 0.7 : 0.92), in: shape)
                .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.88) : Color.white)
        }
    }
}

/// 무채색 탭 전환 (원격 정보 카드의 탭 · 입력 시트의 망·종류). 시스템 세그먼트의 파란 선택 대신 옅은 면으로.
/// equalWidths: 칸을 같은 폭으로 — 가장 긴 글자(굵게)보다 좁아지지 않고 줄 폭을 채운다. 고를 때마다 굵기 차이로 폭이 출렁이지 않게 (입력 시트의 망·종류).
struct PlainSegmented<Item: Hashable>: View {
    @Environment(\.isEnabled) private var isEnabled
    let items: [Item]
    @Binding var selection: Item
    var disabled: Set<Item> = []
    var equalWidths = false
    let title: (Item) -> String
    /// 칸마다 우클릭 메뉴 (없으면 메뉴를 달지 않는다 — 바깥 뷰의 우클릭 메뉴를 가리지 않게)
    var itemMenu: ((Item) -> AnyView)?
    /// 고른 칸의 면이 칸 사이를 미끄러져 옮겨 가게 잇는 이름표
    @Namespace private var selectionSpace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                let button = Button { selection = item } label: {
                    ZStack {
                        if equalWidths {
                            ForEach(items, id: \.self) { Text(title($0)).fontWeight(.semibold).hidden() }
                        }
                        Text(title(item)).fontWeight(selected ? .semibold : .regular)
                            .lineLimit(1).fixedSize()   // 좁아도 칸 글자를 꺾지 않는다 ("Netw·ork" 로 두 줄이 됐다 — 넘치면 바깥에서 가로로 민다)
                    }
                        .frame(maxWidth: equalWidths ? .infinity : nil)
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .background {
                            // 고른 칸의 면은 하나뿐 — 고르는 칸이 바뀌면 그 면이 미끄러져 간다 (뚝 끊겨 바뀌지 않게)
                            if selected {
                                RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous).fill(Palette.raised)
                                    .overlay(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous).strokeBorder(Palette.hairline))
                                    .matchedGeometryEffect(id: "selected", in: selectionSpace)
                            }
                        }
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled.contains(item))
                .opacity(disabled.contains(item) ? 0.45 : 1)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if let itemMenu {
                    button.contextMenu { itemMenu(item) }
                } else {
                    button
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: selection)
        .padding(3)   // 여백은 정수로 — 2.5 는 1x 화면에서 위 2·아래 3 으로 갈려 선택 면이 위로 붙어 보였다 (2026-11-10 사용자 지적)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// 오른쪽 아래 토스트: 조작부 면 + 그림자. 경고(실패·불가 문구, StatusNotice)는 경고색 아이콘과 선. 같은 글이 반복되면 (×N). 닫기 버튼.
struct StatusToast: View {
    let message: String
    let count: Int
    let close: () -> Void

    var body: some View {
        let warning = StatusNotice.isWarning(message)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if warning {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(StatusTone.warn.color)
            }
            Group {
                if count > 1 {
                    Text("\(message) \(Text("(×\(count))").foregroundStyle(.secondary))")
                } else {
                    Text(message)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("닫기")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: 380, alignment: .leading)
        // 카드와 같은 면·선 (시스템 반투명 재질 대신). 떠 있는 것이라 그림자를 주고, 경고는 선만 경고색으로
        .background {
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous).fill(Palette.control)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        }
        .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
            .strokeBorder(warning ? StatusTone.warn.color.opacity(0.45) : Palette.fieldBorder))
    }
}

/// Grid 안의 "라벨  값" 한 줄. 값은 선택·복사할 수 있다.
struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label).font(.fieldLabel).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}

/// 복사하고 잠깐(1.2초) ✓ 표시를 켜는 버튼 틀 (CopyButton·CopyChip 공용). label 은 복사 직후인지를 받는다
private struct CopyFeedbackButton<Content: View>: View {
    let value: String
    let model: AppModel
    @ViewBuilder let label: (Bool) -> Content
    @State private var copied = false

    var body: some View {
        Button {
            model.copy(value)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            label(copied)
        }
    }
}

/// 복사 버튼: 누르면 잠깐 ✓ 로 바뀐다 (복사됐는지 눈으로 확인)
struct CopyButton: View {
    let value: String
    let model: AppModel

    var body: some View {
        CopyFeedbackButton(value: value, model: model) { copied in
            Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help("복사")
    }
}

/// 작은 값 하나를 통째로 복사하는 칩: "Host db.acme ⧉"
struct CopyChip: View {
    let label: String
    let value: String
    let model: AppModel

    var body: some View {
        CopyFeedbackButton(value: value, model: model) { copied in
            HStack(spacing: 5) {
                Text(label).foregroundStyle(.secondary)
                Text(value).font(.callout.monospaced())
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(value) 복사")
    }
}

/// 폭이 모자라면 다음 줄로 넘기는 가로 배치. 각 항목은 제 크기(ideal) 그대로 — HStack 처럼 줄이지 않는다.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row); row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
