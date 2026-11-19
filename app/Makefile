# Nexus.app 빌드·번들·실행. Xcode 프로젝트 없이 SwiftPM 만 쓴다.
#
#   make            디버그 빌드 + .app 번들 (build/Nexus.app)
#   make run        번들을 실행
#   make release    릴리스 빌드로 번들
#   make install    /Applications/Nexus.app 에 복사 (brew 로 깐 자리 — 실제로 띄우는 앱)
#   make dist       릴리스 묶음: 공증한 build/Nexus-<버전>.zip + 앱 안 업데이트 피드 build/appcast.xml + Homebrew cask build/nexus.rb
#                   (올리는 순서는 저장소 RELEASING.md). 처음 한 번:
#                   공증 자격 증명  xcrun notarytool store-credentials nexus --apple-id <이메일> --team-id <팀 ID>
#                   업데이트 서명 키 .build/artifacts/sparkle/Sparkle/bin/generate_keys  (로그인 키체인에 저장 — 공개 키는 Info.plist SUPublicEDKey)
#   make test       ServersCore 단위 테스트 (모의 러너, 서버 접속 없음)
#   make icon       Resources/icon/render-icon.swift 로 아이콘을 다시 그려 AppIcon.icns 생성
#   make cert       로컬 서명 인증서 "Servers Local" 생성 (한 번). Developer ID 가 없을 때 이걸로 서명해 macOS 권한(위치 등)이 빌드 뒤에도 유지된다
#   make clean

APP      := Nexus
# 서명: Developer ID 가 있으면 그걸로 (hardened runtime, 릴리스는 timestamp — 공증 가능), 없으면 로컬 인증서 "Servers Local", 그것도 없으면 ad-hoc.
# Developer ID 는 SHA-1 해시로 고른다 — 갱신해 같은 이름이 둘이면 이름으로는 codesign 이 "ambiguous" 로 실패한다.
IDENTITIES := $(shell security find-identity -v -p codesigning 2>/dev/null)
DEVID    := $(shell security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' | head -1 | awk '{print $$2}')
SIGN     := $(or $(DEVID),$(if $(findstring "Servers Local",$(IDENTITIES)),Servers Local,-))
SIGN_OPTS := $(if $(DEVID),--options runtime $(if $(filter release,$(CONFIG)),--timestamp,),)
NOTARY_PROFILE ?= nexus
# 배포 zip 이름에 붙는 버전 (Info.plist CFBundleShortVersionString — 세 자리 주.부.수정)
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null)
BUILD_VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist 2>/dev/null)
DIST_ZIP := build/$(APP)-$(VERSION).zip
# 릴리스를 올리는 GitHub 저장소 (Info.plist SUFeedURL 과 같은 곳) · Sparkle 의 서명 도구 (swift build 가 받아 둔다)
REPO     ?= youseonghyeon/nexus
RELEASE_URL := https://github.com/$(REPO)/releases/download/v$(VERSION)
SPARKLE_BIN := .build/artifacts/sparkle/Sparkle/bin
CONFIG   ?= debug
BUILD    := .build/$(CONFIG)
OUT      := build/$(APP).app
CONTENTS := $(OUT)/Contents
SPARKLE  := $(CONTENTS)/Frameworks/Sparkle.framework/Versions/B

.PHONY: all build bundle run release install dist test clean icon cert

all: bundle

build:
	@# swiftbuild 는 LC_BUILD_VERSION 의 sdk 를 배포 타깃(Package.swift platforms)으로 찍는다. 이 값이 macOS 가 그릴 디자인을 정하므로
	@# 배포 타깃을 낮추면 옛 디자인(불투명 제목줄)으로 돌아간다. 확인: vtool -show-build build/Nexus.app/Contents/MacOS/Nexus
	swift build -c $(CONFIG)

bundle: build
	@rm -rf "$(OUT)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILD)/ServersApp" "$(CONTENTS)/MacOS/$(APP)"
	@cp Info.plist "$(CONTENTS)/Info.plist"
	@cp "$(BUILD)/servers-askpass" "$(CONTENTS)/MacOS/servers-askpass"
	@cp Resources/icon/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# 내부망·hosts 스크립트 (AppModel.libDir) — 번들만으로 동작하게
	@mkdir -p "$(CONTENTS)/Resources/lib"
	@cp ../lib/lan.zsh ../lib/hosts.zsh "$(CONTENTS)/Resources/lib/"
	@# IEEE 배정 목록 — 진단 [이웃 보기]의 제조사 (DeviceIdentity)
	@cp Resources/oui/oui.tsv "$(CONTENTS)/Resources/oui.tsv"
	@# 브라우저 시작 페이지의 다크 모드 배경 (Resources/startpage/render-background.py 로 Blender 에서 그린 것 — AppModel.startPageBackground)
	@cp Resources/startpage/background-dark.jpg "$(CONTENTS)/Resources/startpage-background.jpg"
	@# GhosttyTerminal 리소스 번들(terminfo·셸 통합). Bundle.module 은 Bundle.main.resourceURL 부터 찾는다.
	@cp -R "$(BUILD)/GhosttyKit_GhosttyTerminal.bundle" "$(CONTENTS)/Resources/"
	@# Sparkle(앱 안 업데이트): 프레임워크를 번들에 넣고 실행 파일이 거기서 찾게 한다. 빌드 폴더를 가리키는 rpath 는 뺀다(다른 Mac 엔 없는 경로).
	@mkdir -p "$(CONTENTS)/Frameworks"
	@cp -R "$(BUILD)/Sparkle.framework" "$(CONTENTS)/Frameworks/"
	@install_name_tool -add_rpath @executable_path/../Frameworks "$(CONTENTS)/MacOS/$(APP)"
	@otool -l "$(CONTENTS)/MacOS/$(APP)" | awk '/PackageFrameworks/ {print $$2}' | while read -r p; do install_name_tool -delete_rpath "$$p" "$(CONTENTS)/MacOS/$(APP)"; done
	@# 서명은 안쪽부터: Sparkle 의 도우미들 → 프레임워크 → 우리 도우미 → 번들 전체 (공증은 번들 서명이 온전해야 받는다)
	@codesign --force --sign "$(SIGN)" $(SIGN_OPTS) "$(SPARKLE)/XPCServices/Installer.xpc"
	@codesign --force --sign "$(SIGN)" $(SIGN_OPTS) --preserve-metadata=entitlements "$(SPARKLE)/XPCServices/Downloader.xpc"
	@codesign --force --sign "$(SIGN)" $(SIGN_OPTS) "$(SPARKLE)/Autoupdate"
	@codesign --force --sign "$(SIGN)" $(SIGN_OPTS) "$(SPARKLE)/Updater.app"
	@codesign --force --sign "$(SIGN)" $(SIGN_OPTS) "$(CONTENTS)/Frameworks/Sparkle.framework"
	@codesign --force --sign "$(SIGN)" $(SIGN_OPTS) "$(CONTENTS)/MacOS/servers-askpass"
	@codesign --force --sign "$(SIGN)" $(SIGN_OPTS) --entitlements Nexus.entitlements "$(OUT)"
	@echo "bundled: $(OUT) (signed: $(SIGN))"

run: bundle
	open -n "$(OUT)"

release:
	$(MAKE) bundle CONFIG=release

install: release
	@rm -rf "/Applications/$(APP).app"
	@cp -R "$(OUT)" "/Applications/$(APP).app"
	@echo "installed: /Applications/$(APP).app"

# 공증: 제출 → 승인 대기 → 표(staple)를 붙여 다시 묶는다. 받은 쪽은 인터넷 없이도 Gatekeeper 를 통과한다.
dist: release
	@# 앱 안 업데이트는 CFBundleVersion 으로 비교하고 피드에는 CFBundleShortVersionString 을 쓴다 — 둘이 다르면 설치한 뒤에도 업데이트 띠가 계속 뜬다
	@[ "$(VERSION)" = "$(BUILD_VERSION)" ] || { echo "버전 키 두 개가 다릅니다 ($(VERSION) / $(BUILD_VERSION)) · CFBundleShortVersionString 과 CFBundleVersion 을 같은 값으로 맞추세요 · app/Info.plist"; exit 1; }
	@[ -n "$(DEVID)" ] || { echo "Developer ID 인증서가 없습니다 · 키체인에 Developer ID Application 인증서를 설치하세요 · Makefile DEVID"; exit 1; }
	@rm -f "$(DIST_ZIP)"
	ditto -c -k --keepParent "$(OUT)" build/$(APP)-notarize.zip
	xcrun notarytool submit build/$(APP)-notarize.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(OUT)"
	@rm -f build/$(APP)-notarize.zip
	@# 확장 속성(com.apple.provenance)을 빼고 묶는다 — 넣으면 zip 에 ._ 파일이 섞여, unzip 처럼 그대로 푸는 도구에서 서명이 깨진다
	ditto -c -k --norsrc --noextattr --keepParent "$(OUT)" "$(DIST_ZIP)"
	@# 앱 안 업데이트 피드: zip 을 업데이트 키(키체인)로 서명해 최신 버전 한 건짜리 appcast 를 쓴다. 앱은 릴리스의 latest/download/appcast.xml 을 읽는다.
	@SIG=$$($(SPARKLE_BIN)/sign_update "$(DIST_ZIP)") && [ -n "$$SIG" ] || { echo "업데이트 서명 실패 · 키체인에 Sparkle 서명 키가 없습니다 · $(SPARKLE_BIN)/generate_keys"; exit 1; }; \
	printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' \
	  '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
	  '  <channel>' \
	  '    <title>$(APP)</title>' \
	  '    <item>' \
	  '      <title>$(VERSION)</title>' \
	  "      <pubDate>$$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>" \
	  '      <link>https://github.com/$(REPO)/releases/tag/v$(VERSION)</link>' \
	  '      <sparkle:version>$(VERSION)</sparkle:version>' \
	  '      <sparkle:shortVersionString>$(VERSION)</sparkle:shortVersionString>' \
	  '      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>' \
	  "      <enclosure url=\"$(RELEASE_URL)/$(APP)-$(VERSION).zip\" $$SIG type=\"application/octet-stream\"/>" \
	  '    </item>' \
	  '  </channel>' \
	  '</rss>' > build/appcast.xml
	@# Homebrew cask (tap 저장소의 Casks/nexus.rb 로 올린다). auto_updates: 앱이 스스로 올라가므로 brew 는 버전 차이를 문제 삼지 않는다.
	@SHA=$$(shasum -a 256 "$(DIST_ZIP)" | awk '{print $$1}'); \
	printf '%s\n' 'cask "nexus" do' \
	  '  version "$(VERSION)"' \
	  "  sha256 \"$$SHA\"" \
	  '' \
	  '  url "https://github.com/$(REPO)/releases/download/v#{version}/Nexus-#{version}.zip"' \
	  '  name "Nexus"' \
	  '  desc "Server dashboard with SSH terminal, tunnels, file transfer and network tools"' \
	  '  homepage "https://github.com/$(REPO)"' \
	  '' \
	  '  livecheck do' \
	  '    url :url' \
	  '    strategy :github_latest' \
	  '  end' \
	  '' \
	  '  auto_updates true' \
	  '  depends_on arch: :arm64' \
	  '  depends_on macos: :golden_gate' \
	  '' \
	  '  app "Nexus.app"' \
	  '' \
	  '  zap trash: [' \
	  '    "~/Library/Application Support/Servers",' \
	  '    "~/Library/Preferences/local.yuseonghyeon.servers.plist",' \
	  '  ]' \
	  'end' > build/nexus.rb
	@echo "dist: $(DIST_ZIP) · build/appcast.xml · build/nexus.rb"

test:
	swift test --filter ServersCoreTests

icon:
	cd Resources/icon && swift render-icon.swift AppIcon-1024.png 1024 && rm -rf AppIcon.iconset && mkdir AppIcon.iconset && \
	for s in 16 32 128 256 512; do sips -z $$s $$s AppIcon-1024.png --out AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  d=$$((s*2)); sips -z $$d $$d AppIcon-1024.png --out AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; done && \
	iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset

cert:
	scripts/make-signing-cert.sh

clean:
	rm -rf build .build
