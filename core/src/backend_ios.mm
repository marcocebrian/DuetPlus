// iOS backend: RemoteIO AudioUnit. Presentation time = buffer host time +
// AVAudioSession.outputLatency (same convention as Ableton Link).
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>

#include "core.h"

namespace duet {
namespace {

AudioUnit g_unit = nullptr;
bool g_mic = false;
double g_rate = 48000;
std::atomic<int64_t> g_outLatNs{0};
std::atomic<int64_t> g_inLatNs{0};
mach_timebase_info_data_t g_tb;
std::vector<float> g_inBuf;
id g_routeObs = nil;
id g_intrObs = nil;

inline int64_t hostToNs(uint64_t h) { return (int64_t)((__uint128_t)h * g_tb.numer / g_tb.denom); }

void refreshLatency() {
  AVAudioSession* s = [AVAudioSession sharedInstance];
  g_outLatNs = (int64_t)(s.outputLatency * 1e9);
  g_inLatNs = (int64_t)(s.inputLatency * 1e9);
}

OSStatus renderCb(void*, AudioUnitRenderActionFlags*, const AudioTimeStamp* ts, UInt32,
                  UInt32 frames, AudioBufferList* io) {
  int64_t present = hostToNs(ts->mHostTime) + g_outLatNs.load(std::memory_order_relaxed);
  Engine::get().setReportedLatencyNs(present - nowNs());
  float* out = (float*)io->mBuffers[0].mData;
  Engine::get().render(out, (int)frames, 2, present, g_rate);
  return noErr;
}

OSStatus inputCb(void*, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus,
                 UInt32 frames, AudioBufferList*) {
  if (g_inBuf.size() < frames) return noErr;  // never allocate on the audio thread
  AudioBufferList bl;
  bl.mNumberBuffers = 1;
  bl.mBuffers[0].mNumberChannels = 1;
  bl.mBuffers[0].mDataByteSize = frames * sizeof(float);
  bl.mBuffers[0].mData = g_inBuf.data();
  if (AudioUnitRender(g_unit, flags, ts, bus, frames, &bl) != noErr) return noErr;
  int64_t t = hostToNs(ts->mHostTime) - g_inLatNs.load(std::memory_order_relaxed);
  Engine::get().capture(g_inBuf.data(), (int)frames, t, g_rate);
  return noErr;
}

bool openUnit() {
  AudioComponentDescription d{kAudioUnitType_Output, kAudioUnitSubType_RemoteIO,
                              kAudioUnitManufacturer_Apple, 0, 0};
  AudioComponent c = AudioComponentFindNext(nullptr, &d);
  if (!c || AudioComponentInstanceNew(c, &g_unit) != noErr) return false;
  UInt32 one = 1;
  AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one,
                       sizeof(one));
  if (g_mic)
    AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one,
                         sizeof(one));

  AudioStreamBasicDescription f{};
  f.mSampleRate = g_rate;
  f.mFormatID = kAudioFormatLinearPCM;
  f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  f.mFramesPerPacket = 1;
  f.mChannelsPerFrame = 2;
  f.mBitsPerChannel = 32;
  f.mBytesPerFrame = f.mBytesPerPacket = 8;
  AudioUnitSetProperty(g_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f,
                       sizeof(f));
  AURenderCallbackStruct rcb{renderCb, nullptr};
  AudioUnitSetProperty(g_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                       &rcb, sizeof(rcb));
  if (g_mic) {
    AudioStreamBasicDescription m = f;
    m.mChannelsPerFrame = 1;
    m.mBytesPerFrame = m.mBytesPerPacket = 4;
    AudioUnitSetProperty(g_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &m,
                         sizeof(m));
    AURenderCallbackStruct icb{inputCb, nullptr};
    AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_SetInputCallback,
                         kAudioUnitScope_Global, 0, &icb, sizeof(icb));
    g_inBuf.assign(8192, 0.f);
  }
  UInt32 maxFrames = 4096;
  AudioUnitSetProperty(g_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                       &maxFrames, sizeof(maxFrames));
  if (AudioUnitInitialize(g_unit) != noErr) return false;
  return AudioOutputUnitStart(g_unit) == noErr;
}

void closeUnit() {
  if (!g_unit) return;
  AudioOutputUnitStop(g_unit);
  AudioUnitUninitialize(g_unit);
  AudioComponentInstanceDispose(g_unit);
  g_unit = nullptr;
}

}  // namespace

// ExtAudioFile decodes AAC/ALAC/MP3/WAV/AIFF/CAF… and resamples for us.
bool platformDecodeFile(const std::string& path, const DecodeSink& sink, int64_t* total) {
  @autoreleasepool {
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    ExtAudioFileRef f = nullptr;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &f) != noErr || !f) return false;
    AudioStreamBasicDescription src{};
    UInt32 sz = sizeof(src);
    ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &sz, &src);
    AudioStreamBasicDescription c{};
    c.mSampleRate = 48000;
    c.mFormatID = kAudioFormatLinearPCM;
    c.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    c.mFramesPerPacket = 1;
    c.mChannelsPerFrame = 2;
    c.mBitsPerChannel = 32;
    c.mBytesPerFrame = c.mBytesPerPacket = 8;
    if (ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(c), &c) != noErr) {
      ExtAudioFileDispose(f);
      return false;
    }
    SInt64 frames = 0;
    sz = sizeof(frames);
    ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileLengthFrames, &sz, &frames);
    *total = src.mSampleRate > 0 ? (int64_t)(frames * 48000.0 / src.mSampleRate) : 0;
    std::vector<float> buf(4096 * 2);
    bool ok = true;
    for (;;) {
      AudioBufferList bl;
      bl.mNumberBuffers = 1;
      bl.mBuffers[0].mNumberChannels = 2;
      bl.mBuffers[0].mDataByteSize = (UInt32)(buf.size() * sizeof(float));
      bl.mBuffers[0].mData = buf.data();
      UInt32 n = 4096;
      if (ExtAudioFileRead(f, &n, &bl) != noErr) { ok = false; break; }
      if (n == 0) break;
      if (!sink(buf.data(), n, 48000, 2)) { ok = false; break; }
    }
    ExtAudioFileDispose(f);
    return ok;
  }
}

int backendMicPermission() {
  switch ([AVAudioSession sharedInstance].recordPermission) {
    case AVAudioSessionRecordPermissionGranted: return 2;
    case AVAudioSessionRecordPermissionDenied: return 1;
    default: return 0;
  }
}

void backendMicRequest() {
  [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL) {}];
}

bool backendStart(bool wantMic) {
  mach_timebase_info(&g_tb);
  AVAudioSession* s = [AVAudioSession sharedInstance];
#if TARGET_OS_SIMULATOR
  wantMic = false;  // simulator audio server times out on RemoteIO input
#endif
  if (wantMic && s.recordPermission != AVAudioSessionRecordPermissionGranted) wantMic = false;
  g_mic = wantMic;
  NSError* err = nil;
  if (wantMic) {
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
              mode:AVAudioSessionModeDefault
           options:AVAudioSessionCategoryOptionDefaultToSpeaker
             error:&err];
  } else {
    [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&err];
  }
  [s setPreferredSampleRate:48000 error:&err];
  [s setPreferredIOBufferDuration:0.005 error:&err];
  [s setActive:YES error:&err];
  if (g_mic && !s.isInputAvailable) g_mic = false;
  g_rate = s.sampleRate > 0 ? s.sampleRate : 48000;
  refreshLatency();

  NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
  if (!g_routeObs) {
    g_routeObs = [nc addObserverForName:AVAudioSessionRouteChangeNotification
                                 object:nil
                                  queue:nil
                             usingBlock:^(NSNotification*) { refreshLatency(); }];
    g_intrObs = [nc addObserverForName:AVAudioSessionInterruptionNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification* n) {
                              NSUInteger type =
                                  [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                              if (type == AVAudioSessionInterruptionTypeEnded) {
                                [[AVAudioSession sharedInstance] setActive:YES error:nil];
                                if (g_unit) AudioOutputUnitStart(g_unit);
                              }
                            }];
  }
  if (!openUnit()) { closeUnit(); return false; }
  return true;
}

void backendStop() { closeUnit(); }

}  // namespace duet
