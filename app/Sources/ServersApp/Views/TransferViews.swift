// 파일 전송 UI: 서버 화면 액션 카드의 "파일" 행(버튼)과 그 아래 드롭 영역, 업로드·다운로드 입력 시트, 사이드바 TRANSFERS 행, 전송 정보 시트.

import AppKit
import ServersCore
import SwiftUI
import UniformTypeIdentifiers

/// 액션 카드의 "파일" 행: 업로드·다운로드 버튼
struct TransferButtons: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        let reachable = model.isReachable(server)
        HStack(spacing: 8) {
            Button { model.chooseUpload(server) } label: { Label("Upload…", systemImage: "arrow.up.doc") }
                .disabled(!reachable)
            Button { model.promptDownload(server) } label: { Label("Download…", systemImage: "arrow.down.doc") }
                .disabled(!reachable)
        }
    }
}

/// 액션 카드 아래 드롭 영역. 파일을 떨어뜨리면 그 서버로 업로드(원격 경로를 묻는다).
struct TransferDropZone: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @State private var targeted = false

    var body: some View {
        let reachable = model.isReachable(server)
        // 카드의 남는 자리를 채우는 우묵한 면. 파일을 올려 가져오면 선이 또렷해진다 (색은 쓰지 않는다)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            shape.fill(Palette.well.opacity(targeted ? 1 : 0.6))
            shape.strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(targeted ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.35))
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 17, weight: .light))
                    .foregroundStyle(targeted ? .primary : .secondary)
                Text(reachable ? "파일·폴더를 놓으면 \(server.key) 서버로 업로드" : "지금은 업로드할 수 없음")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: .infinity)
        .opacity(reachable ? 1 : 0.6)
        .dropDestination(for: URL.self) { urls, _ in
            guard reachable else { return false }
            model.promptUpload(server, localPaths: urls.filter(\.isFileURL).map(\.path))
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// 업로드 시트: 보낼 항목 확인 → 원격 폴더 (절대 경로로 보인다. 직접 적은 상대 경로는 홈 기준).
/// 처음 값은 그 서버에 마지막으로 올린 폴더, 없으면 홈 아래 기본 폴더(Linux download, Windows Downloads — 없으면 홈).
/// 폴더를 바꾸면(입력이 0.5초 멈추면) 그 폴더에 쓸 수 있는지 서버에 묻고, 없거나 못 쓰면 Upload 를 비활성으로 둔다 (이유 문구 없이).
struct UploadPromptSheet: View {
    @Environment(AppModel.self) private var model
    let request: UploadPromptRequest
    @State private var remotePath: String
    @State private var browsing = false
    /// 마지막으로 확인한 쓰기 가능 여부. nil = 확인 중이거나 모름 (막지 않는다)
    @State private var access: RemoteCommands.WriteAccess?
    /// 칸이 기본 폴더로 자동으로 채운 값인가. 직접 치거나 찾아보기로 고르면 꺼진다 — 그때는 없는 폴더라도 홈으로 바꾸지 않는다
    @State private var autoFilled: Bool

    init(request: UploadPromptRequest) {
        self.request = request
        _remotePath = State(initialValue: request.initialPath ?? Self.defaultName(request.server))
        _autoFilled = State(initialValue: request.initialPath == nil)
    }

    /// 홈 아래 기본 폴더 이름. 홈 경로를 알면 절대 경로로 바꿔 보인다.
    static func defaultName(_ server: Server) -> String { UploadPathPlan.defaultName(windows: server.type == .windows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(request.server.accountTitle) 서버로 업로드").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(request.localPaths.prefix(6), id: \.self) { path in
                    Label(path, systemImage: isDirectory(path) ? "folder" : "doc").font(.callout).lineLimit(1).truncationMode(.middle)
                }
                if request.localPaths.count > 6 {
                    Text("외 \(request.localPaths.count - 6)개").font(.caption).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading) {
                GridRow {
                    Text("원격 경로")
                    HStack(spacing: 6) {
                        // 직접 고친 값은 자동 채움이 아니다 (화면이 바꾼 값은 이 Binding 을 거치지 않는다)
                        TextField(request.server.type == .windows ? "비우면 홈 (C:/Users/\(request.server.user))" : "비우면 홈 (~)",
                                  text: Binding(get: { remotePath }, set: { remotePath = $0; autoFilled = false }))
                            .frame(width: 250)
                        Button("찾아보기…") { browsing = true }.buttonStyle(SecondaryButtonStyle()).fixedSize()   // 칸이 좁아도 글자가 사라지지 않게
                    }
                }
            }
            Text("상대 경로는 홈 기준입니다. 같은 이름이 있으면 덮어씁니다. 진행률은 사이드바 Transfers 에 표시됩니다.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { model.closeUploadPrompt() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
                Button("Upload") {
                    model.closeUploadPrompt()
                    model.startUpload(request.server, localPaths: request.localPaths,
                                      remotePath: RemoteBrowser.normalizePath(remotePath, windows: request.server.type == .windows))
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                .disabled(access == .readonly || access == .missing)
            }
        }
        .padding(16)
        .frame(width: 480)
        .task(id: remotePath) {
            // 입력이 멈춘 뒤에만 묻는다 (글자마다 ssh 를 돌리지 않게). 경로가 바뀌면 이 작업은 취소되고 새로 시작한다.
            access = nil
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // 기본 폴더 이름은 절대 경로로 펴고, 자동으로 채운 기본 폴더가 서버에 없으면 홈으로 (ServersCore UploadPathPlan).
            // 칸을 바꾸면 바뀐 경로로 이 작업이 다시 돈다
            let server = request.server
            let next = await UploadPathPlan.next(field: remotePath, windows: server.type == .windows, autoFilled: autoFilled,
                                                 home: { await model.remoteHome(server) },
                                                 access: { await model.uploadTargetAccess(server, path: $0) })
            guard !Task.isCancelled else { return }
            switch next {
            case .fill(let path): remotePath = path
            case .show(let result): access = result
            }
        }
        .sheet(isPresented: $browsing) {
            // 폴더 하나, 절대 경로로 돌아온다. 지금 칸의 폴더에서 연다 (없거나 못 열면 홈)
            let current = RemoteBrowser.normalizePath(remotePath, windows: request.server.type == .windows)
            RemoteBrowserSheet(server: request.server, foldersOnly: true, startPath: current.isEmpty ? nil : current,
                               onPick: { remotePath = $0.first ?? ""; autoFilled = false; browsing = false }, onCancel: { browsing = false })
                .environment(model)
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}

/// 다운로드 시트: 원격 경로(직접 입력 하나, 또는 찾아보기로 여러 개) → 받을 로컬 폴더 (기본 ~/Downloads)
struct DownloadPromptSheet: View {
    @Environment(AppModel.self) private var model
    let request: DownloadPromptRequest
    @State private var remotePath = ""
    /// 찾아보기에서 두 개 이상 고른 경로. 비어 있으면 remotePath 입력칸을 쓴다.
    @State private var picked: [String] = []
    @State private var localDirectory = NSHomeDirectory() + "/Downloads"
    @State private var browsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(request.server.accountTitle) 에서 다운로드").font(.title3.weight(.semibold))
            Grid(alignment: .leading) {
                GridRow {
                    Text("원격 경로")
                    HStack(spacing: 6) {
                        // Windows 도 슬래시: scp 의 SFTP 모드가 "\" 를 이스케이프로 먹어 "Desktop\a.zip" 이 "Desktopa.zip" 으로 간다 (입력하면 / 로 바꿔 준다)
                        if picked.isEmpty {
                            TextField(request.server.type == .windows ? "예: Desktop/report.zip 또는 D:/backup/data.zip" : "예: /var/log/syslog 또는 ~/file", text: $remotePath)
                                .frame(width: 250)
                        } else {
                            HStack(spacing: 4) {
                                Text("\(picked.count)개: " + picked.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                                    .lineLimit(1).truncationMode(.tail)
                                    .help(picked.joined(separator: "\n"))
                                Spacer(minLength: 0)
                                Button { picked = [] } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("고른 항목 지우기")
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("직접 입력으로")
                            }
                            .frame(width: 250)
                        }
                        Button("찾아보기…") { browsing = true }.buttonStyle(SecondaryButtonStyle()).fixedSize()   // 칸이 좁아도 글자가 사라지지 않게
                    }
                }
                GridRow {
                    Text("받을 폴더")
                    HStack(spacing: 6) {
                        Text(localDirectory).lineLimit(1).truncationMode(.middle).frame(width: 250, alignment: .leading)
                        Button("선택…") { chooseDirectory() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            Text("같은 이름이 있으면 덮어씁니다.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { model.closeDownloadPrompt() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
                Button("Download") {
                    model.closeDownloadPrompt()
                    let paths = picked.isEmpty ? [RemoteBrowser.normalizePath(remotePath, windows: request.server.type == .windows)] : picked
                    model.startDownload(request.server, remotePaths: paths, localDirectory: localDirectory)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                .disabled(picked.isEmpty && remotePath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .sheet(isPresented: $browsing) {
            RemoteBrowserSheet(server: request.server, foldersOnly: false, onPick: { paths in
                if paths.count > 1 { picked = paths } else { picked = []; remotePath = paths.first ?? "" }
                browsing = false
            }, onCancel: { browsing = false })
                .environment(model)
        }
        .frame(width: 500)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: localDirectory)
        panel.prompt = "여기에 받기"
        if panel.runModal() == .OK, let url = panel.url { localDirectory = url.path }
    }
}

/// TRANSFERS 섹션의 한 행: 상태등 · 제목 · 진행률 · 취소/지우기. 클릭하면 상세 시트.
struct TransferRow: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var transfer: TransferSession

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(tone: transfer.tone).frame(width: Metrics.sidebarIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if case .running(.some) = transfer.state {
                    if let fraction = transfer.fraction { ProgressView(value: fraction).controlSize(.small) } else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                if transfer.isActive { model.cancelTransfer(transfer.id) } else { model.removeTransfer(transfer.id) }
            } label: {
                Image(systemName: transfer.isActive ? "stop.circle" : "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help(transfer.isActive ? "전송 취소" : "목록에서 지우기")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.showTransferInfo(transfer) }
        .selectionDisabled()
        .contextMenu {
            Button("상세") { model.showTransferInfo(transfer) }
            if transfer.isActive { Button("취소") { model.cancelTransfer(transfer.id) } }
            Button("지우기") { model.removeTransfer(transfer.id) }
        }
    }

    private var detail: String {
        switch transfer.state {
        case .running: return transfer.progressText ?? "연결 중…"
        case .done: return "완료"
        case .cancelled: return "취소됨"
        case let .failed(code, message): return "실패 (exit \(code)) · \(message.split(separator: "\n").last ?? "")"
        }
    }
}

/// 전송 정보: 상태·진행률 → 방향/서버/로컬/원격(복사·Finder) → 출력 로그(접힘) → 취소/제거.
struct TransferInfoSheet: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var session: TransferSession
    @State private var showLog = false

    var body: some View {
        let spec = session.spec
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusDot(tone: session.tone)
                Text(stateText).font(.headline)
                Spacer()
                // "n분 전" 은 모델이 안 바뀌어도 흘러야 한다 — 이 글만 30초마다 다시 그린다
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(timing).font(.caption).foregroundStyle(.secondary)
                }
            }
            if case let .running(progress) = session.state {
                if progress != nil, session.fraction == nil { ProgressView().progressViewStyle(.linear) } else { ProgressView(value: session.fraction ?? 0) }
                if let progress, let text = session.progressText {
                    Text("\(progress.file) · \(text)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if case let .failed(_, message) = session.state, !message.isEmpty {
                Text(message.split(separator: "\n").last.map(String.init) ?? message)
                    .font(.caption).foregroundStyle(StatusTone.warn.color).lineLimit(3)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("방향").font(.fieldLabel).foregroundStyle(.secondary)
                    Text(spec.direction == .upload ? "업로드 (이 Mac → \(spec.server.key))" : "다운로드 (\(spec.server.key) → 이 Mac)")
                }
                GridRow {
                    Text("서버").font(.fieldLabel).foregroundStyle(.secondary)
                    Text(spec.server.target).font(.body.monospaced()).textSelection(.enabled)
                }
                ForEach(Array(spec.localPaths.enumerated()), id: \.offset) { index, path in
                    GridRow {
                        Text(index == 0 ? "로컬" : "").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(path).font(.body.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "folder") }.accessibilityLabel("Finder 에서 보기")
                                .buttonStyle(.borderless).help("Finder 에서 보기")
                            Button { model.copy(path) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("경로 복사")
                                .buttonStyle(.borderless).help("경로 복사")
                        }
                    }
                }
                ForEach(Array(spec.remotePaths.enumerated()), id: \.offset) { index, path in
                    GridRow {
                        Text(index == 0 ? "원격" : "").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(path.isEmpty ? "~ (홈)" : path).font(.body.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Button { model.copy(spec.remoteTarget(path)) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("원격 경로 복사")
                                .buttonStyle(.borderless).help("\(spec.remoteTarget(path)) 복사")
                        }
                    }
                }
            }
            if !session.log.isEmpty {
                DisclosureGroup("출력 (\(session.log.count)줄)", isExpanded: $showLog) {
                    ScrollView {
                        Text(session.log.suffix(40).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.callout)
            }
            HStack {
                if session.isActive {
                    Button("취소") { model.cancelTransfer(session.id) }
                } else {
                    Button("목록에서 지우기") { model.removeTransfer(session.id); model.closeTransferInfo() }
                }
                Spacer()
                Button("닫기") { model.closeTransferInfo() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .frame(minWidth: 560)
    }

    private var stateText: String {
        switch session.state {
        case let .running(progress):
            guard progress != nil else { return "연결 중…" }
            return session.fraction.map { "전송 중 · \(Int($0 * 100))%" } ?? "전송 중"
        case .done: return "완료"
        case .cancelled: return "취소됨"
        case let .failed(code, _): return "실패 · exit \(code)"
        }
    }

    private var timing: String {
        let started = session.startedAt.formatted(date: .omitted, time: .shortened)
        return session.isActive ? "\(started) 시작" : "\(started) 시작 · \(session.startedAt.formatted(.relative(presentation: .named)))"
    }
}
