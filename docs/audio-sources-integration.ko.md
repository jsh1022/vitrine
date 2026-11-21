# WireGuard · 무손실 애드온 · 상세 재생 정보

**후속 수정:** 버튼의 화면 표시 누락을 고치고 WireGuard를 독립된 앱 URLSession 프록시로
확장했습니다. 최신 메뉴·사용 순서·적용 범위는 [독립 프록시 안내](wireguard-proxy.ko.md)를
따릅니다. 아래 애드온 전용 WireGuard 설명은 첫 통합의 동작이며, 새 앱 프록시 모드를
켜면 애드온 스위치와 무관하게 앱 URLSession 요청에 적용됩니다.

이 수정본은 Vitrine `2f1f1580bb681c5856ee31467092eae423373fee`에 적용한 실험적 통합입니다.
완성된 IPA나 실기기 검증을 마친 배포판은 아닙니다.

재설계 플레이어의 애드온 재생 방식, 음질 정보의 측정 범위, 이전·현재·다음 곡 화면의 동작과 검증 상태는 [재생 모드 안내](redesigned-playback-modes.ko.md)를 참고하세요.

## 추가한 기능

- **HTTP 음원 애드온**: 생성된 HTTPS 루트/manifest URL을 추가하고 연결 검사·삭제·현재 곡 재시도를 합니다. 최대 8개 소스를 추가 순서대로 조회합니다. 공급자 코드는 실행하지 않습니다.
- **앱 내부 WireGuard**: 첨부 BitChord의 Go 엔진을 Vitrine 전용 URLSession에 연결했습니다. `.conf`를 파일 앱에서 가져오고 Keychain에 저장합니다. 애드온 JSON과 음원 요청에만 적용됩니다. Spotify 로그인·Spotify 스트림·다른 앱의 트래픽을 터널링하지 않습니다.
- **상세 재생 정보**: 곡·아티스트·URI·재생 위치·상태, 준비된 파일의 FLAC/ALAC 코덱·원본 샘플레이트·비트 깊이·채널·평균 파일 비트레이트, 실제 클라이언트 PCM·오디오 세션 레이트·출력 경로·출력 지연·속도·피치·Karaoke·터널 상태를 표시합니다.
- 기본 UI와 재설계 UI 모두 Player 설정에서 열 수 있습니다. 플레이어의 `⋯`에도 Playback details 진입점을 추가했습니다.

## 빌드

Mac에서는 기존 README의 Xcode 26 이상·Theos·IPA 주입 도구를 설치하고, 추가로 `vendor/wireguard/go.mod`에 맞는 Go를 설치합니다. Go 1.27.4로 검사했습니다.

```sh
make release IPA=/path/to/your/decrypted-spotify.ipa
```

WireGuard는 기본 포함됩니다. 제외하려면 `make release WIREGUARD=0 IPA=...`를 사용합니다.
제외 빌드에서 WireGuard 설정을 켜면 애드온 요청을 차단합니다. 직접 연결로 조용히 우회하지 않습니다.

Mac 없이 빌드하려면 본인 GitHub 포크에 수정 소스를 반영한 후 기존 **Build IPA from your own Spotify IPA** 워크플로를 실행합니다. Go 설치 단계를 추가했습니다. 실제 Actions 실행이나 GitHub 업로드는 이 작업에서 수행하지 않았습니다.

Spotify 9.1.78/9.1.88/9.1.90의 본인 decrypted IPA가 필요하며, 결과 IPA에는 본인 인증서로 서명해야 합니다. 기존 UI 재설계는 iOS 26 이상을 권장합니다. WireGuard를 애드온 URLSession에 적용하는 기능은 iOS 17 이상이 필요합니다.

## 설정 순서

1. `Settings → Mod Settings → Player → Lossless files`를 켜고 Spotify를 한 번 다시 실행합니다. 오디오 훅은 시작할 때 설치됩니다.
2. `Lossless sources & WireGuard → Add source`에서 본인이 사용할 수 있는 애드온의 생성된 HTTPS 링크를 붙여넣습니다. GitHub 저장소 링크나 HTML 설정 페이지는 사용할 수 없습니다.
3. 소스 항목에서 `Test manifest`를 실행합니다. 이 검사는 manifest 계약과 연결만 검사하며, 해당 곡의 매칭이나 실제 재생 성공까지 보장하지 않습니다.
4. `HTTP lossless addons`를 켭니다. 기본값은 휴대전화 데이터 다운로드 차단이며, 필요하면 `Allow cellular downloads`를 켭니다.
5. 터널을 쓰려면 `Import .conf file`로 본인 WireGuard 구성을 가져온 다음 `WireGuard for addons`를 켭니다. 설정을 변경하면 새 준비 시도가 현재 곡을 다시 조회합니다. 실제 peer 핸드셰이크는 첫 터널 요청 이후 확인합니다.
6. `Playback details`에서 준비된 파일 형식과 출력 상태를 확인합니다. `External lossless frames reaching local output`은 최근 0.5초 동안 외부 PCM 프레임이 로컬 출력 경로에 전달된 경우에만 표시합니다. 정렬만 된 상태는 따로 표시합니다.

프로필을 교체하려면 WireGuard를 끄고 Spotify를 다시 실행한 뒤 가져옵니다. 저장된 프로필을 삭제해도 실행 중인 Go 엔진은 프로세스가 종료될 때 메모리에서 해제됩니다. 터널을 끈 뒤 재실행하면 사용 중인 엔진도 종료됩니다.

## 지원 범위와 동작

`/manifest.json`, `/search?q=...`, `/stream/{id}` 계약을 사용합니다. 검색 결과의 직접 `streamURL`도 지원합니다. 비밀 경로 접두사와 기본 URL의 query를 보존하고, 곡 ID를 한 개의 경로 세그먼트로 인코딩합니다. 사용자 에이전트는 Vitrine입니다. BitChord 공식 앱 인증을 요구하는 공급자는 사용하지 않습니다.

현재는 **HTTPS로 제공되는 완성된 스테레오 FLAC/ALAC 파일**만 사용합니다. HLS·DASH·DRM·Atmos·HTTP 전용 서버·추가 요청 헤더가 필요한 서버·ISRC 전용 조회·공급자별 사용자 설정 폼은 지원하지 않습니다. 호스팅된 상용 공급자와의 실시간 호환성을 확인하지 않았으며 기본 서버 주소나 계정을 넣지 않았습니다. 본인 라이브러리를 제공하는 HTTPS 서버가 첫 검증 대상으로 적합합니다.

제목과 아티스트를 보수적으로 대조하고 길이 차이가 2초 이내인 후보 한 개를 선택합니다. live/remaster 등의 표기는 지우지 않습니다. 동일 곡을 놓칠 수 있으며, 성공한 metadata 매칭도 동일 마스터를 증명하지 않습니다. 파일 헤더를 native decoder로 확인한 뒤 기존 Vitrine 엔진이 파일을 디코딩하고 Spotify 출력과 약 4초간 소리를 대조합니다. 소리가 일치해야 교체합니다. 실패하거나 파일을 준비할 수 없으면 Spotify 오디오를 계속 사용합니다.

애드온 JSON은 요청당 1 MiB·20초, 음원은 128 MiB·120초로 제한합니다. 서버가 429 또는 503과 함께 `Retry-After`를 보내면 해당 대기 시간을 따릅니다. 그 외 일시 오류는 지수형 대기로 다시 시도합니다. 중복 검색·stream 조회를 줄이기 위해 JSON 응답을 제한된 크기와 짧은 수명의 캐시에 보관합니다. 포그라운드 재생 준비가 대기 중이면 백그라운드 파일 수신을 중단하고 100ms 간격으로 확인하며, 현재 곡 준비가 끝난 뒤 사전 준비를 재개합니다. 사전 준비는 다음 한 곡만 대상으로 하며 곡 전체 큐나 플레이리스트를 받지 않습니다. 셀룰러 차단은 요청 전 네트워크 확인·URLSession 설정·전송 중 경로 감시로 적용합니다. 새 곡과 설정 변경은 진행 중 준비를 취소하고 이전 세대의 응답을 버립니다. 준비 파일은 임시 폴더에 두고 곡 전환 또는 다음 실행의 첫 준비 때 정리합니다.

Spotify는 큐·컨트롤·가사 타이밍을 계속 담당하고 자체 스트림도 내려받습니다. 정상 속도 1×와 Karaoke가 꺼진 상태에서 기존 엔진의 정렬 조건을 만족해야 외부 파일로 전환됩니다. Spotify Connect의 원격 기기 오디오는 개선하지 않습니다. 원본 고해상도 파일이 클라이언트 레이트로 리샘플링될 수 있으며, Bluetooth 등 출력 경로까지 bit-perfect라고 주장하지 않습니다. Spotify 자체 디코더의 코덱·비트레이트는 검증된 API에서 얻을 수 없어 미확인으로 표시합니다. 알아내지 못한 원본 bit depth를 Float32 출력으로 추정하지 않습니다.

## 보관과 라이선스

비밀 링크 및 WireGuard 프로필은 기기 전용 Keychain에 보관합니다. 환경설정 내보내기에 포함하지 않습니다. 애드온 API 리다이렉트는 거부하고, 음원 리다이렉트는 HTTPS만 허용합니다. 원격 오류 본문이나 URL을 로그/상태에 노출하지 않습니다. WireGuard 엔드포인트가 hostname이면 최초 연결을 위한 DNS 조회는 터널 밖에서 한 번 수행됩니다.

첨부 `BitChord-iOS-main.zip`의 `WireGuard/`를 GPL-3.0에 따라 포함했고 기존 제3자 라이선스를 유지했습니다. 엔진 출처와 ZIP SHA-256은 `vendor/wireguard/README.vitrine.md`에 있습니다. 애드온 JSON 모델은 참고하고 Vitrine의 Objective-C 클라이언트로 새로 구현했습니다. IPA 파이프라인은 WireGuard의 GPL 및 제3자 고지도 앱에 넣습니다.

## 수행한 검증

- Go 1.27.4에서 `go test ./...`와 `go test -race ./...` 통과. 로컬 WireGuard peer를 사용한 핸드셰이크·터널 DNS·HTTPS·Range·인증 거부·직접 연결 차단·소켓 재생성·키 정보 비노출 검사가 포함됩니다.
- Linux에서 iPhoneOS 16.5 SDK와 Clang 19를 사용해 iOS arm64용 Go C archive 빌드 성공.
- 새 Objective-C 소스와 변경한 오디오 엔진·설정 페이지·플레이어 메뉴를 iOS arm64 타깃으로 컴파일 검사. WireGuard 포함/제외 양쪽 검사.
- Vitrine 레이어 검사·패치 공백 검사·셸 문법 검사·워크플로 YAML 파싱 수행.

**아직 실행하지 않은 검증**: Foundation 프로토콜 fixture 실행(`bash harness/audio-sources/check.sh`의 Mac 실행 파일), 실제 URLSession과 SOCKS5의 iPhone 통합, 실제 애드온 서버에서의 음원 준비, Spotify 기기 재생·전환·탐색·백그라운드·UI 레이아웃, 전체 Theos 링크·서명·IPA 설치. 기존 오디오 handoff harness는 Linux에 `xcrun`이 없어 실행할 수 없었습니다. `Audio sources checks` 워크플로에 Mac fixture와 iOS 소스 검사를 추가했으며, 전체 오디오 동작 검증은 기존 handoff harness와 실기기에서 진행해야 합니다.
