// Track decoding: everything becomes 48 kHz stereo float, stored in fixed
// blocks so the audio thread can read lock-free while decoding continues.
#define MA_NO_DEVICE_IO
#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include "../third_party/miniaudio.h"

#include <opus.h>

#include <cstdio>

#include "core.h"

namespace duet {

Track::Track() {
  blocks_ = new std::atomic<const float*>[kMaxBlocks];
  for (int i = 0; i < kMaxBlocks; i++) blocks_[i].store(nullptr);
}

Track::~Track() {
  cancel();
  for (int i = 0; i < kMaxBlocks; i++) delete[] blocks_[i].load();
  delete[] blocks_;
}

void Track::cancel() {
  cancel_ = true;
  if (th_.joinable()) th_.join();
}

bool Track::startDecode(const std::string& path) {
  th_ = std::thread(&Track::run, this, path);
  return true;
}

bool Track::append(const float* inter, int64_t frames) {
  int64_t d = decoded_.load();
  while (frames > 0) {
    int64_t bi = d >> kBlockShift;
    if (bi >= kMaxBlocks) return false;
    float* b = const_cast<float*>(blocks_[bi].load());
    if (!b) {
      b = new float[kBlockFrames * 2]();
      blocks_[bi].store(b, std::memory_order_release);
    }
    int64_t off = d & (kBlockFrames - 1);
    int64_t n = std::min<int64_t>(frames, kBlockFrames - off);
    memcpy(b + off * 2, inter, n * 2 * sizeof(float));
    inter += n * 2;
    frames -= n;
    d += n;
    decoded_.store(d, std::memory_order_release);
  }
  return true;
}

void Track::run(std::string path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) { error_ = 1; done_ = true; return; }
  uint8_t magic[4] = {0};
  size_t got = fread(magic, 1, 4, f);
  bool webm = got == 4 && magic[0] == 0x1A && magic[1] == 0x45 && magic[2] == 0xDF && magic[3] == 0xA3;
  bool duop = got == 4 && memcmp(magic, "DUOP", 4) == 0;
  bool ok;
  if (webm || duop) {
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> data((size_t)std::max(0L, sz));
    size_t rd = fread(data.data(), 1, data.size(), f);
    data.resize(rd);
    fclose(f);
    if (duop) {
      ok = decodeDuop(data, [this](const float* x, int64_t n) { append(x, n); }, total_, cancel_);
      if (!ok) error_ = 5;
    } else {
      ok = decodeWebm(data);
    }
  } else {
    fclose(f);
    ok = decodeMiniaudio(path);
  }
  if (!ok && !error_) error_ = 2;
  total_ = decoded_.load();
  done_ = true;
}

bool Track::decodeMiniaudio(const std::string& path) {
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 2, 48000);
  ma_decoder dec;
  if (ma_decoder_init_file(path.c_str(), &cfg, &dec) != MA_SUCCESS) { error_ = 3; return false; }
  ma_uint64 len = 0;
  if (ma_decoder_get_length_in_pcm_frames(&dec, &len) == MA_SUCCESS) total_ = (int64_t)len;
  std::vector<float> buf(8192 * 2);
  while (!cancel_) {
    ma_uint64 read = 0;
    ma_result r = ma_decoder_read_pcm_frames(&dec, buf.data(), 8192, &read);
    if (read > 0) append(buf.data(), (int64_t)read);
    if (r != MA_SUCCESS || read == 0) break;
  }
  ma_decoder_uninit(&dec);
  return true;
}

// ------------------------------------------------------------- minimal WebM
namespace {
struct Reader {
  const uint8_t* p;
  const uint8_t* end;
  bool vint(uint64_t& v, bool keepMarker, int* lenOut = nullptr) {
    if (p >= end) return false;
    uint8_t b = *p;
    int len = 1;
    while (len <= 8 && !(b & (0x80 >> (len - 1)))) len++;
    if (len > 8 || p + len > end) return false;
    v = keepMarker ? b : (b & (0xFF >> len));
    for (int i = 1; i < len; i++) v = (v << 8) | p[i];
    p += len;
    if (lenOut) *lenOut = len;
    return true;
  }
};
uint64_t readUInt(const uint8_t* p, uint64_t n) {
  uint64_t v = 0;
  for (uint64_t i = 0; i < n; i++) v = (v << 8) | p[i];
  return v;
}
double readFloat(const uint8_t* p, uint64_t n) {
  if (n == 4) { uint32_t u = (uint32_t)readUInt(p, 4); float f; memcpy(&f, &u, 4); return f; }
  if (n == 8) { uint64_t u = readUInt(p, 8); double d; memcpy(&d, &u, 8); return d; }
  return 0;
}
}  // namespace

bool Track::decodeWebm(const std::vector<uint8_t>& data) {
  int channels = 2, preskip = 0;
  uint64_t audioTrack = 0;
  uint64_t timecodeScale = 1000000;
  double duration = 0;
  OpusDecoder* dec = nullptr;
  std::vector<float> pcm(5760 * 2), st(5760 * 2);
  int64_t toSkip = 0;

  auto decodeFrame = [&](const uint8_t* fr, int len) {
    if (!dec) return;
    int n = opus_decode_float(dec, fr, len, pcm.data(), 5760, 0);
    if (n <= 0) return;
    const float* src = pcm.data();
    if (channels == 1) {
      for (int i = 0; i < n; i++) st[i * 2] = st[i * 2 + 1] = pcm[i];
      src = st.data();
    }
    int skip = (int)std::min<int64_t>(toSkip, n);
    toSkip -= skip;
    if (n - skip > 0) append(src + skip * 2, n - skip);
  };

  auto block = [&](const uint8_t* p, uint64_t size) {
    Reader r{p, p + size};
    uint64_t tn;
    if (!r.vint(tn, false)) return;
    if (r.p + 3 > r.end) return;
    uint8_t flags = r.p[2];
    r.p += 3;
    if (audioTrack && tn != audioTrack) return;
    int lacing = (flags >> 1) & 3;
    if (lacing == 0) { decodeFrame(r.p, (int)(r.end - r.p)); return; }
    int count = *r.p++ + 1;
    std::vector<uint64_t> sizes;
    if (lacing == 2) {  // fixed
      uint64_t each = (uint64_t)(r.end - r.p) / count;
      sizes.assign(count, each);
    } else if (lacing == 1) {  // xiph
      uint64_t sum = 0;
      for (int i = 0; i < count - 1; i++) {
        uint64_t s = 0;
        while (r.p < r.end) { uint8_t b = *r.p++; s += b; if (b != 255) break; }
        sizes.push_back(s); sum += s;
      }
      sizes.push_back((uint64_t)(r.end - r.p) - sum);
    } else {  // ebml
      uint64_t first;
      if (!r.vint(first, false)) return;
      sizes.push_back(first);
      int64_t prev = (int64_t)first, sum = (int64_t)first;
      for (int i = 1; i < count - 1; i++) {
        uint64_t raw; int len;
        if (!r.vint(raw, false, &len)) return;
        int64_t bias = (1LL << (7 * len - 1)) - 1;
        prev += (int64_t)raw - bias;
        sizes.push_back((uint64_t)prev); sum += prev;
      }
      sizes.push_back((uint64_t)((r.end - r.p) - sum));
    }
    for (uint64_t s : sizes) {
      if (r.p + s > r.end) return;
      decodeFrame(r.p, (int)s);
      r.p += s;
    }
  };

  // Track parsing state
  uint64_t curTrackNum = 0, curTrackType = 0;
  std::string curCodec;
  std::vector<uint8_t> curPriv;

  // Iterative walk with an explicit parent stack.
  struct Frame { const uint8_t* end; uint64_t id; };
  std::vector<Frame> stack;
  Reader r{data.data(), data.data() + data.size()};
  const uint8_t* fileEnd = r.end;
  while (r.p < fileEnd && !cancel_) {
    while (!stack.empty() && r.p >= stack.back().end) {
      if (stack.back().id == 0xAE) {  // TrackEntry finished
        if (curTrackType == 2 && !audioTrack && curCodec == "A_OPUS") {
          audioTrack = curTrackNum;
          if (curPriv.size() >= 19 && memcmp(curPriv.data(), "OpusHead", 8) == 0) {
            channels = curPriv[9];
            preskip = curPriv[10] | (curPriv[11] << 8);
          }
          int err = 0;
          dec = opus_decoder_create(48000, channels > 1 ? 2 : 1, &err);
          channels = channels > 1 ? 2 : 1;
          toSkip = preskip;
          if (duration > 0)
            total_ = (int64_t)(duration * (double)timecodeScale / 1e9 * 48000.0) - preskip;
        }
      }
      stack.pop_back();
    }
    uint64_t id, size;
    int sl;
    if (!r.vint(id, true)) break;
    if (!r.vint(size, false, &sl)) break;
    bool unknown = size == ((1ULL << (7 * sl)) - 1);
    const uint8_t* parentEnd = stack.empty() ? fileEnd : stack.back().end;
    const uint8_t* elEnd = unknown ? parentEnd : r.p + size;
    if (elEnd > parentEnd) elEnd = parentEnd;
    switch (id) {
      case 0x18538067:  // Segment
      case 0x1549A966:  // Info
      case 0x1654AE6B:  // Tracks
      case 0x1F43B675:  // Cluster
      case 0xA0:        // BlockGroup
        stack.push_back({elEnd, id});
        continue;
      case 0xAE:  // TrackEntry
        curTrackNum = 0; curTrackType = 0; curCodec.clear(); curPriv.clear();
        stack.push_back({elEnd, id});
        continue;
      case 0xD7: curTrackNum = readUInt(r.p, size); break;
      case 0x83: curTrackType = readUInt(r.p, size); break;
      case 0x86:
        curCodec.assign((const char*)r.p, (size_t)(elEnd - r.p));
        curCodec = std::string(curCodec.c_str());  // strip NUL padding
        break;
      case 0x63A2: curPriv.assign(r.p, elEnd); break;
      case 0x2AD7B1: timecodeScale = readUInt(r.p, size); break;
      case 0x4489: duration = readFloat(r.p, size); break;
      case 0xA3:  // SimpleBlock
      case 0xA1:  // Block
        block(r.p, (uint64_t)(elEnd - r.p));
        break;
      default: break;
    }
    r.p = elEnd;
  }
  if (dec) opus_decoder_destroy(dec);
  if (!audioTrack) { error_ = 4; return false; }
  return true;
}

}  // namespace duet
