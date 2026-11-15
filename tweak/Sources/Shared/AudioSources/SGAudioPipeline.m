// Five-stage pipeline and measured/claimed separation ported from the supplied
// BitChord 1.0.2-kr-proxy.24 NerdStats.swift / AudioPipeline.swift (GPL-3.0).
#import "SGAddons.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Lossless/SGWiredOutput.h"
#import "Shared/Sing/Sing.h"
#import <AVFoundation/AVFoundation.h>

static NSDictionary *row(NSString *label, NSString *value) { return @{@"label":label, @"value":value ?: @"—"}; }
static NSString *number(id v, NSString *unit) { return [v doubleValue] > 0 ? [NSString stringWithFormat:@"%@ %@", v, unit] : @"—"; }
static NSDictionary *stage(NSString *title, NSString *symbol, NSArray *rows) { return @{@"title":title,@"symbol":symbol,@"rows":rows}; }
NSDictionary *SGAudioPipelineSnapshot(void) {
    // BitChord binds measurements to the playing item. Here the source epoch and
    // recent render proof must agree; prepared provider hints never become measurements.
    NSDictionary *measured = SGLosslessRendering() ? SGLosslessSourceInfo() : @{};
    NSDictionary *prepared = SGAddonMediaInfo();
    NSDictionary *claimed = prepared[@"declared"] ?: @{};
    NSNumber *bits = measured[@"bits"], *rate = measured[@"rate"], *channels = measured[@"channels"];
    double bitrate = rate.doubleValue * bits.doubleValue * channels.doubleValue / 1000;
    NSMutableArray *line = [NSMutableArray array];
    if (measured[@"codec"]) [line addObject:measured[@"codec"]];
    if (bits.intValue > 0) [line addObject:[NSString stringWithFormat:@"%@-bit",bits]];
    if (rate.doubleValue > 0) [line addObject:[NSString stringWithFormat:@"%.1f kHz",rate.doubleValue/1000]];
    if (bitrate > 0) [line addObject:[NSString stringWithFormat:@"%.0f kbps",bitrate]];
    if (channels.intValue) [line addObject:channels.intValue==2 ? @"Stereo" : channels.intValue==1 ? @"Mono" : [NSString stringWithFormat:@"%@ ch",channels]];
    BOOL downgraded = ([claimed[@"sampleRate"] doubleValue] > rate.doubleValue && rate.doubleValue>0) || ([claimed[@"bitDepth"] intValue] > bits.intValue && bits.intValue>0);
    if (downgraded) [line addObject:[NSString stringWithFormat:@"↓ from %@ · %@ · %@", claimed[@"codec"] ?: @"source claim", number(claimed[@"bitDepth"], @"bit"), number(claimed[@"sampleRate"], @"Hz")]];
    AudioStreamBasicDescription f={0}; BOOL local = SGPlayerMusicClientFormat(&f);
    AVAudioSession *session=AVAudioSession.sharedInstance;
    double rendered=local ? f.mSampleRate : 0, hardware=session.sampleRate;
    BOOL resampled=rate.doubleValue>0 && rendered>0 && fabs(rate.doubleValue-rendered)>1;
    NSString *io= [NSString stringWithFormat:@"%@ → %@",number(rate,@"Hz"), rendered>0 ? number(@(rendered),@"Hz") : @"—"];
    NSString *pcm=local ? [NSString stringWithFormat:@"%u-bit %@ · %u ch",(unsigned)f.mBitsPerChannel,(f.mFormatFlags & kAudioFormatFlagIsFloat)?@"Float":@"PCM",(unsigned)f.mChannelsPerFrame] : @"—";
    NSString *verdict=@"Unknown — complete bit transparency is not measured";
    double gain=[measured[@"gain"] doubleValue];
    if (gain>0 && fabs(gain-1)>0.0001) verdict=@"No — level correction";
    else if (fabs(SGPlayerSpeed()-1)>0.001 || fabs(SGPlayerPitch())>0.001) verdict=@"No — speed / pitch processing";
    else if (SGSingOn() || SGPlayerReverb()>0) verdict=@"No — audio processing";
    else if (resampled) verdict=@"No — app resampling";
    else if (rendered>0 && hardware>0 && fabs(rendered-hardware)>1) verdict=@"No — iOS sample rate conversion";
    NSMutableArray *routes=[NSMutableArray array];
    for (AVAudioSessionPortDescription *p in session.currentRoute.outputs) [routes addObject:p.portName];
    NSString *system=rendered>0 && hardware>0 ? (fabs(rendered-hardware)<1 ? @"Passthrough rate" : @"iOS에서 변환됨") : @"—";
    return @{@"statsLine":line.count ? [line componentsJoinedByString:@" · "] : @"No decoder measurement for the selected source",
      @"playing":@(SGPlayerState().isPlaying && !SGPlayerState().isPaused),
      @"diagnostic":SGAddonStatus(), @"stages":@[
        stage(@"Track Info",@"doc",@[
          row(@"소스",measured.count ? prepared[@"sourceName"] ?: @"Local Storage" : @"Spotify · format not exposed"),
          row(@"Format",measured[@"codec"]),row(@"비트 깊이",number(bits,@"bit")),row(@"Sample Rate",number(rate,@"Hz")),
          row(@"Bitrate",bitrate>0 ? [NSString stringWithFormat:@"%.0f kbps",bitrate] : @"—"),row(@"Channels",channels.intValue==2 ? @"Stereo" : number(channels,@"ch")),
          row(@"Source claim",[NSString stringWithFormat:@"%@ · %@",number(claimed[@"bitDepth"],@"bit"),number(claimed[@"sampleRate"],@"Hz")])]),
        stage(@"Decoder",@"cpu",@[
          row(@"디코더 이름",measured.count ? @"Apple ExtAudioFile / AudioConverter" : @"Spotify decoder · not exposed"),row(@"Format",measured.count ? pcm : nil)]),
        stage(@"Resampler",@"slider.horizontal.3",@[
          row(@"I/O Rate",io),row(@"Type",rate.doubleValue>0 && rendered>0 ? (resampled ? @"Resampler" : @"없음") : @"—"),row(@"Cutoff",nil),row(@"음질",rate.doubleValue>0 && rendered>0 ? (resampled ? @"Resampled" : @"Passthrough") : @"—")]),
        stage(@"DSP",@"waveform",@[
          row(@"PCM Format",pcm),row(@"Sample Rate",rendered>0 ? number(@(rendered),@"Hz") : nil),
          row(@"Gain",gain>0 ? [NSString stringWithFormat:@"%+.2f dB",20*log10(gain)] : nil),row(@"Measured",nil),row(@"EQ Preset",@"Not measured"),row(@"Stereo Expand",@"Not measured"),
          row(@"속도",[NSString stringWithFormat:@"%.2f× / %+.1f st",SGPlayerSpeed(),SGPlayerPitch()]),row(@"Buffers",nil),row(@"Output API",local ? @"AudioUnit RemoteIO" : nil),row(@"Bit-exact",verdict)]),
        stage(@"Output Device",@"speaker.wave.2",@[
          row(@"기기 이름",routes.count ? [routes componentsJoinedByString:@", "] : nil),row(@"Route",session.currentRoute.outputs.firstObject.portType),
          row(@"Sample Rate",hardware>0 ? number(@(hardware),@"Hz") : nil),row(@"Channels",number(@(session.outputNumberOfChannels),@"ch")),row(@"System",system),row(@"유선 원본 출력",SGWiredOutputStatus()[@"state"]),row(@"Latency",[NSString stringWithFormat:@"%.0f ms",session.outputLatency*1000])])
      ]};
}
