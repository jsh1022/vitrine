# Vitrine

A Theos tweak (Objective-C + Logos) injected into the decrypted Spotify iOS app. The full guide is
`docs/tweaks.md`; read it before changing code.

## Two looks, never both

**Redesigned UI** (the first row of Mod Settings) picks one of two looks, read once at launch:

- **Native**: Spotify's own screens with the mod's tweaks on them (hide switches, glass header buttons,
  Home gradient, AMOLED switch, accent color...).
- **Redesigned**: the mod's own Liquid Glass look, from a clean sheet. It includes the glass tab bar,
  search field and now playing bar, the redesigned player and lyrics page with Apple Music style lyrics
  always on, a decluttered Home, Search's categories on tinted glass, a Library with one large title, the
  playlist, album and artist pages the way the Music app lays them out with one pinned ⋯ over each, black
  throughout, and its own accent color. No native tweak runs.

Anything that doesn't draw on Spotify's screens works the same under both: ads, privacy, lyrics
sources, gestures, blocked artists, flags, Vibrations, Speed and pitch, and the Live Activity. Those
last three were the redesign's until they moved to `Shared/`, so their keys lost the `.redesign.` and
`Core/SGPrefs.h`'s `SGMigrateKey` carries the old ones over at launch.

**The redesign is built for iOS 26.** It is Liquid Glass, which the system draws from 26 on and no older OS
can be given. `SGRedesignAvailable()` (`Core/SGUIMode.h`) says whether this OS has it. Below 26 the
redesign runs only after a warning that it is untested there (`SGKeyRedesignUntested`, stored by
`SGSetRedesignedUI` in `App/Pages.m`), and a launch with it that hangs (issue #37) is followed by one in
the native look with both switches off. The native look's floor is iOS 16.1, which is
Spotify 9.1.78's own. Vitrine is made for Spotify 9.1.78 and supports 9.1.88 and 9.1.90, the daily test build. The install warning
leaves all three alone. A new version goes in one of the two lists
in `App/Onboarding/Onboarding.h` (`SGSpotifySupportedVersions`, `SGSpotifyLikelyWorksVersions`), and the warning's text
and About follow. The IPA build reads
Spotify's flag table from the IPA it builds, and again when the version changes.

## Where code goes (`tweak/Sources/`)

| Layer | What | Gate at the top of every `%ctor` |
|---|---|---|
| `Shared/` | behavior and data, either look | none |
| `Native/` | Spotify's screens tweaked | `if (!SGNativeUI()) return;` |
| `Redesigned/` | the redesign (`Kit/` + parts) | `if (!SGRedesignedUI()) return;` |
| `App/` | Mod Settings root and combined pages, Mod page, tour | none |
| `Core/`, `Settings/`, `Headers/`, `Diagnostics/` | infrastructure | none |

Rules:

- Imports run one way: `Core <- Settings <- Shared <- Native | Redesigned <- App`. Native and
  Redesigned never import each other. `scripts/check-layers.sh` runs before every build and fails on a
  violation. Don't work around it.
- Change one look without touching the other. When both need the same thing, each side keeps its own
  copy under its own names (`SG…` native, `SGR…` redesign) and its own keys. Examples are the tab bar
  composition and editor, AMOLED and the accent color. Don't merge copies back into
  a shared file.
- A lower layer that needs something from a higher one gets it through a registry in `Core`
  (forced flags: `Core/SGFlagForce.h`) or a function declared low and defined high.
- Settings: each layer builds its own rows and sections. `App/Pages.m` and `App/ModSettings.x`
  decide what to show from `SGRedesignedUIStored()`, so native-only pages disappear in the redesign.
- Keys start with `spotifyglass.` (redesign-only ones with `spotifyglass.redesign.`). Switches are
  read live through the `Core/SGPrefs.m` memo, but Redesigned UI and any feature whose `%ctor` installs
  its hooks only when it is on take effect at the next launch.

## Working on it

- Lossless (`Shared/Lossless/`, `SGLossless.h`; off unless `spotifyglass.lossless` is set): a local FLAC or ALAC of
  the same recording plays in place of Spotify's sound. The anchor comes from cross-correlating 4 s of Spotify's
  output with the file, never from Spotify's position reports, and every seek, skip, pause or route change drops it
  (`SGSourceEvents.x`). Spotify still streams its own copy, so the switch lowers its quality only while the next song
  has a file. `Shared/AudioSources/` now contains an experimental HTTPS addon client, app-local WireGuard
  transport and playback details; `docs/audio-sources-integration.ko.md` records its limits and unrun device checks.
  The older provider designs remain in `docs/lossless-sources.md`. Do not take Sing's
  `SGPlayerSetStage` slot. After audio edits, run the handoff harness (`harness/lossless/handoff-build.sh`).

- Independent WireGuard (`Shared/NetworkProxy/`): an opt-in launch setting configures new app URLSession
  traffic without enabling lossless or addons. It is not a system VPN. Engine initialization is async;
  never call Go or wait for peer DNS in a constructor or on main. Preserve other URLProtocols and session
  policies. `harness/audio-sources/presentation-check.sh` covers UIKit presentation and the unavailable-engine
  URLSession block path on a Mac simulator; `docs/wireguard-proxy.ko.md` records the unverified device scope.

- Build: `make install` (signs and pushes to the phone), `make quick` (a tweak-only change, in seconds), `make release` (IPA only). Tweak only:
  `env -u MAKELEVEL gmake -C tweak clean package`.
- Look at Spotify's views through recorded trees (`make session` records clean ones into
  `trees/clean/`) before hooking anything. Prove every class and selector against the tree or the binary.
- Device log: `make log` (`[spotifyglass]` lines).
- Releases: Release Please (`.github/workflows/release.yml`). Commit as `feat:` / `fix:` (they bump
  `version.txt` and fill `CHANGELOG.md`; `chore:`, `refactor:` and `docs:` stay out). Merging its
  release PR tags `vX.Y.Z` and builds the tweak to check it compiles; nothing is attached. Never edit `version.txt` by hand.
- Known traps: anything pushed onto Spotify's nav stack must conform to `SPTPageController`
  (`Settings/SGPage.m`). Setting `hidden` on views inside Spotify's `OverflowStackView` or its Encore
  stacks crashes, so use alpha. A `CADisplayLink` capped at 60 Hz drags the player's 120 Hz
  transitions down with it. Never observe a notification that other threads post (`NSUserDefaultsDidChangeNotification`,
  `AVAudioSessionRouteChangeNotification`) with `queue:NSOperationQueue.mainQueue`: the posting thread waits
  for main, and at launch main waits on Spotify's CoreThread, so Spotify hangs and is killed. Use `queue:nil`
  and `dispatch_async` to main. Glass takes the appearance it inherits, and outside Spotify's navigation
  stacks (the tab bar, the now playing bar, the player) that is the system's: set every pane of the
  mod's to `overrideUserInterfaceStyle = UIUserInterfaceStyleDark`, or it goes light in light mode. Present a
  controller of the mod's through `SGPresentDark` (`Core/SGGlass.h`): a sheet's glass is its presentation's, and the
  controller's own override does not reach it. ARC does not know that `init` consumes its receiver: calling
  `alloc`/`init` through a cast `objc_msgSend` over-releases when `init` returns another object, so do both on
  `void *` and hand the result to `CFBridgingRelease`. A Logos hook on an `init…` that returns another object
  returns it with `CFBridgingRetain`, or the app crashes at launch. iOS 26's scroll edge effect blurs any header
  that sits inside its own scroll view; hide that list's `topEdgeEffect` (`Redesigned/Player/PlayerScroll.x`).



# Codex 작업 및 모델 분담 지침

## 기본 원칙
- 토큰 사용량과 Codex 사용량 한도를 될수 있는 한 절약한다.
- 메인 에이전트는 상위 모델을 사용한다.
- 간단하고 반복적인 작업은 저비용 서브에이전트(Luna)에 위임한다.
- 복잡하거나 중요한 작업은 메인 에이전트가 직접 처리한다.

## 서브에이전트에 위임할 작업
- 번역 및 다국어 문자열 수정
- 주석, 문서, README 수정
- 단순 코드 정리 및 반복적인 수정
- 빌드 로그 요약 및 오류 분류
- 독립적인 파일 검사
- 지정된 파일에서 함수·설정 키·문자열의 사용 위치 검색
- 기존 코드와 참고 소스의 차이 정리 및 관련 구현 위치 조사
- 메인 에이전트가 정한 범위 내에서 UI 문구·간격·색상·아이콘 등 단순 수정
- 기존 패턴을 따르는 단순 설정 항목 추가 및 표시 연결 (오디오·네트워크 동작 변경은 메인 에이전트가 담당한다.)
- 번역 누락·잘린 문구·잘못된 리소스 경로·중복 설정 키 검사
- 동작 변경이 없는 포맷 정리와 사용하지 않는 import 정리
- 재현 조건과 기대 결과가 명확한 소규모 테스트 작성 (기존 성공 조건을 임의로 변경하지 않는다.)
- 정해진 검사 명령 실행 및 결과 요약
- 수정 파일 목록·변경 요약·커밋 메시지 초안 작성
- 위 작업 중 공통 인터페이스 변경이나 오디오·네트워크·동시성 문제가 발견되면 직접 확장하지 않고 메인 에이전트에 보고한다.

## 메인 에이전트가 직접 처리할 작업
- WireGuard 및 Lossless 기능 통합
- 복잡한 Swift / Objective-C 코드 수정
- dylib 통합 및 충돌 해결
- 런타임 오류 분석
- 최종 IPA 빌드 검증
- 중요한 아키텍처 변경

## 효율성 규칙
- 작업 위임에 필요한 비용이 더 크다면 메인 에이전트가 직접 처리한다.
- 서브에이전트에는 필요한 파일과 최소한의 맥락만 전달한다.
- 같은 파일을 여러 에이전트가 동시에 수정하지 않는다.
- 불필요한 전체 프로젝트 탐색과 반복 분석을 피한다.
- 서브에이전트의 결과 보고는 간결하게 유지한다.
- 최종 통합과 검증은 메인 에이전트가 책임진다.
