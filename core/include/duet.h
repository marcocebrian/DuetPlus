// DuetPlus core — platform-neutral C API (consumed by Dart FFI).
// All times are nanoseconds. "local" = this device's monotonic clock,
// "master" = the host's monotonic clock (estimated through clock sync).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define DUET_API __declspec(dllexport)
#else
#define DUET_API __attribute__((visibility("default"))) __attribute__((used))
#endif

// ---- audio engine -------------------------------------------------------
// want_mic=1 on the host (needed for acoustic sync check).
DUET_API int32_t duet_engine_start(int32_t want_mic);
DUET_API void duet_engine_stop(void);
// Microphone permission (iOS native; Android always 2, handled in Dart).
// 0 = undetermined, 1 = denied, 2 = granted.
DUET_API int32_t duet_mic_permission(void);
DUET_API void duet_mic_request(void);

// ---- clock --------------------------------------------------------------
DUET_API int64_t duet_local_now_ns(void);
DUET_API int64_t duet_master_now_ns(void);  // == local on the host
DUET_API int32_t duet_clock_server_start(int32_t udp_port);
DUET_API int32_t duet_clock_client_start(const char* host_ip, int32_t udp_port);
DUET_API void duet_clock_stop(void);
// Writes: [0]=offset_ns [1]=best_rtt_ns [2]=skew_ppb [3]=samples [4]=locked(0/1)
DUET_API void duet_clock_stats(int64_t* out5);

// ---- track --------------------------------------------------------------
// Decodes the file to 48 kHz stereo float in a background thread.
// Supported: WebM/Opus (YouTube itag 251), MP3, FLAC, WAV.
DUET_API int32_t duet_track_load(const char* path);
// Writes: [0]=frames_decoded [1]=total_frames(estimate, 0=unknown) [2]=done [3]=error
DUET_API void duet_track_status(int64_t* out4);
DUET_API void duet_track_unload(void);

// ---- host-side transcoding (AAC/M4A/ALAC/OGG… -> Opus "DUOP") ----------
DUET_API int32_t duet_transcode_start(const char* in_path, const char* out_path);
// Writes: [0]=progress per mille [1]=done [2]=error
DUET_API void duet_transcode_status(int32_t* out3);

// ---- schedule -----------------------------------------------------------
// Play source frame `anchor_frame` at master time `anchor_master_ns`, continue
// until `end_master_ns` (INT64_MAX for "until the end"). playing=0 => silence.
DUET_API void duet_set_schedule(int32_t playing, int64_t anchor_frame,
                                int64_t anchor_master_ns, int64_t end_master_ns);
// Extra latency compensation (ns) found by the acoustic calibration.
DUET_API void duet_set_latency_fix_ns(int64_t fix_ns);
DUET_API int64_t duet_get_latency_fix_ns(void);
DUET_API void duet_set_volume(float v);
// Current playout position (source frames, 48 kHz) as heard right now.
DUET_API double duet_position_frames(void);
// Last rendered buffer: master time its first frame is heard + source frame
// playing then (-1 if silent). For measuring sync between devices.
DUET_API void duet_playhead(int64_t* master_ns, double* frame);
// Writes: [0]=ctrl_error_us [1]=rate_ppm [2]=underruns [3]=reported_out_latency_us
//         [4]=device_rate [5]=hard_resyncs [6]=callbacks
DUET_API void duet_engine_stats(double* out7);
// Log-spaced band magnitudes 0..1 of what is being played (for visuals).
DUET_API void duet_spectrum(float* out, int32_t bands);

// ---- acoustic sync check ------------------------------------------------
// Mix a chirp into the output, starting exactly at master time `at_master_ns`.
DUET_API void duet_chirp_at(int64_t at_master_ns);
DUET_API int32_t duet_record_start(void);  // host only, needs want_mic=1
DUET_API void duet_record_stop(void);
// Locates `count` chirps expected at first_master_ns + k*spacing_ns in the
// recording. out_rel_ns[k] = arrival error of slot k relative to slot 0
// (positive = late). out_conf[k] = peak/noise ratio. Returns found count.
DUET_API int32_t duet_record_analyze(int64_t first_master_ns, int32_t count,
                                     int64_t spacing_ns, int64_t* out_rel_ns,
                                     double* out_conf);

#ifdef __cplusplus
}
#endif
