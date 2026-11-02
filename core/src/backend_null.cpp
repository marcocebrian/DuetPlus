// Desktop test backend: a fake audio device driven by a thread, with a
// configurable "true" latency the engine doesn't know about.
#include <cstdlib>

#include "../third_party/miniaudio.h"
#include "core.h"

namespace duet {
namespace {
std::thread g_th;
std::atomic<bool> g_run{false};
}

bool platformDecodeFile(const std::string& path, const DecodeSink& sink, int64_t* total) {
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 0, 0);  // native rate/channels
  ma_decoder dec;
  if (ma_decoder_init_file(path.c_str(), &cfg, &dec) != MA_SUCCESS) return false;
  ma_uint64 len = 0;
  ma_decoder_get_length_in_pcm_frames(&dec, &len);
  *total = (int64_t)len;
  int ch = (int)dec.outputChannels, rate = (int)dec.outputSampleRate;
  std::vector<float> buf(4096 * ch);
  bool ok = true;
  for (;;) {
    ma_uint64 got = 0;
    ma_decoder_read_pcm_frames(&dec, buf.data(), 4096, &got);
    if (got == 0) break;
    if (!sink(buf.data(), (int64_t)got, rate, ch)) { ok = false; break; }
  }
  ma_decoder_uninit(&dec);
  return ok;
}

int backendMicPermission() { return 2; }
void backendMicRequest() {}

bool backendStart(bool) {
  g_run = true;
  g_th = std::thread([] {
    const int frames = 256;
    const double rate = 48000;
    std::vector<float> buf(frames * 2);
    int64_t t = nowNs();
    while (g_run) {
      Engine::get().render(buf.data(), frames, 2, t + 10'000'000, rate);
      t += (int64_t)(frames * 1e9 / rate);
      std::this_thread::sleep_for(std::chrono::nanoseconds(std::max<int64_t>(0, t - nowNs())));
    }
  });
  return true;
}

void backendStop() {
  g_run = false;
  if (g_th.joinable()) g_th.join();
}

}  // namespace duet
