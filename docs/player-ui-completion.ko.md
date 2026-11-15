# 플레이어·한국어 UI 후속 작업 (3번 제외)

이 문서는 `player-followup.ko.md`의 미완료 상태 이후 수행한 작업을 기록합니다.
Lossless Bridge 연동은 사용자 요청으로 이번 작업 범위에서 제외했습니다.

## 변경

- Native/Redesigned 각 레이어의 한 줄 가사를 Shared 가사 캐시·현재 곡·재생 시계·가사 지연과 연결했습니다.
  새 곡의 가사가 아직 없을 때 이전에 삽입한 줄이 남지 않으며, 처음부터 공유 가사가 없었다면
  Spotify 원래 미리보기를 덮어쓰지 않습니다. 창에서 제거되면 갱신 타이머를 중지합니다.
- Redesigned 전환은 열기/닫기의 첫 프레임을 구별합니다. 커버 목적지를 확보하기 전에 원래 커버를
  숨기지 않고, 종료/취소 때 원래 마스크와 sublayerTransform을 복원합니다. 중복 정리도 안전합니다.
  컨테이너 전체 시간축을 바꾸던 속도 조절을 제거해 Spotify의 제스처·릴리스 속도를 유지합니다.
- Native 전환에는 자체 레이어의 snapshot glass 복사 처리를 추가했습니다. 두 UI가 서로 import하지 않습니다.
- 음질 표시의 글자/아이콘을 4pt 올렸습니다. 36pt 터치 영역은 실제 슬라이더 bounds 아래에 2pt 간격을
  확보하며 시간 표시와 겹치지 않습니다. 탐색은 유지하되 배지에는 기본을 표시합니다.
  실제 외부 PCM 출력과 디코더 측정값만 무손실/고해상도 무손실 판단에 사용합니다.
  waveform 아이콘, 테두리 없음, 한 번 탭 팝오버, 글자 강조 효과를 유지합니다.
- 메뉴, 하위 설정, 설명, 알림 및 오류/상태 표시를 한국어로 확장했습니다. 설정 화면의 동적 표시값은
  SGKoreanUI에서 번역해 원래 내부 상태/사용자 입력/키를 바꾸지 않습니다. 기본 UI 문구 사전은 1120개이며
  형식 인자 검증과 생성 파일 재현 검사를 제공합니다. 서비스·기술 명칭과 원문 라이선스는 유지합니다.
  긴 제목·설명은 여러 줄을 허용합니다. 자체 효과 슬라이더도 한국어로 표시합니다.
- 원본 Spotify 9.1.90 IPA 전체 ZIP 검사를 통과했습니다. LyricsContainerView와 CompactOverlayTransition 및
  npbSnapshotView/tabBarSnapshotView 식별자를 원본 바이너리에서 확인했습니다.
- 정지 커버의 상단 3:4 배치 및 하단 흐림 코드와 옵션은 바꾸지 않았습니다.

## 검증

- 두 UI 모드의 실제 production InlineLyrics/PlaybackQuality 코드를 링크한 iOS Simulator 검사 통과:
  가사 위치·사용자 지연·탐색·곡 교체, 음질 구분·디코더 기준·팝오버·탭·터치 영역,
  정지 커버 3:4 배치·하단 블러·옵션 제거.
- production PlayerMorph의 20회 열기/닫기/반전, 지연 레이아웃, 원래 마스크/변환 복원,
  중복 teardown, 잔여 stand-in 없음 검사 통과.
- 실제 Core Audio handoff harness 통과(실패 0): FLAC/ALAC 디코딩, PCM 예산/취소,
  파형 정렬, 탐색·정지·출력 변경 시 무효화, 44.1→48 kHz 유선 협상과 원래 레이트 복원.
- 오디오 소스 protocol fixture, iOS Objective-C/Logos(WireGuard 포함/제외), Swift typecheck 및 레이어 검사 통과.
- WireGuard race 검사와 iOS arm64 archive 생성 통과(앞선 검사 결과, 이후 엔진 코드는 변경하지 않음).
- Mod Settings 하네스 빌드 및 한국어 화면 캡처 확인. 형식 인자/생성 사전 검사 통과.

시뮬레이터는 Spotify 내부 구현의 모의 화면이며 실제 Spotify 기기 재생 검증과 구별합니다.
사용자 요청대로 인증서 서명 및 기기 설치는 수행하지 않습니다. SG_UNSIGNED=1은 Live Activity의
기존 임시 ad-hoc codesign도 생략합니다. 최종 IPA에는 설치 전에 별도 서명이 필요합니다.

GitHub Actions의 enabled:true/active 상태와 별개로 workflow_dispatch가 HTTP 422
`Actions has been disabled for this repository`로 거부됐습니다. 따라서 최신 커밋 Actions 성공이나
Actions 산출물이라고 주장하지 않습니다. 로컬의 동일 release 파이프라인으로 IPA를 만들며
Filebin 업로드 후 전체 재다운로드의 SHA-256 및 바이트 일치를 검사합니다.
