// Five-stage pipeline and measured/claimed separation ported from the supplied
// BitChord 1.0.2-kr-proxy.24 NerdStats.swift / AudioPipeline.swift (GPL-3.0).
#import "SGAddons.h"
#import "SGStandalonePlayback.h"
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Lossless/SGWiredOutput.h"
#import "Shared/Lossless/LosslessQuality.h"
#import "Shared/AudioEffects/AudioEffects.h"
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
    double fileBitrate = [measured[@"averageKbps"] doubleValue];
    NSMutableArray *line = [NSMutableArray array];
    if (measured[@"codec"]) [line addObject:measured[@"codec"]];
    if (bits.intValue > 0) [line addObject:[NSString stringWithFormat:@"%@-bit",bits]];
    if (rate.doubleValue > 0) [line addObject:[NSString stringWithFormat:@"%.1f kHz",rate.doubleValue/1000]];
    if (fileBitrate > 0) [line addObject:[NSString stringWithFormat:@"평균 %.0f kbps",fileBitrate]];
    if (channels.intValue) [line addObject:channels.intValue==2 ? @"스테레오" : channels.intValue==1 ? @"Mono" : [NSString stringWithFormat:@"%@ ch",channels]];
    BOOL downgraded = ([claimed[@"sampleRate"] doubleValue] > rate.doubleValue && rate.doubleValue>0) || ([claimed[@"bitDepth"] intValue] > bits.intValue && bits.intValue>0);
    if (downgraded) [line addObject:[NSString stringWithFormat:@"↓ from %@ · %@ · %@", claimed[@"codec"] ?: @"source claim", number(claimed[@"bitDepth"], @"bit"), number(claimed[@"sampleRate"], @"Hz")]];
    AudioStreamBasicDescription f={0}; BOOL independent=SGStandaloneActive();
    BOOL local = independent ? SGStandaloneOutputFormat(&f) : SGPlayerMusicClientFormat(&f);
    AVAudioSession *session=AVAudioSession.sharedInstance;
    BOOL spotifyPCM = !measured.count && local && SGPlayerState().isPlaying;
    if (spotifyPCM) {
        [line addObject:[NSString stringWithFormat:@"Spotify 출력 PCM · %.1f kHz · %u ch", f.mSampleRate/1000, (unsigned)f.mChannelsPerFrame]];
    }
    NSInteger metered = 0, nonMetered = 0;
    BOOL configured = SGStreamQuality(&metered, &nonMetered);
    // Spotify's levels are enums, not measured kbps. Do not turn these values into a codec or bitrate.
    NSString *preference = configured ? [NSString stringWithFormat:@"셀룰러 단계 %ld / Wi-Fi 단계 %ld · 실제 비트레이트 아님", (long)metered, (long)nonMetered] : @"설정 아직 읽지 못함";
    double rendered=local ? f.mSampleRate : 0, hardware=session.sampleRate;
    BOOL resampled=rate.doubleValue>0 && rendered>0 && fabs(rate.doubleValue-rendered)>1;
    NSString *io= [NSString stringWithFormat:@"%@ → %@",number(rate,@"Hz"), rendered>0 ? number(@(rendered),@"Hz") : @"—"];
    NSString *pcm=local ? [NSString stringWithFormat:@"%u-bit %@ · %u ch",(unsigned)f.mBitsPerChannel,(f.mFormatFlags & kAudioFormatFlagIsFloat)?@"Float":@"PCM",(unsigned)f.mChannelsPerFrame] : @"—";
    NSString *verdict=@"확인 불가 · 전체 경로의 비트 일치는 측정하지 않음";
    double gain=[measured[@"gain"] doubleValue];
    if (gain>0 && fabs(gain-1)>0.0001) verdict=@"아니요 · 음량 보정";
    else if (fabs(SGPlayerSpeed()-1)>0.001 || fabs(SGPlayerPitch())>0.001) verdict=@"아니요 · 속도 / 피치 처리";
    else if (SGSingOn() || SGPlayerReverb()>0) verdict=@"아니요 · 오디오 처리";
    else if (SGFlag(SGKeyDSP, NO)) verdict=@"확인 불가 · 오디오 효과가 켜져 있음";
    else if (resampled) verdict=@"아니요 · 앱 리샘플링";
    else if (rendered>0 && hardware>0 && fabs(rendered-hardware)>1) verdict=@"아니요 · iOS 샘플레이트 변환";
    NSMutableArray *routes=[NSMutableArray array];
    for (AVAudioSessionPortDescription *p in session.currentRoute.outputs) [routes addObject:p.portName];
    NSString *system=rendered>0 && hardware>0 ? (fabs(rendered-hardware)<1 ? @"레이트 유지" : @"iOS에서 변환됨") : @"—";
    return @{@"statsLine":line.count ? [line componentsJoinedByString:@" · "] : @"선택한 소스의 디코더 측정값 없음",
      @"playing":@(SGPlayerState().isPlaying && !SGPlayerState().isPaused),
      @"diagnostic":SGAddonStatus(), @"stages":@[
        stage(@"곡 정보",@"doc",@[
          row(@"소스",measured.count ? prepared[@"sourceName"] ?: @"로컬 저장 공간" : @"Spotify 기본 스트림"),
          row(@"형식",measured[@"codec"]),row(@"비트 깊이",number(bits,@"bit")),row(@"샘플레이트",number(rate,@"Hz")),
          row(@"비트레이트",fileBitrate>0 ? [NSString stringWithFormat:@"파일 평균 %.0f kbps",fileBitrate] : @"—"),
          row(@"PCM 환산 비트레이트",bitrate>0 ? [NSString stringWithFormat:@"%.0f kbps",bitrate] : @"—"),row(@"채널",channels.intValue==2 ? @"스테레오" : number(channels,@"ch")),
          row(@"공급자 주장",[NSString stringWithFormat:@"%@ · %@",number(claimed[@"bitDepth"],@"bit"),number(claimed[@"sampleRate"],@"Hz")]),
          row(@"Spotify 품질 설정",preference),
          row(@"기본 스트림 형식",measured.count ? @"해당 없음" : @"코덱·원본 레이트·비트 깊이·압축 비트레이트 확인 불가")]),
        stage(@"Decoder",@"cpu",@[
          row(@"디코더 이름",measured.count ? independent ? @"Apple ExtAudioFile → AVAudioEngine" : @"Apple ExtAudioFile / AudioConverter" : @"Spotify 디코더 · 정보 미제공"),row(@"실제 출력 PCM",local ? pcm : nil),
          row(@"측정 위치",local ? (independent ? @"자체 엔진 믹서 출력 · 압축 원본 형식과 별개" : @"활성 RemoteIO 입력 · 압축 원본 형식과 별개") : @"확인 불가")]),
        stage(@"Resampler",@"slider.horizontal.3",@[
          row(@"입출력 레이트",io),row(@"종류",rate.doubleValue>0 && rendered>0 ? (resampled ? @"Resampler" : @"없음") : @"—"),row(@"차단 주파수",nil),row(@"음질",rate.doubleValue>0 && rendered>0 ? (resampled ? @"리샘플링됨" : @"원본 유지") : @"—")]),
        stage(@"DSP",@"waveform",@[
          row(@"PCM 형식",pcm),row(@"샘플레이트",rendered>0 ? number(@(rendered),@"Hz") : nil),
          row(@"게인",gain>0 ? [NSString stringWithFormat:@"%+.2f dB",20*log10(gain)] : nil),row(@"측정값",nil),row(@"EQ 프리셋",@"측정되지 않음"),row(@"스테레오 확장",@"측정되지 않음"),
          row(@"속도",[NSString stringWithFormat:@"%.2f× / %+.1f st",SGPlayerSpeed(),SGPlayerPitch()]),row(@"버퍼",nil),row(@"출력 API",local ? (independent ? @"AVAudioEngine / AVAudioPlayerNode" : @"AudioUnit RemoteIO") : nil),row(@"Bit-exact",verdict)]),
        stage(@"출력 기기",@"speaker.wave.2",@[
          row(@"기기 이름",routes.count ? [routes componentsJoinedByString:@", "] : nil),row(@"출력 경로",session.currentRoute.outputs.firstObject.portType),
          row(@"샘플레이트",hardware>0 ? number(@(hardware),@"Hz") : nil),row(@"채널",number(@(session.outputNumberOfChannels),@"ch")),row(@"시스템",system),row(@"유선 원본 출력",independent ? @"자체 엔진 · 출력 레이트 확인 필요" : SGWiredOutputStatus()[@"state"]),row(@"지연",[NSString stringWithFormat:@"%.0f ms",session.outputLatency*1000])])
      ]};
}
