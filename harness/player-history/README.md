# Player history harness

The history rows reuse Spotify's native queue row renderer and current-track view. They appear
above the current-track row in a header on Spotify's existing queue table; future queue cells,
table ownership, editing, shuffle, repeat and the player timer stay with Spotify. If the native
renderer or expected layout is unavailable, the adapter leaves the original queue in place.

## Local checks

Run the deterministic UIKit adapter harness and the Swift/Objective-C ABI harness on a booted
simulator:

```sh
harness/player-history/check.sh
harness/player-history/abi-check.sh
```

The adapter harness checks native row reuse and layout, future-row delegation, scrolling and
restoration, history ordering and limits, duplicate entries, stale taps, native edit mode, and the
targeted replay call. The ABI harness checks the production row model's Swift/Objective-C boundary.
These harnesses use fixtures; they do not validate Spotify's live playback behavior. Production
row-touch playback has also been verified separately in the simulator, as recorded below.

## Spotify 9.1.90 simulator evidence

On the signed-in iPhone 18 Pro simulator, a touch on the production history row replayed
`MementoMori`; player state confirmed it became current and playing (`queue history: replay
confirmed by player state`). Spotify's native `getQueueWithCallback:` showed all 15 core
`nextTracks` remained identical before and after, including order, UIDs, URIs and titles. Playback
was issued by passing a fresh URI-only `SPTPlayerTrack` (nil UID) to `queueTrackPlayNext:`, followed
by the one-argument `skipToNextTrackWithOptions:` call. Task fulfillment alone was not treated as
proof of playback. The displayed `UI.QueueModel.futureTracks` was stale and differed from the live
core queue; exact queue verification used the native callback readback. The queue closed naturally
after playback, so post-play inspection of its hidden header was unavailable. This simulator
evidence does not establish behavior on a physical device or other Spotify versions.

`getQueueWithCallback:` takes a one-argument callback receiving the queue and returns an
`id` cancellation token; it is not an `SPTask`. The wrapper's `fetchQueue` task exposes a transformed
queue value, so it is not interchangeable with this native callback readback when checking exact
queue entries and UIDs.

## Limits

Physical-device behavior and Spotify 9.1.78/9.1.88 remain untested.
