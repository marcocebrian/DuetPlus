// DuetPlus core internals (platform-neutral).
#pragma once
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace duet {

constexpr double kSrcRate = 48000.0;  // all tracks are stored at 48 kHz stereo
constexpr int kSrcCh = 2;

int64_t nowNs();  // monotonic, same base the audio backends use

// Single-writer / many-reader seqlock for small POD structs (audio-thread safe).
template <typename T>
class SeqLock {
 public:
  void store(const T& v) {
    seq_.fetch_add(1, std::memory_order_acq_rel);
    std::atomic_thread_fence(std::memory_order_release);
    std::memcpy(&data_, &v, sizeof(T));
    std::atomic_thread_fence(std::memory_order_release);
    seq_.fetch_add(1, std::memory_order_acq_rel);
  }
  T load() const {
    T out;
    for (;;) {
      uint32_t s1 = seq_.load(std::memory_order_acquire);
      if (s1 & 1) continue;
      std::atomic_thread_fence(std::memory_order_acquire);
      std::memcpy(&out, &data_, sizeof(T));
      std::atomic_thread_fence(std::memory_order_acquire);
      if (seq_.load(std::memory_order_acquire) == s1) return out;
    }
  }

 private:
  std::atomic<uint32_t> seq_{0};
  T data_{};
};

// ---------------------------------------------------------------- clock sync
struct ClockModel {
  int64_t refLocal;  // local time the model is anchored at
  int64_t offset;    // master - local at refLocal
  double skew;       // d(offset)/d(local), dimensionless
};

class ClockSync {
 public:
  static ClockSync& get();
  bool startServer(int port);
  bool startClient(const std::string& ip, int port);
  void stop();
  int64_t toMaster(int64_t local) const {
    if (isMaster_.load(std::memory_order_relaxed)) return local;
    ClockModel m = model_.load();
    return local + m.offset + (int64_t)(m.skew * (double)(local - m.refLocal));
  }
  int64_t toLocal(int64_t master) const {  // inverse (skew is tiny)
    if (isMaster_.load(std::memory_order_relaxed)) return master;
    ClockModel m = model_.load();
    int64_t l = master - m.offset;
    return master - m.offset - (int64_t)(m.skew * (double)(l - m.refLocal));
  }
  void stats(int64_t* out5);
  bool isMaster() const { return isMaster_.load(); }

 private:
  struct Sample { int64_t mid, offset, rtt; };
  void serverLoop();
  void clientSendLoop();
  void clientRecvLoop();
  void addSample(const Sample& s);

  std::atomic<bool> isMaster_{true};
  std::atomic<bool> running_{false};
  int sock_ = -1;
  std::thread t1_, t2_;
  SeqLock<ClockModel> model_;
  std::mutex mu_;
  std::vector<Sample> samples_;
  int64_t bestRtt_ = 0;
  int nUsed_ = 0;
  bool locked_ = false;
  int64_t startedAt_ = 0;
};

// ---------------------------------------------------------------- track (PCM)
class Track {
 public:
  static constexpr int kBlockShift = 16;  // 65536 frames per block
  static constexpr int kBlockFrames = 1 << kBlockShift;
  static constexpr int kMaxBlocks = 8192;  // ~3 h

  Track();
  ~Track();
  bool startDecode(const std::string& path);
  void cancel();
  // Audio thread: returns sample or 0 if not decoded.
  inline float sample(int64_t frame, int ch) const {
    if (frame < 0 || frame >= decoded_.load(std::memory_order_acquire)) return 0.f;
    const float* b = blocks_[frame >> kBlockShift].load(std::memory_order_acquire);
    if (!b) return 0.f;
    return b[((frame & (kBlockFrames - 1)) << 1) + ch];
  }
  int64_t decoded() const { return decoded_.load(std::memory_order_acquire); }
  int64_t total() const { return total_.load(); }
  bool done() const { return done_.load(); }
  int error() const { return error_.load(); }

 private:
  void run(std::string path);
  bool decodeWebm(const std::vector<uint8_t>& data);
  bool decodeMiniaudio(const std::string& path);
  // Appends interleaved stereo frames.
  bool append(const float* inter, int64_t frames);

  std::atomic<const float*>* blocks_;
  std::atomic<int64_t> decoded_{0};
  std::atomic<int64_t> total_{0};
  std::atomic<bool> done_{false};
  std::atomic<int> error_{0};
  std::atomic<bool> cancel_{false};
  std::thread th_;
};

// ---------------------------------------------------------------- engine
struct Schedule {
  int32_t playing;
  int32_t gen;  // bumps on every change
  int64_t anchorFrame;
  int64_t anchorMaster;
  int64_t endMaster;
};

class Engine {
 public:
  static Engine& get();
  bool start(bool wantMic);
  void stop();

  // Called by backends from the realtime thread.
  // presentLocalNs = local time when out[0] reaches the speaker.
  void render(float* out, int frames, int channels, int64_t presentLocalNs, double rate);
  // captureLocalNs = local time when in[0] hit the microphone.
  void capture(const float* in, int frames, int64_t captureLocalNs, double rate);
  void setReportedLatencyNs(int64_t v) { reportedLatNs_.store(v); }

  // control
  void setTrack(Track* t);
  Track* track() const { return track_.load(); }
  void setSchedule(int playing, int64_t frame, int64_t atMaster, int64_t endMaster);
  void setLatencyFix(int64_t ns) { latencyFix_.store(ns); }
  int64_t latencyFix() const { return latencyFix_.load(); }
  void setVolume(float v) { volume_.store(v); }
  void chirpAt(int64_t masterNs) { chirpAt_.store(masterNs); }
  double position() const { return position_.load(); }
  struct Playhead { int64_t master; double frame; };
  Playhead playhead() const { return playhead_.load(); }
  void stats(double* out7);
  void spectrum(float* out, int bands);
  bool recordStart();
  void recordStop() { recording_.store(false); }
  int analyze(int64_t firstMaster, int count, int64_t spacing, int64_t* rel, double* conf);

 private:
  inline float srcSample(Track* t, double pos, int ch) const;
  float chirpValue(double tSec) const;

  std::atomic<Track*> track_{nullptr};
  SeqLock<Schedule> sched_;
  std::atomic<int32_t> schedGen_{0};
  std::atomic<int64_t> latencyFix_{0};
  std::atomic<float> volume_{1.f};
  std::atomic<int64_t> chirpAt_{0};
  std::atomic<double> position_{0};
  std::atomic<int64_t> reportedLatNs_{0};
  SeqLock<Playhead> playhead_;
  bool running_ = false;

  // realtime state (audio thread only)
  int32_t seenGen_ = -1;
  bool locked_ = false;
  double readPos_ = 0;
  double errF_ = 0;
  int fadeIn_ = 0;
  // stats (written by audio thread)
  std::atomic<double> statErrUs_{0}, statPpm_{0}, statRate_{0};
  std::atomic<int64_t> underruns_{0}, hardResyncs_{0}, callbacks_{0};

  // visuals
  static constexpr int kVisN = 2048;
  float vis_[kVisN] = {0};
  std::atomic<uint32_t> visW_{0};

  // recording
  std::vector<float> rec_;
  std::atomic<int64_t> recN_{0};
  std::atomic<bool> recording_{false};
  std::atomic<int64_t> recFirstLocal_{0};
  std::atomic<double> recRate_{48000};
};

// Platform backend (one implementation per OS).
// Platform decoder (host-side only, for formats we transcode). Sink gets
// interleaved float frames at the file's rate/channels; return false to abort.
using DecodeSink = std::function<bool(const float* x, int64_t frames, int rate, int ch)>;
bool platformDecodeFile(const std::string& path, const DecodeSink& sink, int64_t* totalFrames);
bool transcodeStart(const std::string& in, const std::string& out);
void transcodeStatus(int32_t* out3);
bool decodeDuop(const std::vector<uint8_t>& data, const std::function<void(const float*, int64_t)>& sink,
                std::atomic<int64_t>& total, const std::atomic<bool>& cancel);

bool backendStart(bool wantMic);
int backendMicPermission();
void backendMicRequest();
void backendStop();

}  // namespace duet
