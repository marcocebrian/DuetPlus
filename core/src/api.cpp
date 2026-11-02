#include "../include/duet.h"
#include "core.h"

using namespace duet;

namespace {
std::mutex g_mu;
}

extern "C" {

int32_t duet_engine_start(int32_t want_mic) { return Engine::get().start(want_mic != 0) ? 1 : 0; }
void duet_engine_stop(void) { Engine::get().stop(); }
int32_t duet_mic_permission(void) { return backendMicPermission(); }
void duet_mic_request(void) { backendMicRequest(); }

int64_t duet_local_now_ns(void) { return nowNs(); }
int64_t duet_master_now_ns(void) { return ClockSync::get().toMaster(nowNs()); }
int32_t duet_clock_server_start(int32_t port) { return ClockSync::get().startServer(port) ? 1 : 0; }
int32_t duet_clock_client_start(const char* ip, int32_t port) {
  return ClockSync::get().startClient(ip ? ip : "", port) ? 1 : 0;
}
void duet_clock_stop(void) { ClockSync::get().stop(); }
void duet_clock_stats(int64_t* o) { ClockSync::get().stats(o); }

int32_t duet_track_load(const char* path) {
  std::lock_guard<std::mutex> l(g_mu);
  Engine& e = Engine::get();
  e.setSchedule(0, 0, 0, INT64_MAX);
  Track* t = new Track();
  t->startDecode(path ? path : "");
  e.setTrack(t);
  return 1;
}

void duet_track_status(int64_t* o) {
  Track* t = Engine::get().track();
  if (!t) { o[0] = o[1] = o[2] = 0; o[3] = 0; return; }
  o[0] = t->decoded();
  o[1] = t->total();
  o[2] = t->done() ? 1 : 0;
  o[3] = t->error();
}

int32_t duet_transcode_start(const char* in, const char* out) {
  return transcodeStart(in ? in : "", out ? out : "") ? 1 : 0;
}
void duet_transcode_status(int32_t* o) { transcodeStatus(o); }

void duet_track_unload(void) {
  std::lock_guard<std::mutex> l(g_mu);
  Engine::get().setSchedule(0, 0, 0, INT64_MAX);
  Engine::get().setTrack(nullptr);
}

void duet_set_schedule(int32_t playing, int64_t frame, int64_t at, int64_t end) {
  Engine::get().setSchedule(playing, frame, at, end);
}
void duet_set_latency_fix_ns(int64_t ns) { Engine::get().setLatencyFix(ns); }
int64_t duet_get_latency_fix_ns(void) { return Engine::get().latencyFix(); }
void duet_set_volume(float v) { Engine::get().setVolume(v); }
double duet_position_frames(void) { return Engine::get().position(); }
void duet_engine_stats(double* o) { Engine::get().stats(o); }
void duet_playhead(int64_t* m, double* f) {
  auto p = Engine::get().playhead();
  *m = p.master;
  *f = p.frame;
}
void duet_spectrum(float* out, int32_t bands) { Engine::get().spectrum(out, bands); }

void duet_chirp_at(int64_t at) { Engine::get().chirpAt(at); }
int32_t duet_record_start(void) { return Engine::get().recordStart() ? 1 : 0; }
void duet_record_stop(void) { Engine::get().recordStop(); }
int32_t duet_record_analyze(int64_t first, int32_t count, int64_t spacing, int64_t* rel,
                            double* conf) {
  return Engine::get().analyze(first, count, spacing, rel, conf);
}

}  // extern "C"
