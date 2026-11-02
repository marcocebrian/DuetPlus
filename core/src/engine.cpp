// Playout engine: turns (schedule, clock model, presentation timestamps) into
// sample-accurate output. Platform-neutral; backends only supply buffers and
// the local time at which the buffer's first frame will reach the speaker.
#include <algorithm>
#include <complex>

#include "core.h"

namespace duet {

namespace {
constexpr double kHardResyncSec = 0.020;  // beyond this we jump instead of slewing
constexpr double kMaxSlew = 0.001;        // +-1000 ppm max rate correction
constexpr double kSlewTau = 0.5;          // seconds to remove an error
constexpr double kChirpSec = 0.040;
constexpr double kChirpF0 = 1500, kChirpF1 = 7000;
constexpr int kFadeFrames = 256;
}  // namespace

Engine& Engine::get() {
  static Engine e;
  return e;
}

bool Engine::start(bool wantMic) {
  if (running_) backendStop();
  running_ = backendStart(wantMic);
  return running_;
}

void Engine::stop() {
  if (running_) backendStop();
  running_ = false;
}

void Engine::setTrack(Track* t) {
  Track* old = track_.exchange(t);
  if (old && old != t) {
    // Let the audio thread finish any callback using the old track.
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    delete old;
  }
}

void Engine::setSchedule(int playing, int64_t frame, int64_t atMaster, int64_t endMaster) {
  int32_t g = schedGen_.fetch_add(1) + 1;
  sched_.store(Schedule{playing, g, frame, atMaster, endMaster});
  if (!playing) position_.store((double)frame);
}

float Engine::chirpValue(double t) const {
  if (t < 0 || t >= kChirpSec) return 0.f;
  double k = (kChirpF1 - kChirpF0) / kChirpSec;
  double ph = 2 * M_PI * (kChirpF0 * t + 0.5 * k * t * t);
  double w = 0.5 - 0.5 * std::cos(2 * M_PI * t / kChirpSec);
  return (float)(0.9 * w * std::sin(ph));
}

inline float Engine::srcSample(Track* t, double pos, int ch) const {
  // Catmull-Rom cubic interpolation.
  int64_t i = (int64_t)std::floor(pos);
  float f = (float)(pos - (double)i);
  float y0 = t->sample(i - 1, ch), y1 = t->sample(i, ch), y2 = t->sample(i + 1, ch),
        y3 = t->sample(i + 2, ch);
  float a = -0.5f * y0 + 1.5f * y1 - 1.5f * y2 + 0.5f * y3;
  float b = y0 - 2.5f * y1 + 2.f * y2 - 0.5f * y3;
  float c = -0.5f * y0 + 0.5f * y2;
  return ((a * f + b) * f + c) * f + y1;
}

void Engine::render(float* out, int frames, int channels, int64_t presentLocalNs, double rate) {
  callbacks_.fetch_add(1, std::memory_order_relaxed);
  statRate_.store(rate, std::memory_order_relaxed);
  memset(out, 0, sizeof(float) * frames * channels);

  ClockSync& clk = ClockSync::get();
  // Real presentation = reported presentation + acoustic correction.
  int64_t masterStart = clk.toMaster(presentLocalNs + latencyFix_.load(std::memory_order_relaxed));
  double nsPerFrame = 1e9 / rate;
  Schedule s = sched_.load();
  Track* t = track_.load(std::memory_order_acquire);
  float vol = volume_.load(std::memory_order_relaxed);

  if (s.gen != seenGen_) { seenGen_ = s.gen; locked_ = false; }

  int first = 0;  // first output frame that plays music
  int last = 0;   // one past
  double step = kSrcRate / rate;
  if (s.playing && t) {
    int64_t bufEnd = masterStart + (int64_t)(frames * nsPerFrame);
    if (bufEnd > s.anchorMaster && masterStart < s.endMaster) {
      if (masterStart < s.anchorMaster) {
        first = std::min(frames, (int)std::ceil((s.anchorMaster - masterStart) / nsPerFrame));
        // Exact sub-sample start position for that frame.
        double tf = (double)(masterStart - s.anchorMaster) + first * nsPerFrame;
        readPos_ = (double)s.anchorFrame + tf * kSrcRate / 1e9;
        locked_ = true;
        errF_ = 0;
        fadeIn_ = 0;
      } else {
        double target = (double)s.anchorFrame + (double)(masterStart - s.anchorMaster) * kSrcRate / 1e9;
        if (!locked_) {
          readPos_ = target;
          locked_ = true;
          errF_ = 0;
          fadeIn_ = kFadeFrames;
        }
        double err = target - readPos_;  // frames; >0 = we are behind
        errF_ = errF_ * 0.85 + err * 0.15;
        if (std::fabs(err) > kHardResyncSec * kSrcRate) {
          readPos_ = target;
          errF_ = 0;
          fadeIn_ = kFadeFrames;
          hardResyncs_.fetch_add(1, std::memory_order_relaxed);
        }
        double slew = std::clamp(errF_ / kSrcRate / kSlewTau, -kMaxSlew, kMaxSlew);
        step *= (1.0 + slew);
        statErrUs_.store(errF_ / kSrcRate * 1e6, std::memory_order_relaxed);
        statPpm_.store(slew * 1e6, std::memory_order_relaxed);
      }
      last = frames;
      if (bufEnd > s.endMaster)
        last = std::max(first, (int)std::floor((s.endMaster - masterStart) / nsPerFrame));
    }
  }

  // Music
  if (last > first) {
    playhead_.store(Playhead{masterStart + (int64_t)(first * nsPerFrame), readPos_});
  } else {
    playhead_.store(Playhead{masterStart, -1});
  }
  if (last > first) {
    int64_t total = t->done() ? t->decoded() : INT64_MAX;
    if (readPos_ + 2 >= (double)t->decoded() && !t->done()) underruns_.fetch_add(1, std::memory_order_relaxed);
    for (int i = first; i < last; i++) {
      float g = vol;
      if (fadeIn_ > 0) { g *= 1.f - (float)fadeIn_ / kFadeFrames; fadeIn_--; }
      int toEnd = last - i;
      if (last < frames && toEnd < kFadeFrames) g *= (float)toEnd / kFadeFrames;
      if (readPos_ < (double)total) {
        float l = srcSample(t, readPos_, 0), r = srcSample(t, readPos_, 1);
        if (channels >= 2) { out[i * channels] = l * g; out[i * channels + 1] = r * g; }
        else out[i] = 0.5f * (l + r) * g;
      }
      readPos_ += step;
    }
    // Position as heard at the start of this buffer.
    position_.store(readPos_ - (last - first) * step, std::memory_order_relaxed);
  } else if (!s.playing) {
    locked_ = false;
  }

  // Visual tap (pre-chirp mono)
  uint32_t w = visW_.load(std::memory_order_relaxed);
  for (int i = 0; i < frames; i++) {
    float m = channels >= 2 ? 0.5f * (out[i * channels] + out[i * channels + 1]) : out[i];
    vis_[(w + i) & (kVisN - 1)] = m;
  }
  visW_.store(w + frames, std::memory_order_relaxed);

  // Chirp (acoustic sync check), scheduled in master time.
  int64_t ca = chirpAt_.load(std::memory_order_relaxed);
  if (ca > 0) {
    double t0 = (double)(masterStart - ca) / 1e9;
    double dt = 1.0 / rate;
    if (t0 + frames * dt >= 0 && t0 < kChirpSec) {
      for (int i = 0; i < frames; i++) {
        float v = chirpValue(t0 + i * dt);
        for (int c = 0; c < channels; c++) out[i * channels + c] += v;
      }
    }
    if (t0 > kChirpSec) chirpAt_.compare_exchange_strong(ca, 0);
  }
}

void Engine::capture(const float* in, int frames, int64_t captureLocalNs, double rate) {
  if (!recording_.load(std::memory_order_relaxed)) return;
  int64_t n = recN_.load(std::memory_order_relaxed);
  if (n == 0) { recFirstLocal_.store(captureLocalNs); recRate_.store(rate); }
  int64_t cap = (int64_t)rec_.size();
  int64_t k = std::min<int64_t>(frames, cap - n);
  if (k > 0) memcpy(rec_.data() + n, in, k * sizeof(float));
  recN_.store(n + std::max<int64_t>(k, 0), std::memory_order_release);
}

bool Engine::recordStart() {
  recording_.store(false);
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  if (rec_.size() != 48000 * 30) rec_.assign(48000 * 30, 0.f);
  recN_.store(0);
  recording_.store(true);
  return running_;
}

int Engine::analyze(int64_t firstMaster, int count, int64_t spacing, int64_t* rel, double* conf) {
  recording_.store(false);
  int64_t n = recN_.load();
  double rate = recRate_.load();
  if (n <= 0 || count <= 0) return 0;
  // Template at the mic rate.
  int L = (int)(kChirpSec * rate);
  std::vector<float> tpl(L);
  for (int i = 0; i < L; i++) tpl[i] = chirpValue(i / rate);

  int64_t recStartMaster = ClockSync::get().toMaster(recFirstLocal_.load());
  const float* x = rec_.data();
  int64_t win = (int64_t)(0.25 * rate);
  int found = 0;
  double arrival0 = 0;
  bool have0 = false;
  for (int k = 0; k < count; k++) {
    rel[k] = 0;
    conf[k] = 0;
    double expIdx = (double)(firstMaster + k * spacing - recStartMaster) * rate / 1e9;
    int64_t lo = std::max<int64_t>(0, (int64_t)expIdx - win);
    int64_t hi = std::min<int64_t>(n - L - 1, (int64_t)expIdx + win);
    if (hi <= lo + 2) continue;
    std::vector<float> c((size_t)(hi - lo));
    double sumAbs = 0;
    int64_t best = 0;
    float bestV = 0;
    for (int64_t lag = lo; lag < hi; lag++) {
      const float* p = x + lag;
      float acc = 0;
      for (int i = 0; i < L; i++) acc += p[i] * tpl[i];
      float a = std::fabs(acc);
      c[(size_t)(lag - lo)] = a;
      sumAbs += a;
      if (a > bestV) { bestV = a; best = lag; }
    }
    double mean = sumAbs / (double)(hi - lo);
    // Parabolic refinement around the peak.
    double frac = 0;
    size_t bi = (size_t)(best - lo);
    if (bi > 0 && bi + 1 < c.size()) {
      double ym = c[bi - 1], y0 = c[bi], yp = c[bi + 1];
      double den = ym - 2 * y0 + yp;
      if (den != 0) frac = 0.5 * (ym - yp) / den;
    }
    double arrival = ((double)best + frac - expIdx) / rate * 1e9;  // ns vs expectation
    conf[k] = mean > 0 ? bestV / mean : 0;
    if (conf[k] < 4.0) continue;  // not heard
    if (k == 0) { arrival0 = arrival; have0 = true; }
    if (!have0) continue;
    rel[k] = (int64_t)(arrival - arrival0);
    found++;
  }
  return found;
}

void Engine::stats(double* o) {
  o[0] = statErrUs_.load();
  o[1] = statPpm_.load();
  o[2] = (double)underruns_.load();
  o[3] = (double)reportedLatNs_.load() / 1000.0;
  o[4] = statRate_.load();
  o[5] = (double)hardResyncs_.load();
  o[6] = (double)callbacks_.load();
}

void Engine::spectrum(float* out, int bands) {
  constexpr int N = 1024;
  std::vector<std::complex<float>> a(N);
  uint32_t w = visW_.load(std::memory_order_relaxed);
  for (int i = 0; i < N; i++) {
    float hann = 0.5f - 0.5f * std::cos(2.f * (float)M_PI * i / (N - 1));
    a[i] = vis_[(w - N + i) & (kVisN - 1)] * hann;
  }
  // In-place radix-2 FFT.
  for (int i = 1, j = 0; i < N; i++) {
    int bit = N >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }
  for (int len = 2; len <= N; len <<= 1) {
    float ang = -2.f * (float)M_PI / len;
    std::complex<float> wl(std::cos(ang), std::sin(ang));
    for (int i = 0; i < N; i += len) {
      std::complex<float> wv(1, 0);
      for (int j = 0; j < len / 2; j++) {
        auto u = a[i + j], v = a[i + j + len / 2] * wv;
        a[i + j] = u + v;
        a[i + j + len / 2] = u - v;
        wv *= wl;
      }
    }
  }
  double rate = statRate_.load() > 0 ? statRate_.load() : 48000;
  double fLo = 50, fHi = 14000;
  for (int b = 0; b < bands; b++) {
    double f0 = fLo * std::pow(fHi / fLo, (double)b / bands);
    double f1 = fLo * std::pow(fHi / fLo, (double)(b + 1) / bands);
    int i0 = std::max(1, (int)(f0 * N / rate));
    int i1 = std::max(i0 + 1, (int)(f1 * N / rate));
    float m = 0;
    for (int i = i0; i < i1 && i < N / 2; i++) m = std::max(m, std::abs(a[i]));
    float db = 20.f * std::log10(m + 1e-6f);
    out[b] = std::clamp((db + 50.f) / 60.f, 0.f, 1.f);
  }
}

}  // namespace duet
