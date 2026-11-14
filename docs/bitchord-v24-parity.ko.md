# BitChord 1.0.2-kr-proxy.24 비교 수정

참고 ZIP SHA-256: dc5c3935f9282240d00adc4f38052a1469138fb24971c232a49492f0fc7f5dd8.
첨부 프롬프트는 설계 참고 자료로 읽었으며 YouTube Music 전용 클래스/분기 값은 Spotify에 적용하지 않았습니다.

## 이번 수정

- 프로필 선택기는 BitChord처럼 public.data/public.text/public.item + Import 모드를 사용합니다.
  .conf처럼 등록 타입이 없는 파일을 포함하고 복사본을 읽습니다. 파일 제공자 읽기는 worker의
  NSFileCoordinator와 최대 64 KiB 스트림으로 처리합니다. 클립보드 가져오기도 추가했습니다.
  성공 시 클립보드를 비우고 가져온 임시 복사본을 지워 키를 Keychain에 보관합니다.
  실행 중에도 새 프로필을 저장할 수 있지만 새 peer 적용에는 재시작이 필요합니다.
- 애드온은 BitChord처럼 /stream/{id}를 먼저 호출하고 search의 streamURL은 fallback으로 씁니다.
  요청 품질은 manifest 옵션의 lossless와 우선 정확히 맞춥니다. 같은 곡의 구두점·여러 아티스트
  표기 차이를 허용하되 제목의 edition 단어와 길이를 확인하고 최종 음향 정렬을 유지합니다.
  길이 후보 허용 범위는 BitChord TrackMatcher와 같은 30초이며, 검색 길이가 없으면 실제 파일로 검증합니다.
  짧은 유효기간의 URL을 다운로드 제한시간보다 짧다는 이유만으로 거절하지 않습니다.
- Test source는 manifest와 실제 인증 검색을 검사합니다. 401/403·429·자체 요청 예산·네트워크
  정책·지원하지 않는 전송·녹음 매칭 실패·다운로드/디코딩 실패·정렬 실패를 구분해 표시합니다.
  비밀 경로/원격 오류 본문은 진단에 넣지 않습니다. 애드온을 처음 켜면 재생 훅도 켜고 재시작을 안내합니다.
- 상세 재생 정보의 SwiftUI StageView와 SignalBus는 첨부 BitChord AudioPipelineSheet.swift에서
  가져왔습니다(GPL-3.0). Track Info → Decoder → Resampler → DSP → Output Device의 다섯 단계,
  신호선 애니메이션과 아래 Done 버튼 구조를 유지합니다. NerdStats/AudioPipeline의 measured와
  claimed 분리 및 원본 비트 깊이·원본 레이트·디코딩 PCM 비트레이트 순서로 바인딩합니다.
  이전 곡/준비 중인 파일을 현재 재생 측정으로 쓰지 않도록 실제 외부 프레임 출력 여부를 확인합니다.
  FLAC STREAMINFO에서 실제 원본 bit depth를 읽고 공급자 claim과 나란히 표시합니다.
  Spotify 디코더 내부 값·LUFS·버퍼 크기처럼 얻지 못하는 값은 —로 남깁니다. 모르는 값을 만들거나
  Float32 출력을 원본 32-bit로 오인하지 않습니다. BitChord의 독립 AVPlayer 엔진 전체를 옮긴 것은 아닙니다.
- WireGuard 엔진 engine.go는 새 BitChord 첨부본과 바이트 단위로 동일함을 확인했습니다.
  wireguard-go/gVisor/인증 SOCKS5/URLSession 프록시 구조를 유지하고 iOS arm64 정적 라이브러리를
  다시 빌드했습니다. URLSession을 실제 터널에 강제 적용하는 HTTPS/출구 국가 검사도 추가했습니다.
  국가/IP 성공이 Spotify 음악 로더 전체를 검증한다는 의미는 UI에서 명확히 구분합니다.

## addon.palv.org 확인

공개 /manifest.json은 HTTP 200이지만 토큰 없는 /search?q=music는 HTTP 401을 반환했습니다.
공개 문서는 로그인 후 받은 개인 token 경로의 manifest와 direct FLAC 계약을 설명합니다:
https://addon.palv.org/docs . 실제 manifest는 quality 기본값 atmos와 lossless/hires 옵션을 선언합니다.
사용자는 양쪽 앱에서 같은 개인 링크를 사용한다고 확인했으므로 공개 root의 401을 현재 장애의
원인으로 단정하지 않습니다. 개인 링크는 여기서 받거나 사용하지 않았으며 실제 보호된 음원 재생을
이 환경에서 성공했다고 주장하지 않습니다. 새 Test source와 준비/정렬 상태로 실패 단계를 확인해야 합니다.

현재 Vitrine 재생기는 전체 stereo FLAC/ALAC를 준비한 후 Spotify 소리와 대조해 전환합니다.
BitChord는 자체 플레이어로 원본을 바로 재생하므로 그곳에서 재생되는 파일도 Spotify 버전과
다른 마스터/시간축이면 정렬이 실패할 수 있습니다. DASH/HLS/Atmos/DRM은 이번 PCM 엔진에
연결하지 않았으며 그런 응답이면 지원하지 않는 형식으로 표시합니다. 이 한계를 지원한 것처럼 숨기지 않습니다.

## 공식 빌드 자료와 범위

공식 netstack HTTP 예제: https://git.zx2c4.com/wireguard-go/tree/tun/netstack/examples/http_client.go
공식 iOS 임베딩 안내: https://www.wireguard.com/embedding/
WireGuardKit(Network Extension)과 이 앱 내부 netstack 프록시는 같은 설치 방식이 아닙니다.
이번 구현은 시스템 VPN/Network Extension 없이 앱 URLSession 경로를 프록시하는 후자입니다.

제공된 Spotify 9.1.90 바이너리에는 SPTCoreURLSessionDataDelegate, HttpClientURLSession이 있고
YTIHamplayerUrlSessionDataLoaderConfig는 없습니다. Cronet/Envoy 문자열은 SDK enum이나 podcast
서비스 이름에도 나타나므로 이름 존재만으로 로더 분기를 추정하거나 값을 0으로 바꾸지 않았습니다.
모든 Spotify 내부 소켓이 터널로 가는지와 실제 음악/다음 곡/잠금 화면 재생은 기기 검증이 남아 있습니다.

## 빌드/검사

기존과 같이 새 코드를 main에 반영한 후 Audio sources checks를 실행합니다. 새 SwiftUI의
Xcode typecheck와 실제 SwiftUI를 링크한 시뮬레이터 창 검사를 CI에 추가했습니다.
그 다음 Build IPA from your own Spotify IPA를 새 main 실행으로 빌드하고 Feather에서 같은
인증서·Identifier로 서명하여 업데이트합니다. 이 환경은 Linux이므로 전체 Xcode IPA 링크·서명은
직접 실행할 수 없습니다. Go C archive와 Objective-C/Logos 컴파일은 여기서 검사합니다.
기존 handoff harness는 xcrun 부재로 여기서는 실행하지 못했습니다.

적용 후 순서:
1. 앱을 재시작합니다. Lossless sources에서 HTTP lossless addons를 켠 첫 실행은 다시 재시작합니다.
2. 같은 개인 manifest 링크로 Test source를 실행합니다. 실패하면 토큰 없는 오류 문구만 공유합니다.
3. Wi-Fi에서 같은 곡을 재생하고 Playback details의 준비/정렬 상태를 확인합니다.
4. WireGuard는 Import .conf file 또는 Import from clipboard로 가져온 후 DNS/HTTPS 검사를 하고
   Spotify app proxy를 켜고 완전 종료/재시작합니다. HTTPS 검사에 성공해도 실제 음악 통신은 별도 확인합니다.
