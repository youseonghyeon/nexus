// swift-tools-version: 6.0
// Nexus.app — 서버 관리 GUI. servers.conf 를 읽고 GhosttyTerminal 로 SSH 탭을 연다.
// 빌드·설치는 Makefile (make run / make install). Xcode 프로젝트 없이 SwiftPM 만 쓴다.
import PackageDescription

let package = Package(
    name: "ServersApp",
    platforms: [.macOS("27.0")],   // 디자인·API 기준은 macOS 27 (과거 버전 분기 두지 않음)
    products: [
        // 비밀번호 팝업 헬퍼 (SSH_ASKPASS·SUDO_ASKPASS). 앱 번들의 Contents/MacOS 에 함께 들어간다.
        .executable(name: "servers-askpass", targets: ["ServersAskPass"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.5.2"),
        // 앱 안 업데이트 (받기 · 서명 검증 · 교체 · 재시작). 화면은 기본 창 대신 사이드바 띠 (AppUpdater)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // AppleSMC 온도 센서 (IOKit 구조체 호출이라 C 로 둔다 — ~/.tools/stats-helpers/smctemp.c 와 같은 코드)
        .target(
            name: "CSMC",
            path: "Sources/CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "ServersCore",
            dependencies: ["CSMC"],
            path: "Sources/ServersCore"
        ),
        .executableTarget(
            name: "ServersApp",
            dependencies: [
                "ServersCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyKit", package: "libghostty-spm"),   // 화면 글자 읽기 (TerminalScreen — C API 직접 호출)
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ServersApp",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(
            name: "ServersAskPass",
            dependencies: ["ServersCore"],
            path: "Sources/ServersAskPass"
        ),
        .testTarget(
            name: "ServersCoreTests",
            dependencies: ["ServersCore"],
            path: "Tests/ServersCoreTests",
            exclude: ["Fixtures"]   // 테스트가 #filePath 로 직접 읽는 원문 (LinuxLiveTests)
        ),
    ]
)
