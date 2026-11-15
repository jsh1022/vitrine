# 플레이어 후속 수정과 검증 범위

- Native와 Redesigned 각각의 InlineLyrics.x는 Spotify의 기존 한 줄 가사 컨테이너를 유지하면서
  Shared 가사 엔진의 현재 곡, 재생 시계 및 사용자 지연을 사용해 문구를 갱신합니다.
  기존 미리보기는 Vitrine의 소스 캐시와 보정된 시계에 연결되어 있지 않았습니다.
  숨김 정책은 그대로 두고 창을 떠나면 타이머를 중지합니다. 실제 Spotify 화면 확인은 남아 있습니다.
- Redesigned morph는 커버 목적지 레이아웃을 확보한 뒤 원래 커버를 숨기며,
  대체 커버 제거와 원래 커버 복원을 같은 트랜잭션에 넣고 중복 정리를 막습니다.
  Native 전환은 Spotify의 기존 전환을 유지합니다. 두 모드 모두 기기 프레임별 검증은 남아 있습니다.
- 음질 배지는 탐색 중에도 기본을 표시하며 waveform을 공통 사용합니다.
  기존 36pt 터치 영역과 시간 라벨 간격을 유지하며 글자와 아이콘을 4pt 올립니다.
  터치 영역은 실제 슬라이더 bounds 아래 2pt 간격을 확보합니다.
  실제 외부 PCM 출력 및 파일 디코더 측정으로만 무손실을 표시합니다.
- Mod Settings의 주요 메뉴와 하위 항목, 공통 버튼 및 일부 상태·오류를 한국어로 변경했습니다.
  전체 설명과 모든 동적 오류의 번역 및 긴 문구의 실제 기기 검수는 아직 완료하지 않았습니다.

## Lossless Bridge 인증

첨부 BitChord-iOS-1.0.2-kr-proxy.24의 AddonModels.swift는 bitchordAuth를
requiresOfficialAppProof로 읽고, AddonSource.health는 실제 검색을 보내 거부 여부를 확인합니다.
AddonClient에는 공식 앱 proof 발급·갱신이나 Vitrine에 허용된 로그인 방법이 없습니다.
minAppVersion: 39는 Vitrine의 버전 번호를 위장해서 해결할 수 있는 인증 방법이 아닙니다.
서비스의 인증 문서/운영자 허용 및 사용 가능한 자격 증명 없이 연동 성공을 주장할 수 없습니다.
Vitrine은 기존 인증 요구 manifest 거부를 유지하고 이유를 한국어로 표시합니다.
addon.palv.org의 개인 링크 보관, query 보존, 검색/stream 계약과 디코딩 경로는 유지합니다.
개인 토큰을 코드나 로그에 추가하지 않았습니다.

## 이번 로컬 검증

- WireGuard iOS arm64 C archive 생성 성공(임시 Go 1.27.3 사용).
- WireGuard `go test -race ./...` 통과.
- `harness/audio-sources/check.sh` 통과: protocol fixture, iOS Objective-C/Logos,
  WireGuard 포함/제외 컴파일, Swift typecheck, 레이어 검사.
- 시뮬레이터 실행은 설치된 iOS 런타임이 없어 실패했습니다.
- handoff-build.sh는 로컬 ffmpeg 부재로 fixture 생성에서 실패했습니다.
- Actions 저장소 설정은 enabled:true이고 워크플로는 active지만, 두 workflow_dispatch 요청 모두
  HTTP 422 `Actions has been disabled for this repository`로 거부됐습니다.
  계정/플랫폼 측 추가 원인은 API 응답만으로 확인되지 않았습니다.
  이전 커밋의 성공 검사를 이번 커밋의 성공으로 간주하지 않습니다.
- IPA 원본은 HEAD가 403이지만 GET Range 0–1023은 1024바이트 다운로드에 성공했습니다.
  새 IPA는 빌드하지 못했으므로 Filebin 업로드와 다운로드 SHA-256 검증도 완료하지 않았습니다.

Lossless Bridge의 공개 홈페이지(https://losslessbridge.de.deplexo.com/)는 브라우저별 개인 링크를
발급하고 BitChord에 붙여넣도록 안내하지만 Vitrine용 공식 앱 proof 발급 방법을 설명하지 않습니다.
공개 /manifest.json은 404입니다. 개인 링크나 토큰은 이 문서에 보관하지 않습니다.
