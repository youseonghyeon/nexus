# 릴리스 절차

릴리스 하나는 세 곳에 올라갑니다: 이 저장소의 GitHub Release(zip · appcast), Homebrew tap 저장소(cask). 앱 안 업데이트는 Release 의 `appcast.xml` 을, `brew` 는 tap 의 cask 를 읽습니다.

## 처음 한 번

- **Developer ID Application 인증서**가 로그인 키체인에 있어야 합니다 (`make dist` 가 찾아 씁니다).
- **공증 자격 증명**: `xcrun notarytool store-credentials nexus --apple-id <이메일> --team-id <팀 ID>`
- **업데이트 서명 키**: `app/.build/artifacts/sparkle/Sparkle/bin/generate_keys` — 개인 키는 로그인 키체인에 저장되고, 출력된 공개 키가 `app/Info.plist` 의 `SUPublicEDKey` 입니다.
  `generate_keys -x <파일>` 로 내보내 안전한 곳에 보관합니다. 이 키만 잃었다면 같은 Developer ID 로 서명한 릴리스에서 새 키로 바꿀 수 있지만, 인증서까지 잃으면 이미 설치된 앱은 새 버전을 받지 못합니다.
- **tap 저장소**: `youseonghyeon/homebrew-nexus` 에 `Casks/nexus.rb`.

## 매번

1. `app/Info.plist` 의 `CFBundleShortVersionString` · `CFBundleVersion` 을 올리고 `CHANGELOG.md` 에 항목을 씁니다.
2. 검증하고 커밋·푸시합니다.

   ```zsh
   zsh -n lib/lan.zsh && (cd app && make test)
   ```

3. 릴리스 묶음을 만듭니다 (공증에 몇 분 걸립니다).

   ```zsh
   cd app && make dist
   ```

   `build/` 에 세 파일이 생깁니다.

   | 파일 | 올릴 곳 |
   | --- | --- |
   | `Nexus-<버전>.zip` | GitHub Release |
   | `appcast.xml` | GitHub Release (같은 릴리스) |
   | `nexus.rb` | tap 저장소의 `Casks/nexus.rb` |

4. 태그와 Release 를 만듭니다. 태그 이름은 `v<버전>` 이어야 합니다 (appcast 와 cask 의 주소가 이 이름을 씁니다).

   ```zsh
   gh release create v<버전> build/Nexus-<버전>.zip build/appcast.xml --title <버전> --notes-file <변경 내용>
   ```

5. `build/nexus.rb` 를 tap 저장소에 커밋·푸시합니다.

## 확인

- README 의 설치 명령(`brew tap` → `brew trust` → `brew install --cask nexus`)으로 새로 설치되는지. cask 를 고쳤으면 `brew style youseonghyeon/nexus` · `brew audit --cask youseonghyeon/nexus/nexus`.
- 피드가 새 버전을 가리키는지: `curl -sL https://github.com/youseonghyeon/nexus/releases/latest/download/appcast.xml | grep sparkle:version`
  (Release 에 `appcast.xml` 을 빠뜨리면 앱의 확인이 조용히 실패해 아무도 모른다.)
- 이전 버전 앱을 켰을 때 사이드바 아래에 업데이트 띠가 뜨고, 누르면 새 버전으로 다시 시작하는지 (시험 방법은 `AGENTS.md` 의 검증 절).

## 주의

- Release 를 "latest" 가 아닌 사전 릴리스로 올리면 앱이 찾지 못합니다 (`releases/latest/download/appcast.xml`).
- zip 을 다시 만들면 서명과 sha256 이 바뀝니다. zip · appcast · cask 는 늘 같은 `make dist` 에서 나온 것을 함께 올립니다.
