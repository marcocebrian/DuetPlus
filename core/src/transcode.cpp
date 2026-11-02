// Host-side transcoding of formats the core can't decode identically on every
// phone (AAC/M4A/ALAC/OGG...). The host decodes with the platform decoder,
// converts to 48 kHz stereo and encodes Opus into a tiny "DUOP" container.
// Guests then all decode the exact same Opus stream => identical timing.
#include <opus.h>

#include <cstdio>

#include "../third_party/miniaudio.h"
#include "core.h"

namespace duet {

namespace {
struct DuopHeader {
  char magic[4];  // "DUOP"
  uint32_t version;
  uint32_t channels;
  uint32_t preskip;
  int64_t totalFrames;  // after preskip
};

std::atomic<int> g_tcProgress{0};  // per mille
std::atomic<int> g_tcDone{0};
std::atomic<int> g_tcError{0};
std::atomic<bool> g_tcCancel{false};
std::thread* g_tcThread = nullptr;  // intentionally leaked: no join at static teardown

class Encoder {
 public:
  bool open(const std::string& out) {
    f_ = fopen(out.c_str(), "wb");
    if (!f_) return false;
    int err = 0;
    enc_ = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &err);
    if (err != OPUS_OK) return false;
    opus_encoder_ctl(enc_, OPUS_SET_BITRATE(160000));
    opus_encoder_ctl(enc_, OPUS_SET_COMPLEXITY(8));
    opus_int32 la = 0;
    opus_encoder_ctl(enc_, OPUS_GET_LOOKAHEAD(&la));
    hdr_ = DuopHeader{{'D', 'U', 'O', 'P'}, 1, 2, (uint32_t)la, 0};
    fwrite(&hdr_, sizeof(hdr_), 1, f_);
    return true;
  }
  // Interleaved stereo 48 kHz.
  void push(const float* x, int64_t frames) {
    frames_ += frames;
    while (frames > 0) {
      int64_t n = std::min<int64_t>(frames, 960 - fill_);
      memcpy(buf_ + fill_ * 2, x, n * 2 * sizeof(float));
      fill_ += (int)n;
      x += n * 2;
      frames -= n;
      if (fill_ == 960) encodeFrame();
    }
  }
  bool finish() {
    // Flush the encoder lookahead with silence, then pad the last frame.
    int64_t real = frames_;
    std::vector<float> z((size_t)(hdr_.preskip + 960) * 2, 0.f);
    push(z.data(), hdr_.preskip);
    if (fill_ > 0) push(z.data(), 960 - fill_);
    hdr_.totalFrames = real;
    fseek(f_, 0, SEEK_SET);
    fwrite(&hdr_, sizeof(hdr_), 1, f_);
    fclose(f_);
    f_ = nullptr;
    opus_encoder_destroy(enc_);
    enc_ = nullptr;
    return true;
  }
  ~Encoder() {
    if (f_) fclose(f_);
    if (enc_) opus_encoder_destroy(enc_);
  }

 private:
  void encodeFrame() {
    unsigned char pkt[4000];
    int n = opus_encode_float(enc_, buf_, 960, pkt, sizeof(pkt));
    fill_ = 0;
    if (n < 0) return;
    uint16_t len = (uint16_t)n;
    fwrite(&len, 2, 1, f_);
    fwrite(pkt, 1, n, f_);
  }
  FILE* f_ = nullptr;
  OpusEncoder* enc_ = nullptr;
  DuopHeader hdr_{};
  float buf_[960 * 2];
  int fill_ = 0;
  int64_t frames_ = 0;
};

void run(std::string in, std::string out) {
  Encoder enc;
  if (!enc.open(out)) { g_tcError = 1; g_tcDone = 1; return; }
  ma_data_converter conv{};
  bool convInit = false;
  int curRate = 0, curCh = 0;
  std::vector<float> tmp;
  int64_t total = 0, seen = 0;
  bool ok = platformDecodeFile(
      in,
      [&](const float* x, int64_t frames, int rate, int ch) -> bool {
        if (g_tcCancel) return false;
        if (!convInit || rate != curRate || ch != curCh) {
          if (convInit) ma_data_converter_uninit(&conv, nullptr);
          ma_data_converter_config cfg = ma_data_converter_config_init(
              ma_format_f32, ma_format_f32, (ma_uint32)ch, 2, (ma_uint32)rate, 48000);
          cfg.resampling.algorithm = ma_resample_algorithm_linear;
          cfg.resampling.linear.lpfOrder = 8;
          if (ma_data_converter_init(&cfg, nullptr, &conv) != MA_SUCCESS) return false;
          convInit = true;
          curRate = rate;
          curCh = ch;
        }
        ma_uint64 inLeft = (ma_uint64)frames;
        const float* p = x;
        while (inLeft > 0) {
          ma_uint64 outCap = 4096;
          tmp.resize(outCap * 2);
          ma_uint64 inN = inLeft, outN = outCap;
          ma_data_converter_process_pcm_frames(&conv, p, &inN, tmp.data(), &outN);
          if (outN) enc.push(tmp.data(), (int64_t)outN);
          p += inN * ch;
          inLeft -= inN;
          if (inN == 0 && outN == 0) break;
        }
        seen += frames;
        if (total > 0) g_tcProgress = (int)std::min<int64_t>(999, seen * 1000 / total);
        return true;
      },
      &total);
  if (convInit) {
    // Drain the resampler.
    ma_uint64 outN = 4096;
    tmp.resize(outN * 2);
    ma_uint64 inN = 0;
    ma_data_converter_process_pcm_frames(&conv, nullptr, &inN, tmp.data(), &outN);
    if (outN) enc.push(tmp.data(), (int64_t)outN);
    ma_data_converter_uninit(&conv, nullptr);
  }
  if (!ok || g_tcCancel) { g_tcError = 2; g_tcDone = 1; return; }
  enc.finish();
  g_tcProgress = 1000;
  g_tcDone = 1;
}
}  // namespace

bool transcodeStart(const std::string& in, const std::string& out) {
  g_tcCancel = true;
  if (g_tcThread) { g_tcThread->join(); delete g_tcThread; g_tcThread = nullptr; }
  g_tcCancel = false;
  g_tcProgress = 0;
  g_tcDone = 0;
  g_tcError = 0;
  g_tcThread = new std::thread(run, in, out);
  return true;
}

void transcodeStatus(int32_t* out3) {
  out3[0] = g_tcProgress;
  out3[1] = g_tcDone;
  out3[2] = g_tcError;
}

// ------------------------------------------------------------ DUOP decoding
bool decodeDuop(const std::vector<uint8_t>& data, const std::function<void(const float*, int64_t)>& sink,
                std::atomic<int64_t>& total, const std::atomic<bool>& cancel) {
  if (data.size() < sizeof(DuopHeader)) return false;
  DuopHeader h;
  memcpy(&h, data.data(), sizeof(h));
  if (memcmp(h.magic, "DUOP", 4) != 0 || h.channels != 2) return false;
  total = h.totalFrames;
  int err = 0;
  OpusDecoder* dec = opus_decoder_create(48000, 2, &err);
  if (err != OPUS_OK) return false;
  std::vector<float> pcm(5760 * 2);
  int64_t skip = h.preskip, left = h.totalFrames;
  size_t off = sizeof(h);
  while (off + 2 <= data.size() && left > 0 && !cancel) {
    uint16_t len;
    memcpy(&len, data.data() + off, 2);
    off += 2;
    if (off + len > data.size()) break;
    int n = opus_decode_float(dec, data.data() + off, len, pcm.data(), 5760, 0);
    off += len;
    if (n <= 0) continue;
    int s = (int)std::min<int64_t>(skip, n);
    skip -= s;
    int64_t k = std::min<int64_t>(n - s, left);
    if (k > 0) sink(pcm.data() + s * 2, k);
    left -= k;
  }
  opus_decoder_destroy(dec);
  return true;
}

}  // namespace duet
