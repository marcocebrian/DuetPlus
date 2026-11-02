// Desktop tests for the platform-neutral algorithms.
//   duet_test clock          -> clock sync across two processes (fork) on localhost
//   duet_test decode <file>  -> decode a file, print frames
//   duet_test calib          -> synthetic acoustic calibration
//   duet_test engine <file>  -> schedule playback on the null backend
#include <sys/wait.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include "../include/duet.h"
#include "../src/core.h"

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } else { printf("ok:   "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void sleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

static int testClock() {
  pid_t pid = fork();
  if (pid == 0) {
    duet_clock_server_start(47999);
    sleepMs(9000);
    _exit(0);
  }
  sleepMs(200);
  duet_clock_client_start("127.0.0.1", 47999);
  sleepMs(8000);
  int64_t s[5];
  duet_clock_stats(s);
  printf("offset=%lldus rtt=%lldus skew=%lldppb n=%lld locked=%lld\n", s[0] / 1000, s[1] / 1000,
         s[2], s[3], s[4]);
  // Same machine => true offset is 0.
  CHECK(std::llabs(s[0]) < 200000, "clock offset %lld ns within 200us", s[0]);
  CHECK(s[4] == 1, "clock locked");
  int64_t d = duet_master_now_ns() - duet_local_now_ns();
  CHECK(std::llabs(d) < 200000, "master-local %lld ns", d);
  duet_clock_stop();
  waitpid(pid, nullptr, 0);
  return 0;
}

static int testDecode(const char* path) {
  duet_track_load(path);
  int64_t st[4];
  for (int i = 0; i < 300; i++) {
    duet_track_status(st);
    if (st[2]) break;
    sleepMs(20);
  }
  printf("decoded=%lld total=%lld done=%lld err=%lld (%.2fs)\n", st[0], st[1], st[2], st[3],
         st[0] / 48000.0);
  CHECK(st[2] == 1 && st[3] == 0 && st[0] > 48000, "decode ok");
  return 0;
}

static int testCalib() {
  // Build a fake "recording": slots at 0, 700ms, 1400ms with errors 0, +1.5ms, -0.8ms.
  using namespace duet;
  Engine& e = Engine::get();
  // Use the engine's own chirp generator via render() into a buffer.
  const double rate = 48000;
  std::vector<float> rec((size_t)(rate * 3), 0.f);
  double errs[3] = {0, 0.0015, -0.0008};
  // Generate chirps directly with the same formula (render path tested separately).
  auto chirp = [](double t) {
    if (t < 0 || t >= 0.040) return 0.0;
    double k = (7000 - 1500) / 0.040;
    return 0.9 * (0.5 - 0.5 * cos(2 * M_PI * t / 0.040)) * sin(2 * M_PI * (1500 * t + 0.5 * k * t * t));
  };
  double base = 0.3;  // first chirp 300 ms into the recording
  for (size_t i = 0; i < rec.size(); i++) {
    double t = i / rate;
    double v = 0;
    for (int k = 0; k < 3; k++) v += chirp(t - (base + k * 0.7 + errs[k])) * (k ? 0.3 : 1.0);
    v += 0.05 * ((rand() / (double)RAND_MAX) - 0.5);  // noise
    rec[i] = (float)v;
  }
  e.recordStart();
  int64_t t0 = nowNs();
  for (size_t i = 0; i < rec.size(); i += 480)
    e.capture(rec.data() + i, (int)std::min<size_t>(480, rec.size() - i),
              t0 + (int64_t)(i / rate * 1e9), rate);
  int64_t rel[3];
  double conf[3];
  int found = e.analyze(t0 + (int64_t)(base * 1e9) + 5'000'000 /*coarse error*/, 3, 700'000'000, rel, conf);
  for (int k = 0; k < 3; k++) printf("slot %d rel=%.3fms conf=%.1f\n", k, rel[k] / 1e6, conf[k]);
  CHECK(found == 3, "found 3 chirps");
  CHECK(std::fabs(rel[1] / 1e9 - 0.0015) < 50e-6, "slot1 +1.5ms within 50us");
  CHECK(std::fabs(rel[2] / 1e9 + 0.0008) < 50e-6, "slot2 -0.8ms within 50us");
  return 0;
}

static int testTranscode(const char* in) {
  const char* out = "/tmp/duettest/out.duop";
  duet_transcode_start(in, out);
  int32_t st[3] = {0, 0, 0};
  for (int i = 0; i < 1000 && !st[1]; i++) { duet_transcode_status(st); sleepMs(20); }
  CHECK(st[1] == 1 && st[2] == 0, "transcode done (err=%d)", st[2]);
  // Reference: direct decode of the source
  duet_track_load(in);
  int64_t a[4];
  for (int i = 0; i < 500; i++) { duet_track_status(a); if (a[2]) break; sleepMs(10); }
  duet_track_load(out);
  int64_t b[4];
  for (int i = 0; i < 500; i++) { duet_track_status(b); if (b[2]) break; sleepMs(10); }
  printf("direct=%lld frames, duop=%lld frames, err=%lld\n", a[0], b[0], b[3]);
  CHECK(b[3] == 0 && std::llabs(a[0] - b[0]) < 48, "DUOP length matches source within 1 ms");
  return 0;
}

static int testEngine(const char* path) {
  duet_engine_start(0);
  duet_track_load(path);
  sleepMs(300);
  int64_t start = duet_master_now_ns() + 200'000'000;
  duet_set_schedule(1, 48000, start, INT64_MAX);  // start at 1.0s into the track
  sleepMs(1200);
  double pos = duet_position_frames();
  // Null backend presents 10 ms after render time; position = as heard at buffer start.
  double expected = 48000 + (duet_master_now_ns() - start) / 1e9 * 48000;
  double stats[7];
  duet_engine_stats(stats);
  printf("pos=%.0f expected~%.0f err=%.1fus ppm=%.1f resyncs=%.0f cb=%.0f\n", pos, expected,
         stats[0], stats[1], stats[5], stats[6]);
  CHECK(std::fabs(pos - expected) < 48000 * 0.03, "position tracks schedule (+-30ms incl. buffer)");
  CHECK(std::fabs(stats[0]) < 500, "control error < 0.5ms");
  float sp[24];
  duet_spectrum(sp, 24);
  float m = 0;
  for (float v : sp) m = std::max(m, v);
  CHECK(m > 0.1f, "spectrum has energy (%.2f)", m);
  duet_engine_stop();
  return 0;
}

int main(int argc, char** argv) {
  if (argc < 2) { printf("usage\n"); return 2; }
  if (!strcmp(argv[1], "clock")) testClock();
  else if (!strcmp(argv[1], "decode") && argc > 2) testDecode(argv[2]);
  else if (!strcmp(argv[1], "calib")) testCalib();
  else if (!strcmp(argv[1], "engine") && argc > 2) testEngine(argv[2]);
  else if (!strcmp(argv[1], "transcode") && argc > 2) testTranscode(argv[2]);
  printf(fails ? "FAILED (%d)\n" : "ALL OK\n", fails);
  return fails ? 1 : 0;
}
