#import <Foundation/Foundation.h>

// Local assembled fMP4 only. Verify every source format is lossless stereo before decoding.
// Produces integer PCM WAV at the measured source rate/depth; never fetches network URLs.
BOOL SGDecodeSegmentedLossless(NSString *input, NSString *output, BOOL (^cancelled)(void));
