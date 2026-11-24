// 원격 폴더 탐색 시트: 다운로드(파일·폴더 여러 개 선택)·업로드(폴더 하나) 시트의 [찾아보기…]. 서버가 알려준 정식 경로를 돌려준다.

import ServersCore
import SwiftUI

struct RemoteBrowserSheet: View {
    @Environment(AppModel.self) private var model
    let server: Server
    /// 업로드 대상 고르기: 폴더 하나만, 절대 경로로 돌려준다
    let foldersOnly: Bool
    /// 처음 열 폴더 (지금 칸에 적힌 경로). 없거나 열 수 없으면 홈.
    var startPath: String? = nil
    /// 고른 경로들 (업로드는 항상 하나)
    let onPick: ([String]) -> Void
    let onCancel: () -> Void

    @State private var path = ""
    @State private var home: String?
    @State private var entries: [RemoteEntry] = []
    @State private var selected: Set<RemoteEntry.ID> = []
    @State private var loading = false
    @State private var problem: String?
    /// "." 로 시작하는 파일·폴더 표시 여부 (Linux 의 숨김 관례, Windows 홈에도 .android 같은 게 많다). 마지막 선택을 기억.
    @AppStorage(AppPreferences.remoteShowHiddenKey) private var showHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(server.key) \(foldersOnly ? "폴더 고르기" : "파일·폴더 고르기")").font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Button { load(RemoteBrowser.parent(path)) } label: { Image(systemName: "arrow.up") }.buttonStyle(CompactButtonStyle()).accessibilityLabel("상위 폴더")
                    .disabled(loading || path == "/" || path.isEmpty)
                    .help("상위 폴더")
                if let home { Button("홈") { load(home) }.buttonStyle(CompactButtonStyle()).disabled(loading || path == home) }
                // Windows 의 "/" 는 드라이브 목록이라 이름만 다르다
                Button(server.type == .windows ? "드라이브" : "루트") { load("/") }.buttonStyle(CompactButtonStyle()).disabled(loading || path == "/")
                    .help(server.type == .windows ? "드라이브 목록" : "/")
                Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Toggle("숨김 파일 보기", isOn: $showHidden).toggleStyle(.checkbox).controlSize(.small)
                    .help("이름이 . 으로 시작하는 파일·폴더")
            }
            RemoteEntryTable(entries: visibleEntries, dimFiles: foldersOnly, allowsMultiple: !foldersOnly, selected: $selected) { entry in
                // 읽는 중에는 받지 않는다 (버튼들과 같게) — 겹쳐 읽으면 늦게 끝난 쪽이 경로·목록을 덮는다
                guard !loading else { return }
                if entry.isDirectory { load(RemoteBrowser.join(path, entry)) }
            }
            .frame(minHeight: 260)
            if let problem {
                Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(StatusTone.warn.color)
            } else {
                Text(foldersOnly ? "폴더를 더블클릭해 들어가고, [선택]은 고른 폴더(없으면 현재 폴더)를 씁니다."
                                 : "폴더는 더블클릭해 들어갑니다. 파일이나 폴더를 고르고 [선택] — ⌘·⇧ 클릭으로 여러 개.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("열기") { if let entry = selectedEntry, entry.isDirectory { load(RemoteBrowser.join(path, entry)) } }
                    .disabled(loading || selectedEntry?.isDirectory != true)
                    .help("고른 폴더로 들어갑니다 (더블클릭과 같음)")
                Spacer()
                Button("취소", action: onCancel).keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
                Button(pickedPaths.count > 1 ? "\(pickedPaths.count)개 선택" : "선택", action: pick).keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle()).disabled(loading || pickedPaths.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .onAppear {
            load(startPath, fallbackToHome: startPath != nil)
            // 다른 폴더에서 시작하면 첫 목록이 홈이 아니다 — [홈] 버튼용 경로는 따로 묻는다 (창 없이, 서버별 기억)
            if startPath != nil { Task { if home == nil { home = await model.remoteHome(server) } } }
        }
        .onChange(of: showHidden) { _, _ in selected = [] }
    }

    private var visibleEntries: [RemoteEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    /// 고른 항목들 (목록 순서)
    private var selectedEntries: [RemoteEntry] { visibleEntries.filter { selected.contains($0.id) } }
    /// 하나만 골랐을 때 그 항목 ([열기]·폴더 고르기)
    private var selectedEntry: RemoteEntry? { selectedEntries.count == 1 ? selectedEntries.first : nil }

    /// [선택]이 돌려줄 경로 (절대). 다운로드: 고른 항목들(없으면 현재 폴더). 업로드: 고른 폴더(없으면 현재 폴더).
    private var pickedPaths: [String] {
        guard !path.isEmpty else { return [] }
        if foldersOnly {
            let entry = selectedEntry
            if let entry, !entry.isDirectory { return [] }
            let absolute = entry.map { RemoteBrowser.join(path, $0) } ?? path
            return [absolute]
        }
        let entries = selectedEntries
        return entries.isEmpty ? [path] : entries.map { RemoteBrowser.join(path, $0) }
    }

    private func pick() {
        let picked = pickedPaths
        guard !picked.isEmpty else { return }
        onPick(picked)
    }

    /// fallbackToHome: 처음 열 폴더가 없거나 못 열면 오류 대신 홈을 연다
    private func load(_ target: String?, fallbackToHome: Bool = false) {
        loading = true
        problem = nil
        Task {
            let result = await model.browseRemote(server, path: target)
            loading = false
            switch result {
            case let .success(listing):
                path = listing.path
                entries = listing.entries
                selected = []
                if target == nil { home = listing.path }   // 홈 목록의 정식 경로를 기억
            case let .failure(error):
                if fallbackToHome { load(nil); return }
                problem = error.reason
            }
        }
    }
}
