# Library harness

Spotify's Your Library page mocked under its own class names and accessibility identifiers (from
`trees/clean/library/03.txt`, recorded 2026-09-16), so `Redesigned/Library/LibraryHeader.x` can be laid out
and looked at on the Mac without the phone.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install <udid> build/LibraryHarness.app
    xcrun simctl launch <udid> com.vojta.libraryharness            # first look
    xcrun simctl launch <udid> com.vojta.libraryharness back       # then the pass the page gets coming back from a playlist
    xcrun simctl launch <udid> com.vojta.libraryharness stacked   # header nested in a UIKit UIStackView
    xcrun simctl io <udid> screenshot shot.png

`build.sh` runs `logos.pl -c generator=internal` over `LibraryHeader.x` from the checkout it sits in and
links it with the real `Core/` and `Redesigned/Kit/` sources; `SRC=<other tweak/Sources> ./build.sh` builds
an older tree instead, to compare. `stubs.m` stands in for the hook files the harness does not compile.

It plays issue #21. The page comes up with the header's control row holding Search alone. At 0.8 s the
header's model lands: Recents and Create show, and the page lays out in the same turn. The mock of
`AutoLayoutStackView` (the real one's ivars are `observationsDictionary` and `needsCoalescedLayoutUpdate`)
places what changed on the next turn of the main queue, in a pass of its own container that reaches
neither the header nor the page. So at the page's pass a button just shown still stands at the row's
origin, where 03.txt has the hidden Recents. Before the fix the moves worked out on that pass stayed:
Search ends up next to the title, left of Recents, and Create goes off the screen. A page pass later (`back`)
put Search on top of Recents, which the old code never placed. After the fix the row's own pass places
everything again.

Launch words: `back` adds the page pass at 2.4 s. `steady` builds the header with the model already in it.
`nocreate` leaves Create out of the model, and `norecents` leaves Recents out (the account the tree was
recorded on). `stacked` nests the same header in a UIKit `UIStackView`; its first-look log reports
`stacked header/title check: PASS` when the hook finds it, hides Spotify's title, and shows the replacement
title with the same text. The default launch still covers Spotify's original direct-child placement. Each
moment is logged with where every control landed in the header:

    xcrun simctl spawn <udid> log show --last 1m --style compact --predicate 'eventMessage CONTAINS "[harness]" OR eventMessage CONTAINS "redesign library"'

What it does not cover: the real stack's constraints and when its coalesced update actually runs, the
element framework behind the avatar, the list's rows (`LibraryRows.x`) and the folder page.

`verify`를 함께 주면 첫 안정 레이아웃에서 제목 검사를 수행하고 종료합니다. `SG_LIBRARY_RUN_ID` 환경값과 결과를 Documents/library-result.json에 기록하므로 호출자는 새 실행의 영수증인지 확인할 수 있습니다. `steady verify`는 기존 직접 배치, `steady verify stacked`는 UIStackView 중첩 배치를 검사합니다. 실패는 비정상 종료하며 검사 기준을 건너뛰지 않습니다. 최신 Simulator의 scene lifecycle은 공통 harness/scene.m으로 연결합니다.
