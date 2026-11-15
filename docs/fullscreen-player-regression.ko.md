# 전체 화면 아트워크의 한 줄 가사 및 축소 전환

사용자가 재설계 UI에서 보고한 조건을 기준으로 수정했습니다. Native 및 음질 배지·한국어화는 변경하지 않습니다.

## 원인과 수정

한 줄 가사의 텍스트/재생 시계가 아니라, PlayerMotion.x가 SGRPlayerCoverList의 UICollectionView 전체에
투명 마스크를 씌우는 것이 원인이었습니다. 정지 커버도 같은 경로를 사용하므로 두 경우 모두 목록 안의
LyricsContainerView까지 사라졌습니다. 이제 PlayerArtwork.x가 등록한 실제 CoverArtTiltView들만
마스크로 숨깁니다. 목록과 가사는 유지하며, 아트워크를 끄거나 fade를 반전하면 자신의 마스크만 제거합니다.

PlayerMorph.x는 전체 화면 아트워크가 보이는 경우에도 미니플레이어 커버의 UIImageView 복제본을
추가했습니다. 정지 커버는 기존 MotionShowing 검사에 해당하지 않아 복제본이 바로 보였고, 동영상도
축소 진행 중 복제본의 alpha가 커졌습니다. 이제 전환 시작 시 전체 화면/일반 커버 상태를 고정합니다.
전체 화면인 경우 실제 배경을 플레이어 안에서 함께 축소하며 별도 정사각형 커버를 생성하지 않습니다.
일반 커버의 기존 이동은 유지합니다.

첨부 BitChord의 PlayerDock.swift/NowPlayingScreen.swift가 배너와 sleeve의 소유권을 구분하고
배너 상태에서 sleeve를 중복 그리지 않는 원리를 참고했습니다. SwiftUI 뷰 코드를 Spotify에 복사하지
않고 기존 UIKit/Spotify 전환에 적용했습니다. 정지 커버 상단 3:4 및 하단 블러 배치는 바꾸지 않았습니다.

## 회귀 검증

- harness/player/artwork-check.sh: production PlayerArtwork/PlayerMotion/PlayerField를 연결하고 실제와 같은
  커버 목록 안에 가사를 배치합니다. 정지 커버 활성화, 그림만 숨김, 가사의 모든 상위 뷰 가시성,
  옵션 해제 후 복원을 검사합니다. 동영상을 끌 때 레이아웃 콜백이 먼저 마스크를 제거하던
  경로도 수정해 기존 0.35초 커버/동영상 교차 페이드를 유지합니다. 이전 목록 전체 마스크 구현에서는 이 검사가 실패합니다.
- 같은 하네스의 동영상·전환·배경 교체·가사 페이지·일시정지·저전력 모드 26개 조건을 확인합니다.
  오래된 texture-strip 검사는 현재 production의 불투명 평균색 foot 표현과 기하 조건으로 갱신했습니다.
- harness/player-morph/check.sh: 일반 커버 20회와 정지/동영상 전체 화면 40회 드래그·반전 검사.
  전체 화면 전환 중 별도 커버가 생성되지 않는지 매 단계 확인합니다.
- 기존 두 UI 모드의 가사 시계·음질 배지·팝오버·정지 커버 3:4/블러 검사는 유지합니다.

시뮬레이터 검사는 실제 Spotify 기기 재생 확인과 구별합니다. 인증서 서명 및 기기 설치는 하지 않습니다.
GitHub Actions 실행이 계속 422로 거부되면 해당 사실을 최종 보고하고 로컬 unsigned release IPA를 전달합니다.
