# 유선 무손실 출력 및 설정 정리

## 변경 사항

- WireGuard를 Player에서 제거하고 Mod Settings 첫 화면의 독립 항목으로 이동했습니다.
  Lossless sources의 선택적 애드온 라우팅 기능은 유지합니다.
- Preparation에는 Preparing, Aligning, Playing 같은 짧은 상태만 표시합니다.
  행을 누르면 전체 설명이나 실패 이유를 확인할 수 있습니다.
- Lossless sources → Wired output → **Wired source output**을 추가했습니다. 기본값은 꺼짐입니다.
  유선 헤드폰, USB DAC, 라인 출력에서만 사용합니다.
- Done 버튼과 기존 하단 UI는 수정하지 않았습니다.

## 유선 출력 동작

무손실 파일의 실제 디코더 정보에서 레이트를 읽고 iOS에 해당 레이트를 요청합니다.
장치가 요청한 레이트를 적용한 경우, Spotify의 활성 출력이 독립적인 Apple
MultiChannelMixer를 사용하는지 확인합니다. 조건이 맞으면 출력을 잠시 중지한 뒤
믹서 출력과 RemoteIO 입력을 같은 레이트로 변경하고 다시 시작합니다.
Spotify 디코더가 연결된 믹서 입력의 레이트는 유지합니다. 외부 파일은 믹서 출력
뒤에서 교체하므로, 협상이 성공하면 외부 파일을 44.1 kHz로 변환할 필요가 없어집니다.

모르는 믹서, 다른 출력과 공유하는 믹서, 출력 수명 변경은 거부합니다.
속성 변경, 초기화 또는 재시작이 실패하면 이전 두 형식을 복구합니다.
복구에 실패하면 상태에 재시작 안내를 표시하며 성공으로 표시하지 않습니다.
다음 곡으로 넘어가거나 옵션을 끄면 변경한 형식과 레이트 선호값을 복원합니다.
일시정지 중 복원이 거부되면 Restore pending으로 표시하고 재생이 재개될 때 다시 시도합니다.

옵션이 켜진 유선 경로에서는 정렬 검사에 사용한 음량 보정값을 실제 외부 PCM에
곱하지 않습니다. 정렬 검사는 그대로 수행하며, 실제 재생 Gain은 0 dB가 됩니다.
원본 음량이 Spotify보다 클 수 있습니다. EQ, Sing, reverb, speed/pitch, sleep timer
페이드나 출력 장치의 처리는 별개입니다. 이 기능은 이들을 임의로 끄지 않습니다.

블루투스의 코덱, 레이트 또는 장치 선택을 조정하지 않습니다. 유선 경로에서 설정한
레이트 선호값은 경로가 바뀐 뒤 다음 무손실 준비 시 해제합니다.
Spotify 순정 스트림의 음질 설정을 무손실로 바꾸는 기능도 아닙니다.
기존 로컬 무손실 파일 교체 기능에는 다음 곡에 대체 파일이 있을 때 Spotify의
다운로드 품질을 낮추는 별도 코드가 있으며, 이번 변경은 그 코드를 수정하지 않습니다.

## 확인 방법

1. Audio sources checks의 presentation 검사와 lossless handoff 검사가 통과한 뒤 IPA를 빌드합니다.
2. Feather로 설치하고 Spotify를 다시 엽니다. 유선 장치를 연결합니다.
3. Mod Settings → Player → Lossless sources → Wired source output을 켭니다.
4. 애드온 또는 로컬 무손실 파일이 정렬될 때까지 기다립니다.
5. Playback details에서 Track Info의 실제 Sample Rate, Resampler의 I/O Rate,
   DSP의 Gain, Output Device의 실제 Sample Rate를 확인합니다.

48 kHz 파일의 성공 예시는 `48000 Hz → 48000 Hz`, 출력 `48000 Hz`, Gain `0.00 dB`입니다.
공급자가 96 kHz라고 주장해도 실제 파일이 48 kHz라면 48 kHz를 요청합니다.
Output status를 누르면 장치 제한 또는 Spotify 출력 경로의 제한을 확인할 수 있습니다.

레이트 일치와 0 dB만으로 전체 출력이 bit-perfect라고 증명되지는 않습니다.
Float32 경로는 24-bit 정수 PCM을 표현할 수 있지만 32-bit 정수 원본, iOS 처리,
하드웨어 정밀도, DSP 등의 제한은 별도로 확인해야 합니다. Bit-exact는 측정하지
못한 항목을 Unknown으로 남깁니다. 이 기능은 물리 장치에서 아직 검증하지 않은 실험 기능입니다.

## 검증 범위

- Linux 환경에서 iPhoneOS 16.5 SDK를 사용해 변경한 Objective-C와 Logos를 arm64 오브젝트로 컴파일했습니다.
- 레이어 규칙, 공백 오류, 셸 문법, Python 문법, workflow YAML을 확인했습니다.
- 실제 converter → Apple mixer → RemoteIO 하네스에 44.1 → 48 kHz 협상, 디코더 입력 유지,
  네이티브 디코더 진행, 이전 레이트 복원, 잘못된 레이트와 오래된 출력 식별자 거부 검사를 추가했습니다.
- Xcode/xcrun이 없어 로컬 시뮬레이터 실행과 IPA 빌드는 수행하지 못했습니다.
  GitHub Actions에서 실행할 수 있게 워크플로에 하네스 실행과 실패 진단 파일 업로드를 추가했습니다.
