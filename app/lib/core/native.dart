// FFI bindings to the shared C++ core (core/include/duet.h).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

DynamicLibrary _open() {
  if (Platform.isAndroid) return DynamicLibrary.open('libduet.so');
  if (Platform.isMacOS) return DynamicLibrary.open(Platform.environment['DUET_LIB'] ?? 'libduet.dylib'); // desktop tests
  return DynamicLibrary.process(); // iOS: statically linked into Runner
}

class ClockStats {
  final double offsetMs, rttMs, skewPpm;
  final int samples;
  final bool locked;
  ClockStats(this.offsetMs, this.rttMs, this.skewPpm, this.samples, this.locked);
}

class EngineStats {
  final double ctrlErrorUs, ratePpm, underruns, outLatencyMs, deviceRate, hardResyncs, callbacks;
  EngineStats(this.ctrlErrorUs, this.ratePpm, this.underruns, this.outLatencyMs, this.deviceRate,
      this.hardResyncs, this.callbacks);
}

class TrackStatus {
  final int decoded, total;
  final bool done;
  final int error;
  TrackStatus(this.decoded, this.total, this.done, this.error);
  double get decodedSec => decoded / 48000.0;
  double get totalSec => (total > 0 ? total : decoded) / 48000.0;
}

class Duet {
  Duet._();
  static final Duet I = Duet._();
  final DynamicLibrary _l = _open();

  late final _engineStart = _l.lookupFunction<Int32 Function(Int32), int Function(int)>('duet_engine_start');
  late final _engineStop = _l.lookupFunction<Void Function(), void Function()>('duet_engine_stop');
  late final _micPerm = _l.lookupFunction<Int32 Function(), int Function()>('duet_mic_permission');
  late final _micReq = _l.lookupFunction<Void Function(), void Function()>('duet_mic_request');
  late final _tcStart = _l.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>), int Function(Pointer<Utf8>, Pointer<Utf8>)>(
      'duet_transcode_start');
  late final _tcStatus = _l.lookupFunction<Void Function(Pointer<Int32>), void Function(Pointer<Int32>)>('duet_transcode_status');
  late final _playhead = _l.lookupFunction<Void Function(Pointer<Int64>, Pointer<Double>), void Function(Pointer<Int64>, Pointer<Double>)>('duet_playhead');
  late final _localNow = _l.lookupFunction<Int64 Function(), int Function()>('duet_local_now_ns');
  late final _masterNow = _l.lookupFunction<Int64 Function(), int Function()>('duet_master_now_ns');
  late final _clockServer = _l.lookupFunction<Int32 Function(Int32), int Function(int)>('duet_clock_server_start');
  late final _clockClient = _l.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>(
      'duet_clock_client_start');
  late final _clockStop = _l.lookupFunction<Void Function(), void Function()>('duet_clock_stop');
  late final _clockStats = _l.lookupFunction<Void Function(Pointer<Int64>), void Function(Pointer<Int64>)>('duet_clock_stats');
  late final _trackLoad = _l.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('duet_track_load');
  late final _trackStatus = _l.lookupFunction<Void Function(Pointer<Int64>), void Function(Pointer<Int64>)>('duet_track_status');
  late final _trackUnload = _l.lookupFunction<Void Function(), void Function()>('duet_track_unload');
  late final _setSchedule = _l.lookupFunction<Void Function(Int32, Int64, Int64, Int64), void Function(int, int, int, int)>(
      'duet_set_schedule');
  late final _setFix = _l.lookupFunction<Void Function(Int64), void Function(int)>('duet_set_latency_fix_ns');
  late final _getFix = _l.lookupFunction<Int64 Function(), int Function()>('duet_get_latency_fix_ns');
  late final _setVolume = _l.lookupFunction<Void Function(Float), void Function(double)>('duet_set_volume');
  late final _position = _l.lookupFunction<Double Function(), double Function()>('duet_position_frames');
  late final _engineStats = _l.lookupFunction<Void Function(Pointer<Double>), void Function(Pointer<Double>)>('duet_engine_stats');
  late final _spectrum = _l.lookupFunction<Void Function(Pointer<Float>, Int32), void Function(Pointer<Float>, int)>('duet_spectrum');
  late final _chirpAt = _l.lookupFunction<Void Function(Int64), void Function(int)>('duet_chirp_at');
  late final _recStart = _l.lookupFunction<Int32 Function(), int Function()>('duet_record_start');
  late final _recStop = _l.lookupFunction<Void Function(), void Function()>('duet_record_stop');
  late final _recAnalyze = _l.lookupFunction<Int32 Function(Int64, Int32, Int64, Pointer<Int64>, Pointer<Double>),
      int Function(int, int, int, Pointer<Int64>, Pointer<Double>)>('duet_record_analyze');

  final Pointer<Int64> _i64 = calloc<Int64>(8);
  final Pointer<Double> _f64 = calloc<Double>(8);
  final Pointer<Float> _spec = calloc<Float>(64);

  static const int infinity = 0x7fffffffffffffff;

  bool engineStart({required bool mic}) => _engineStart(mic ? 1 : 0) == 1;
  void engineStop() => _engineStop();

  /// iOS: asks natively and waits for the answer. Returns true if granted.
  Future<bool> requestMicIOS() async {
    if (_micPerm() == 0) {
      _micReq();
      for (var i = 0; i < 600 && _micPerm() == 0; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    return _micPerm() == 2;
  }
  int localNow() => _localNow();
  int masterNow() => _masterNow();
  bool clockServer(int port) => _clockServer(port) == 1;
  bool clockClient(String ip, int port) {
    final p = ip.toNativeUtf8();
    final r = _clockClient(p, port);
    calloc.free(p);
    return r == 1;
  }

  void clockStop() => _clockStop();
  ClockStats clockStats() {
    _clockStats(_i64);
    return ClockStats(_i64[0] / 1e6, _i64[1] / 1e6, _i64[2] / 1e3, _i64[3], _i64[4] == 1);
  }

  void trackLoad(String path) {
    final p = path.toNativeUtf8();
    _trackLoad(p);
    calloc.free(p);
  }

  TrackStatus trackStatus() {
    _trackStatus(_i64);
    return TrackStatus(_i64[0], _i64[1], _i64[2] == 1, _i64[3]);
  }

  void trackUnload() => _trackUnload();

  /// Host-side: platform-decode [input] and re-encode to Opus (DUOP) at [output].
  Future<void> transcode(String input, String output, void Function(double) progress) async {
    final a = input.toNativeUtf8(), b = output.toNativeUtf8();
    _tcStart(a, b);
    calloc.free(a);
    calloc.free(b);
    final st = calloc<Int32>(3);
    try {
      while (true) {
        _tcStatus(st);
        progress(st[0] / 1000);
        if (st[1] == 1) {
          if (st[2] != 0) throw 'This file format could not be decoded (error ${st[2]})';
          return;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      calloc.free(st);
    }
  }
  void setSchedule({required bool playing, required int frame, required int atMaster, int endMaster = infinity}) =>
      _setSchedule(playing ? 1 : 0, frame, atMaster, endMaster);
  set latencyFixNs(int v) => _setFix(v);
  int get latencyFixNs => _getFix();
  set volume(double v) => _setVolume(v);
  double get positionFrames => _position();
  /// (master time ns, source frame or -1 when silent) of the last rendered buffer.
  (int, double) playhead() {
    _playhead(_i64, _f64);
    return (_i64[0], _f64[0]);
  }
  EngineStats engineStats() {
    _engineStats(_f64);
    return EngineStats(_f64[0], _f64[1], _f64[2], _f64[3] / 1000, _f64[4], _f64[5], _f64[6]);
  }

  Float32List spectrum(int bands) {
    _spectrum(_spec, bands);
    return Float32List.fromList(_spec.asTypedList(bands));
  }

  void chirpAt(int masterNs) => _chirpAt(masterNs);
  bool recordStart() => _recStart() == 1;
  void recordStop() => _recStop();

  /// Returns per-slot arrival error relative to slot 0 (ns) or null if not heard.
  List<double?> recordAnalyze(int firstMaster, int count, int spacingNs) {
    final rel = calloc<Int64>(count);
    final conf = calloc<Double>(count);
    _recAnalyze(firstMaster, count, spacingNs, rel, conf);
    final out = <double?>[];
    final heard0 = conf[0] >= 4.0; // slot 0 (host) is the reference
    for (var k = 0; k < count; k++) {
      out.add(heard0 && conf[k] >= 4.0 ? rel[k].toDouble() : null);
    }
    calloc.free(rel);
    calloc.free(conf);
    return out;
  }
}
