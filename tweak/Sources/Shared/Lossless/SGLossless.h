// Lossless: a local FLAC, ALAC or WAV/AIFF PCM file of the same recording replaces Spotify's sound.
//
//     SGLosslessEngine.m   finds where Spotify plays in the file by matching its sound, and swaps the file in
//     SGLosslessStore.m    which file belongs to which Spotify track
//     Lossless.x           anchors again at each track start, seek or resume (the switch below)
//     SGSourceEvents.x     drops the anchor at a seek, skip, pause or route change
#import <Foundation/Foundation.h>

#define SGKeyLossless @"spotifyglass.lossless"   // off unless set

NS_ASSUME_NONNULL_BEGIN
// Install original-audio capture before addon download finishes; no I/O or wait.
void SGLosslessBeginCapture(void);
// Asynchronous bounded prefix predecode of one complete, immutable upcoming file.
void SGLosslessPrepareNext(NSString *_Nullable path, double rate);
// Off main/render. Reuses recent uninterrupted original audio, collecting only the missing part of 4 s.
// Decodes the hint's +/-8 s neighborhood first; failed correlation widens the search. Complete files may
// search globally; growing FLAC expands only to +/-32 s. Retains the decoded window until another path or Stop(YES). Nil with *error when Spotify's sound does not match the file or the source changed.
NSDictionary *_Nullable SGLosslessAnchor(NSString *path, double hintSeconds, NSString *_Nullable *_Nonnull error);
// Off the main thread: the offset in frames between Spotify's sound and the file where the anchor puts it.
NSDictionary *_Nullable SGLosslessCheck(NSString *_Nullable *_Nonnull error);
// Spotify's own sound again; `release` also frees the decoded file.
void SGLosslessStop(BOOL release);
// Whether the file plays now: anchored, and nothing has changed the source since.
BOOL SGLosslessPlaying(void);
// Immutable decoder measurements (not provider hints); safe on main, no audio capture or I/O.
NSDictionary *SGLosslessSourceInfo(void);
// Whether this output actually received external frames within the last half second.
BOOL SGLosslessRendering(void);
NS_ASSUME_NONNULL_END
