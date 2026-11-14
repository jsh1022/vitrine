# 시뮬레이터 실행 검사 종료 문제 후속 수정

이전 검사에서는 Go 터널 테스트, iOS 정적 라이브러리 빌드와 Objective-C/프로토콜 컴파일
검사가 성공했지만, 시뮬레이터 앱에서 PASS 표시 없이 실행 검사가 종료되었습니다.
해당 출력만으로 충돌·watchdog·UIKit assertion 중 어느 것인지 확정할 수 없습니다.

이번 코드에서는 dylib constructor에서 NSURLSessionConfiguration 생성을 강제하던 호출을
제거했습니다. 생성자는 훅만 등록하고 첫 실제 세션 구성이 엔진의 비동기 초기화를 시작합니다.
이는 dyld 초기화 문맥에서 Foundation/CFNetwork 초기화를 강제하는 위험을 제거하는 수정이며,
이전 실행의 확정된 충돌 원인이라고 주장하지 않습니다.

검사에는 진입 단계와 예외 출력을 추가하고, 이전 모달이 아직 붙어 있는 동안 잘못된 창을
확인하지 않도록 다음 모달의 종류·제목을 기다리게 했습니다. 성공 조건은 그대로 유지합니다.
PASS가 없거나 시간이 초과되면 계속 실패하며 검사를 건너뛰거나 성공 처리하지 않습니다.

실패 시 앱 표준 출력, 시스템 로그, 화면 캡처와 해당 앱의 충돌 보고서를
`audio-presentation-diagnostics` artifact에 7일 보관합니다. 프로필이나 IPA를 쓰지 않는
검사 앱의 진단 자료만 수집합니다. GitHub runner의 다른 앱 보고서·환경 변수는 수집하지 않습니다.

## 적용

GitHub Desktop에서 본인 vitrine 저장소의 `Repository → Open in Terminal`을 연 뒤 실행합니다.

```sh
unzip -o "$HOME/Downloads/vitrine-ci-startup-fix.zip" -d .
```

Safari가 자동으로 풀었다면 다음 명령으로 합칩니다.

```sh
ditto "$HOME/Downloads/vitrine-ci-startup-fix" .
```

`fix: defer proxy startup and capture simulator diagnostics`로 커밋하고 Push origin을 누릅니다.
Audio sources checks가 다시 실행됩니다. 다시 실패하면 실행 화면 아래 Artifacts의
`audio-presentation-diagnostics`를 다운로드하여 공유하면 중단 단계와 충돌 원인을 확인할 수
있습니다. 진단 결과가 나오기 전에는 iPhone 설치 성공이나 프록시 작동 성공으로 판단하지 않습니다.

변경한 Objective-C/Logos 코드의 컴파일과 Python runner의 성공·PASS 누락·시간 초과 출력 보존을
검사했습니다. Linux에서는 Xcode 시뮬레이터를 직접 실행하지 못하므로 새 GitHub 실행이 필요합니다.
