// Android backend: AAudio. Presentation time comes from the DAC timestamp.
#include <aaudio/AAudio.h>
#include <fcntl.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <unistd.h>
#include <android/log.h>
#include <time.h>

#include "core.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "duet", __VA_ARGS__)

namespace duet {
namespace {

AAudioStream* g_out = nullptr;
AAudioStream* g_in = nullptr;
bool g_wantMic = false;
std::atomic<bool> g_restart{false};
std::thread g_watch;
std::atomic<bool> g_watchRun{false};

// Smoothed mapping frame -> time for the output stream.
struct OutState {
  bool haveTs = false;
  int64_t tsFrame = 0, tsTime = 0;
  int counter = 0;
} g_os;

aaudio_data_callback_result_t outCb(AAudioStream* s, void*, void* data, int32_t frames) {
  double rate = AAudioStream_getSampleRate(s);
  int64_t written = AAudioStream_getFramesWritten(s);
  // Refresh the hardware timestamp every few callbacks.
  if (!g_os.haveTs || (++g_os.counter & 7) == 0) {
    int64_t fp = 0, tn = 0;
    if (AAudioStream_getTimestamp(s, CLOCK_MONOTONIC, &fp, &tn) == AAUDIO_OK && fp > 0) {
      g_os.haveTs = true;
      g_os.tsFrame = fp;
      g_os.tsTime = tn;
    }
  }
  int64_t present;
  if (g_os.haveTs) {
    present = g_os.tsTime + (int64_t)((double)(written - g_os.tsFrame) * 1e9 / rate);
  } else {
    // Rough fallback until the first timestamp: assume one buffer of latency.
    int32_t buf = AAudioStream_getBufferSizeInFrames(s);
    present = nowNs() + (int64_t)((double)buf * 1e9 / rate);
  }
  int64_t now = nowNs();
  Engine::get().setReportedLatencyNs(present - now);
  Engine::get().render((float*)data, frames, AAudioStream_getChannelCount(s), present, rate);
  return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

aaudio_data_callback_result_t inCb(AAudioStream* s, void*, void* data, int32_t frames) {
  double rate = AAudioStream_getSampleRate(s);
  int64_t read = AAudioStream_getFramesRead(s);
  int64_t fp = 0, tn = 0;
  int64_t t;
  if (AAudioStream_getTimestamp(s, CLOCK_MONOTONIC, &fp, &tn) == AAUDIO_OK)
    t = tn + (int64_t)((double)(read - fp) * 1e9 / rate);
  else
    t = nowNs() - (int64_t)((double)frames * 1e9 / rate);
  Engine::get().capture((const float*)data, frames, t, rate);
  return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

void errCb(AAudioStream*, void*, aaudio_result_t err) {
  LOGI("stream error %d, restarting", err);
  g_restart = true;  // can't reopen from this callback
}

AAudioStream* open(bool input) {
  AAudioStreamBuilder* b = nullptr;
  if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) return nullptr;
  AAudioStreamBuilder_setDirection(b, input ? AAUDIO_DIRECTION_INPUT : AAUDIO_DIRECTION_OUTPUT);
  AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
  AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
  AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_FLOAT);
  AAudioStreamBuilder_setChannelCount(b, input ? 1 : 2);
  AAudioStreamBuilder_setSampleRate(b, 48000);
  if (input) {
    AAudioStreamBuilder_setInputPreset(b, AAUDIO_INPUT_PRESET_UNPROCESSED);
    AAudioStreamBuilder_setDataCallback(b, inCb, nullptr);
  } else {
    AAudioStreamBuilder_setUsage(b, AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setContentType(b, AAUDIO_CONTENT_TYPE_MUSIC);
    AAudioStreamBuilder_setDataCallback(b, outCb, nullptr);
  }
  AAudioStreamBuilder_setErrorCallback(b, errCb, nullptr);
  AAudioStream* s = nullptr;
  aaudio_result_t r = AAudioStreamBuilder_openStream(b, &s);
  AAudioStreamBuilder_delete(b);
  if (r != AAUDIO_OK) { LOGI("open %s failed %d", input ? "in" : "out", r); return nullptr; }
  if (!input) {
    // Two bursts of buffering: low latency but robust.
    AAudioStream_setBufferSizeInFrames(s, AAudioStream_getFramesPerBurst(s) * 2);
  }
  AAudioStream_requestStart(s);
  LOGI("%s stream: rate=%d burst=%d", input ? "in" : "out", AAudioStream_getSampleRate(s),
       AAudioStream_getFramesPerBurst(s));
  return s;
}

void closeAll() {
  if (g_out) { AAudioStream_requestStop(g_out); AAudioStream_close(g_out); g_out = nullptr; }
  if (g_in) { AAudioStream_requestStop(g_in); AAudioStream_close(g_in); g_in = nullptr; }
  g_os = OutState{};
}

void openAll() {
  g_out = open(false);
  if (g_wantMic) g_in = open(true);
}

}  // namespace

// MediaExtractor + MediaCodec: AAC/M4A/OGG/OPUS/MP3/FLAC/… via the NDK.
bool platformDecodeFile(const std::string& path, const DecodeSink& sink, int64_t* total) {
  int fd = ::open(path.c_str(), O_RDONLY);
  if (fd < 0) return false;
  off64_t size = lseek64(fd, 0, SEEK_END);
  AMediaExtractor* ex = AMediaExtractor_new();
  bool ok = false;
  AMediaCodec* codec = nullptr;
  if (AMediaExtractor_setDataSourceFd(ex, fd, 0, size) == AMEDIA_OK) {
    size_t n = AMediaExtractor_getTrackCount(ex);
    for (size_t i = 0; i < n && !codec; i++) {
      AMediaFormat* fmt = AMediaExtractor_getTrackFormat(ex, i);
      const char* mime = nullptr;
      if (AMediaFormat_getString(fmt, AMEDIAFORMAT_KEY_MIME, &mime) && mime && strncmp(mime, "audio/", 6) == 0) {
        AMediaExtractor_selectTrack(ex, i);
        int64_t durUs = 0;
        AMediaFormat_getInt64(fmt, AMEDIAFORMAT_KEY_DURATION, &durUs);
        *total = durUs * 48 / 1000;
        codec = AMediaCodec_createDecoderByType(mime);
        if (codec && (AMediaCodec_configure(codec, fmt, nullptr, nullptr, 0) != AMEDIA_OK ||
                      AMediaCodec_start(codec) != AMEDIA_OK)) {
          AMediaCodec_delete(codec);
          codec = nullptr;
        }
      }
      AMediaFormat_delete(fmt);
    }
  }
  if (codec) {
    int32_t rate = 44100, ch = 2, enc = 2;  // 2 = PCM 16-bit, 4 = float
    AMediaFormat* of = AMediaCodec_getOutputFormat(codec);
    AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_SAMPLE_RATE, &rate);
    AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &ch);
    AMediaFormat_getInt32(of, "pcm-encoding", &enc);
    AMediaFormat_delete(of);
    std::vector<float> fbuf;
    bool inEos = false, aborted = false;
    ok = true;
    for (int idle = 0; idle < 500;) {
      if (!inEos) {
        ssize_t ii = AMediaCodec_dequeueInputBuffer(codec, 5000);
        if (ii >= 0) {
          size_t cap = 0;
          uint8_t* b = AMediaCodec_getInputBuffer(codec, ii, &cap);
          ssize_t got = AMediaExtractor_readSampleData(ex, b, cap);
          if (got < 0) {
            AMediaCodec_queueInputBuffer(codec, ii, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
            inEos = true;
          } else {
            AMediaCodec_queueInputBuffer(codec, ii, 0, got, AMediaExtractor_getSampleTime(ex), 0);
            AMediaExtractor_advance(ex);
          }
        }
      }
      AMediaCodecBufferInfo info;
      ssize_t oi = AMediaCodec_dequeueOutputBuffer(codec, &info, 5000);
      if (oi >= 0) {
        idle = 0;
        size_t sz = 0;
        uint8_t* d = AMediaCodec_getOutputBuffer(codec, oi, &sz);
        if (d && info.size > 0 && ch > 0) {
          const uint8_t* p = d + info.offset;
          if (enc == 4) {
            int64_t frames = info.size / (4 * ch);
            fbuf.assign((const float*)p, (const float*)p + frames * ch);
          } else {
            int64_t frames = info.size / (2 * ch);
            fbuf.resize(frames * ch);
            const int16_t* s = (const int16_t*)p;
            for (int64_t k = 0; k < frames * ch; k++) fbuf[k] = s[k] / 32768.f;
          }
          if (!sink(fbuf.data(), (int64_t)(fbuf.size() / ch), rate, ch)) aborted = true;
        }
        AMediaCodec_releaseOutputBuffer(codec, oi, false);
        if ((info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) || aborted) break;
      } else if (oi == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
        AMediaFormat* f2 = AMediaCodec_getOutputFormat(codec);
        AMediaFormat_getInt32(f2, AMEDIAFORMAT_KEY_SAMPLE_RATE, &rate);
        AMediaFormat_getInt32(f2, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &ch);
        AMediaFormat_getInt32(f2, "pcm-encoding", &enc);
        AMediaFormat_delete(f2);
      } else if (inEos) {
        idle++;
      }
    }
    if (aborted) ok = false;
    AMediaCodec_stop(codec);
    AMediaCodec_delete(codec);
  }
  AMediaExtractor_delete(ex);
  ::close(fd);
  return ok;
}

int backendMicPermission() { return 2; }
void backendMicRequest() {}

bool backendStart(bool wantMic) {
  g_wantMic = wantMic;
  openAll();
  g_watchRun = true;
  g_watch = std::thread([] {
    while (g_watchRun) {
      if (g_restart.exchange(false)) { closeAll(); openAll(); }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  });
  return g_out != nullptr;
}

void backendStop() {
  g_watchRun = false;
  if (g_watch.joinable()) g_watch.join();
  closeAll();
}

}  // namespace duet
