# 독립 WireGuard 프록시와 창 표시 수정

## 달라진 점

`Mod Settings → Player`에서 **Lossless sources**와 **Network → WireGuard proxy**를
따로 엽니다. `Spotify app proxy`는 무손실 파일·HTTP 애드온을 모두 꺼도 사용할 수 있습니다.
기존 `WireGuard for addons`는 애드온만 터널링하는 선택으로 유지됩니다. 앱 프록시 모드가
켜져 있으면 애드온을 포함한 해당 앱의 URLSession HTTP(S) 요청에 동일한 프록시가 적용됩니다.

소스 추가와 `.conf` 선택기가 열리지 않던 문제도 포함했습니다. `SGPresentDark()`는
다크 스타일만 설정하는 함수인데 실제 표시 함수로 잘못 사용했습니다. 이번 코드의
`SGShowAudioController()`는 실제 `presentViewController`를 호출하고, 기존 알림이나
파일 선택기를 닫는 중에는 주 스레드에서 전환 완료를 기다립니다.

## 맥에서 반영하고 재설치

GitHub Desktop에서 `jsh1022/vitrine`을 선택하고 **Repository → Open in Terminal**을
엽니다. 다운로드 폴더에 이번 ZIP을 저장한 뒤 실행합니다.

```sh
unzip -o "$HOME/Downloads/vitrine-wireguard-proxy-fix.zip" -d .
```

Safari가 자동으로 압축을 풀었다면 대신 실행합니다.

```sh
ditto "$HOME/Downloads/vitrine-wireguard-proxy-fix" .
```

GitHub Desktop에서 변경을 확인하고 `fix: present dialogs and add independent WireGuard proxy`로
커밋한 다음 **Push origin**을 누릅니다. **Audio sources checks**를 확인한 뒤,
**Build IPA from your own Spotify IPA → Run workflow → main**으로 새 빌드를 실행합니다.
오래된 실행의 Re-run jobs는 사용하지 않습니다. 이전과 같은 IPA URL을 사용할 수 있지만
Filebin 원본 링크가 아직 만료되지 않았는지 확인해야 합니다.

결과 IPA를 Feather에서 이전과 같은 인증서·Identifier로 서명하여 설치합니다. 설정 보존을
위해 기존 앱을 먼저 삭제하지 않습니다. 코드 변경은 새 IPA를 설치해야 반영됩니다.

## WireGuard 단독 사용

1. `Mod Settings → Player → WireGuard proxy`를 엽니다.
2. `Import .conf file`에서 본인의 구성을 가져옵니다.
3. 선택적으로 `Test tunnel DNS`를 실행하고 결과를 기다립니다. 본인 peer를 통해
   `api.spotify.com`을 DNS 조회하며 원본 서버로 직접 우회하지 않습니다.
4. `Spotify app proxy`를 켜고 Spotify를 완전히 종료한 뒤 다시 실행합니다.
5. `App proxy this launch`가 On인지, URLSession 요청 뒤 `Routed configurations`와
   `Proxy TCP connections`가 늘어나는지, 실제 peer의 `Last handshake`와 수신/송신 바이트를
   확인합니다. 설정 수는 실제 통신 성공 수와 다르므로 핸드셰이크·통신 바이트도 확인합니다.

앱 프록시의 켜기·끄기는 재실행 후 적용됩니다. 애드온 스위치와 Lossless files는 켜지 않아도
됩니다. 프로필 교체 또는 엔진 완전 종료는 앱 프록시와 애드온 전용 라우팅을 모두 끄고
Spotify를 재실행한 뒤 진행합니다. DNS 검사로 시작한 엔진도 프로세스가 종료될 때 해제됩니다.
캐시된 곡을 재생하면 네트워크 요청이 없어 카운터가 늘지 않을 수 있습니다.

## 적용 범위

공개 Foundation API의 URLSession 구성 생성·세션 생성·공유 세션에 프록시를 적용합니다.
제공된 9.1.90 IPA의 bundle/version/executable을 확인했고, Vitrine이 이미 사용하던
`SPTDataLoaderService`, `Connectivity_HttpClientKit…HttpClientURLSession`,
`SPTCoreURLSessionDataDelegate` 및 `sessionWithConfiguration:delegate:delegateQueue:`가
실행 파일에 존재함을 확인했습니다. 이들 Spotify 내부 클래스에 새 훅을 만들지는 않습니다.
이는 통신 경로를 뒷받침하는 정적 증거이며 전체 Spotify 런타임 트래픽을 증명하지는 않습니다.

앱 내부 wireguard-go/gVisor 엔진과 인증된 loopback SOCKS5를 사용하며 iOS 17 이상이 필요합니다.
오디오 앱 시작을 막지 않도록 포트를 먼저 예약하고 엔진과 peer DNS 초기화는 worker에서 합니다.
프록시 구성은 직접 연결 failover를 끄고 확인합니다. 터널을 쓸 수 없는 앱 URLSession 구성은
차단 프로토콜과 닫힌 loopback 프록시로 처리하고, 정상 상태로 조용히 직접 전송하지 않습니다.
기존 앱의 설정·캐시·쿠키 정책과 다른 URLProtocol들은 유지합니다. 명시적인 HTTP/3 가정은
끄며 SOCKS5 TCP를 사용합니다. 네트워크 경로 변경/포그라운드 복귀에서 UDP 바인딩을 갱신합니다.

**아이폰 전체 VPN이 아닙니다.** 원시 TCP/UDP 소켓, Spotify Connect의 로컬 발견 및 원격 출력,
다른 앱·위젯·별도 WebKit/AVFoundation 프로세스, 주입 전 이미 생성된 세션과 커스텀 통신
스택은 보장 범위 밖입니다. WebSocket 및 장시간 background daemon 동작도 실기기에서
검증하지 않았습니다. 모든 트래픽의 IP/DNS 누출 방지가 목적이면 별도 시스템 VPN을 사용해야 합니다.

단일 peer, 숫자 DNS 및 IPv4 기본 경로를 포함하는 .conf가 필요합니다. 이중 스택 프로필에는
IPv6 기본 경로도 필요합니다. 스크립트 실행과 split-only 프로필은 지원하지 않습니다.
peer endpoint가 hostname이면 최초 endpoint 조회는 터널 밖에서 한 번 수행됩니다.
키와 비밀 URL은 Keychain에 남기며 상태/로그에는 내보내지 않습니다.

## 검증과 남은 확인

- 새 코드와 UIKit 테스트 소스 및 Logos 변환 코드를 iOS 타깃으로 컴파일 검사합니다.
- Go 테스트에 예약한 listener FD의 인수와 엔진 시작 전 대기 중인 SOCKS 요청 유지,
  같은 포트를 통한 터널 HTTPS를 확인하는 회귀 테스트를 추가했습니다.
- 기존 터널 DNS/HTTPS/Range/인증 거부/직접 연결 차단 검사와 함께 `go test -race ./...`를 실행합니다.
- GitHub Mac 검사에 실제 UIKit 창 표시·문서 선택기·재생 정보와 세션 훅의 차단 경로를
  검사하는 시뮬레이터 harness를 추가했습니다. 이 테스트는 오디오/네트워크 엔진만
  가짜 실패 상태로 만들고 실제 URLSession의 HTTP 차단과 설정 보존을 확인합니다.
- Linux에서는 Xcode 시뮬레이터를 실행하지 못합니다. 실제 .conf를 사용한 iOS URLSession의
  성공 경로와 Spotify 로그인/스트리밍/가사/백그라운드, Feather 서명 상태에서의 파일 선택은
  새 IPA 설치 후 기기에서 확인해야 합니다. 테스트 성공이나 컴파일 성공을 실기기 성공으로
  표시하지 않습니다.
