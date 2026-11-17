// 설정 창 (⌘,): 흩어져 있던 설정(화면 모드 · 서버 이름 터널 · 숨김 파일)과 갱신 간격 · 코어 막대 애니메이션 · 비밀번호 키 · 부팅 경로 · 버전.
// 값은 UserDefaults — 키·고를 수 있는 값·기본값은 ServersCore AppPreferences. 바꾸면 바로 반영된다 (다음 갱신부터).

import AppKit
import ServersCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppearanceMode.defaultsKey) private var appearance = AppearanceMode.system
    @AppStorage(AppPreferences.namedTunnelsKey) private var namedTunnels = true
    @AppStorage(AppPreferences.remoteShowHiddenKey) private var showHidden = false
    @AppStorage(AppPreferences.statusInterval.key) private var statusInterval = AppPreferences.statusInterval.defaultValue
    @AppStorage(AppPreferences.systemInterval.key) private var systemInterval = AppPreferences.systemInterval.defaultValue
    @AppStorage(AppPreferences.diskInterval.key) private var diskInterval = AppPreferences.diskInterval.defaultValue
    @AppStorage(AppPreferences.bluetoothInterval.key) private var bluetoothInterval = AppPreferences.bluetoothInterval.defaultValue
    @AppStorage(AppPreferences.serverLiveInterval.key) private var serverLiveInterval = AppPreferences.serverLiveInterval.defaultValue
    @AppStorage(AppPreferences.coreAnimationKey) private var coreAnimation = true
    @State private var confirmRotate = false
    @AppStorage(TerminalColorMode.key) private var terminalColor = TerminalColorMode.none.rawValue

    var body: some View {
        Form {
            Section {
                // 보기 ▸ 화면 모드 와 같은 값 (메뉴에도 그대로 있다)
                Picker("화면 모드", selection: Binding(get: { appearance }, set: { appearance = $0; $0.apply() })) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title) }
                }
            } header: {
                SectionHeader("화면")
            }
            Section {
                Toggle("터널을 localhost 대신 서버 이름으로 열기", isOn: $namedTunnels)
                Toggle("원격 파일 탐색에서 숨김 파일 보기", isOn: $showHidden)
            } header: {
                SectionHeader("터널 · 파일")
            }
            Section {
                intervalPicker("서버 상태 확인", AppPreferences.statusInterval, $statusInterval)
                    .onChange(of: statusInterval) { model.requestRefresh() }   // 지금 대기(옛 간격)를 끝까지 기다리지 않게
                intervalPicker("System 화면", AppPreferences.systemInterval, $systemInterval)
                intervalPicker("Disk 화면", AppPreferences.diskInterval, $diskInterval)
                intervalPicker("Bluetooth 화면", AppPreferences.bluetoothInterval, $bluetoothInterval)
                intervalPicker("서버 Live 탭", AppPreferences.serverLiveInterval, $serverLiveInterval)
            } header: {
                SectionHeader("갱신 간격")
            } footer: {
                Text("서버 켜짐·꺼짐 알림도 서버 상태 확인 간격으로 판정합니다. System·Disk·Bluetooth 화면과 서버 Live 탭은 보고 있을 때만 읽습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("터미널 색", selection: Binding(get: { TerminalColorMode.resolve(terminalColor) },
                                                      set: { terminalColor = $0.rawValue; model.applyTerminalColorMode() })) {
                    ForEach(TerminalColorMode.allCases, id: \.self) { Text($0.title) }
                }
            } header: {
                SectionHeader("터미널")
            } footer: {
                Text("이 앱의 터미널 탭에만 적용됩니다. 미적용은 테마 그룹 서버만 어두운 색, 나머지는 기본색입니다. 열린 탭에도 바로 적용되지만, 서버 프롬프트 색은 새로 접속할 때 바뀝니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("코어 막대를 부드럽게 움직이기", isOn: $coreAnimation)
            } header: {
                SectionHeader("System 화면")
            }
            Section {
                LabeledContent("저장한 비밀번호 \(model.passwords.count)개") {
                    Button("키 새로 만들기…") { confirmRotate = true }.buttonStyle(SecondaryButtonStyle())
                }
            } header: {
                SectionHeader("비밀번호")
            } footer: {
                Text("비밀번호는 이 Mac 의 키체인에 둔 키로 암호화합니다. 키를 새로 만들면 저장한 비밀번호가 모두 지워지고, 다음 접속 때 다시 묻습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("비밀번호 키를 새로 만들까요?", isPresented: $confirmRotate) {
                Button("새로 만들기", role: .destructive) { model.rotatePasswordKey() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("저장한 비밀번호 \(model.passwords.count)개가 모두 지워집니다.")
            }
            // 경로가 둘 이상인 서버만 (하나면 고를 게 없다)
            let wakeServers = model.config?.servers.filter { $0.wolMac != nil && $0.wolRoutes.count > 1 } ?? []
            if !wakeServers.isEmpty {
                Section {
                    ForEach(wakeServers) { server in
                        Picker(server.key, selection: Binding(get: { model.wakeRoute(server)?.via ?? "" },
                                                              set: { model.setWakeRoute($0, for: server) })) {
                            ForEach(server.wolRoutes, id: \.self) { Text($0.label).tag($0.via) }
                        }
                    }
                } header: {
                    SectionHeader("부팅 경로")
                } footer: {
                    Text("Boot 가 이 서버를 거쳐 WOL 패킷을 보냅니다. 경로 목록은 servers.conf 의 wol_via= 입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("버전", value: Self.version)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Palette.content)
        // 높이는 고정 상한 — 내용에 맞춰 키우면(fixedSize) 항목이 늘어 화면보다 길어졌을 때 창이 화면 밖으로 넘치고 스크롤이 없었다 (2026-10-15)
        .frame(width: 480, height: 640)
        .background(FullScreenAuxiliary())
    }

    /// Info.plist 의 CFBundleShortVersionString — 세 자리 버전(주.부.수정, Claude Code 식). 빌드 번호(CFBundleVersion)도 같은 값이라 따로 보이지 않는다
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private func intervalPicker(_ title: String, _ preference: IntervalPreference, _ value: Binding<Double>) -> some View {
        Picker(title, selection: Binding(get: { preference.resolve(value.wrappedValue) }, set: { value.wrappedValue = $0 })) {
            ForEach(preference.choices, id: \.self) { Text("\(Int($0))초").tag($0) }
        }
    }
}

/// 설정 창 섹션 머리: 앱의 카드 제목처럼 작은 회색 일반 글씨 (grouped Form 기본은 크고 굵다)
private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
    }
}
