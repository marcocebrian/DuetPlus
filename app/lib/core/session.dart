// Host / guest session logic. The host owns the master clock, the track and
// the schedule. Everything time-critical happens in the C++ core; this layer
// only moves files and schedule messages around.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show ImageProvider, MemoryImage, NetworkImage;
import 'package:path_provider/path_provider.dart';

import 'native.dart';
import 'protocol.dart';
import 'sources.dart';
import 'ytdlp.dart';

const int kRate = 48000;
final Duet duet = Duet.I;

class TrackMeta {
  final int id;
  String title;
  String artist;
  final String? thumb; // URL (fallback when bytes are missing)
  Uint8List? art; // cover art bytes, sent to every guest with the song
  final String source; // youtube | file | demo
  TrackMeta({required this.id, required this.title, required this.artist, this.thumb, this.art, required this.source});
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'thumb': thumb,
        'source': source,
        if (art != null) 'art': base64Encode(art!),
      };
  factory TrackMeta.fromJson(Map<String, dynamic> j) => TrackMeta(
      id: j['id'] as int,
      title: j['title'] as String? ?? '',
      artist: j['artist'] as String? ?? '',
      thumb: j['thumb'] as String?,
      art: j['art'] is String ? base64Decode(j['art'] as String) : null,
      source: j['source'] as String? ?? 'file');
  TrackMeta withId(int newId) =>
      TrackMeta(id: newId, title: title, artist: artist, thumb: thumb, art: art, source: source);

  /// Best image for the disc: embedded/received bytes, else the URL.
  ImageProvider? get image => art != null ? MemoryImage(art!) : (thumb != null ? NetworkImage(thumb!) : null);
}

class Sched {
  bool playing;
  int frame;
  int at;
  int end;
  Sched({this.playing = false, this.frame = 0, this.at = 0, this.end = Duet.infinity});
  Map<String, dynamic> toJson() => {'playing': playing, 'frame': frame, 'at': at, 'end': end == Duet.infinity ? null : end};
  static Sched fromJson(Map<String, dynamic> j) => Sched(
      playing: j['playing'] as bool,
      frame: j['frame'] as int,
      at: j['at'] as int,
      end: (j['end'] as int?) ?? Duet.infinity);
  void apply() => duet.setSchedule(playing: playing, frame: frame, atMaster: at, endMaster: end);

  /// Source frame heard at master time `t`.
  double frameAt(int t) {
    if (!playing || t < at) return frame.toDouble();
    final tt = math.min(t, end);
    return frame + (tt - at) * kRate / 1e9;
  }

  bool audibleAt(int t) => playing && t >= at && t < end;
}

/// Queue entry: resolves to a local file when it is about to play.
class QueueItem {
  final TrackMeta meta;
  final Future<String> Function(void Function(double) progress) resolve;
  QueueItem(this.meta, this.resolve);
}

abstract class Session extends ChangeNotifier {
  bool get isHost;
  TrackMeta? track;
  Sched sched = Sched();
  String status = '';
  double loadProgress = 0; // 0..1 download/distribution progress
  bool busy = false;
  String? error; // shown until the next action
  bool disposed = false;
  final _events = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream; // toasts: joins, leaves…
  void event(String e) {
    if (!_events.isClosed) _events.add(e);
  }
  int totalFrames = 0;
  String deviceName = '';

  double get positionSec => sched.frameAt(duet.masterNow()) / kRate;
  double get durationSec {
    final s = duet.trackStatus();
    totalFrames = s.total > 0 ? s.total : s.decoded;
    return totalFrames / kRate;
  }

  bool get audible => sched.audibleAt(duet.masterNow());

  void notify() {
    if (!disposed) notifyListeners();
  }

  Future<void> close();

  @override
  void dispose() {
    disposed = true;
    _events.close();
    super.dispose();
  }
}

Future<Directory> _work() async {
  final d = Directory('${(await getTemporaryDirectory()).path}/duet');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

// ============================================================== host
class Peer {
  final int id;
  final Wire wire;
  String name = '?';
  String platform = '?';
  int fixNs = 0;
  int readyTrack = -1;
  double dl = 0;
  Map<String, dynamic> stats = {};
  double? residualMs; // last acoustic check result (relative to host)
  double? beforeMs;
  List<String> caps = const [];
  _Fetch? fetch; // song this peer is fetching for us (yt-dlp)
  Future<void> _sendChain = Future.value(); // serializes big transfers per peer
  Peer(this.id, this.wire);

  void enqueue(Future<void> Function() job) {
    _sendChain = _sendChain.then((_) => job()).catchError((Object e) => debugPrint('peer send: $e'));
  }
  bool get locked => stats['locked'] == true;
}

class _Fetch {
  final int req;
  final String videoId;
  final void Function(double) progress;
  final completer = Completer<String>();
  IOSink? sink;
  String? path;
  int size = 0, got = 0;
  _Fetch(this.req, this.videoId, this.progress);
}

class HostSession extends Session {
  @override
  bool get isHost => true;
  ServerSocket? _server;
  BonsoirBroadcast? _bc;
  final List<Peer> peers = [];
  final List<QueueItem> queue = [];
  int _nextPeer = 1;
  int _trackSeq = 0;
  Uint8List? _trackBytes;
  Timer? _tick;
  String? ip;
  List<String> ips = [];
  final int sessionKey = math.Random().nextInt(1 << 30);
  int controlPort = kControlPort;
  bool checking = false;
  String checkReport = '';
  bool micOk = true;

  Future<void> start(String name, {required bool mic}) async {
    deviceName = name;
    micOk = mic;
    duet.engineStart(mic: mic);
    // Another app (or a stale session) may hold our port: fall back.
    Object? err;
    for (final port in kControlPorts) {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        if (!duet.clockServer(port + 1)) {
          await _server!.close();
          _server = null;
          continue;
        }
        controlPort = port;
        break;
      } catch (e) {
        err = e;
      }
    }
    if (_server == null) throw 'No free network port ($err)';
    _server!.listen(_onClient);
    ips = await localIPv4s();
    ip = ips.isNotEmpty ? ips.first : await localIPv4();
    try {
      _bc = BonsoirBroadcast(
          service: BonsoirService(name: name, type: kServiceType, port: controlPort, attributes: {'v': '1'}));
      await _bc!.initialize();
      await _bc!.start();
    } catch (e) {
      debugPrint('bonsoir broadcast failed: $e');
    }
    status = 'Waiting for guests';
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => _onTick());
    notify();
  }

  void _onClient(Socket s) {
    final p = Peer(_nextPeer++, Wire(s));
    peers.add(p);
    () async {
      await for (final m in p.wire.messages) {
        try {
          await _onPeerMsg(p, m);
        } catch (e) {
          debugPrint('peer msg error: $e');
        }
      }
      peers.remove(p);
      p.fetch?.completer.completeError('${p.name} left while fetching the song');
      p.fetch = null;
      _updateRemote();
      event('${p.name} left');
      notify();
    }();
    notify();
  }

  Future<void> _onPeerMsg(Peer p, Msg m) async {
    final j = m.json;
    if (j == null) {
      // Only fetched audio travels guest -> host as raw bytes.
      final f = p.fetch;
      if (f != null && f.sink != null && m.bytes != null) {
        f.sink!.add(m.bytes!);
        f.got += m.bytes!.length;
        if (f.size > 0) f.progress(0.7 + 0.3 * f.got / f.size);
      }
      return;
    }
    switch (m.t) {
      case 'fetchProgress':
        p.fetch?.progress(0.7 * (j['p'] as num).toDouble());
        break;
      case 'fetchBegin':
        final f = p.fetch;
        if (f != null && f.req == j['req']) {
          f.size = j['size'] as int;
          f.path = await workPath('yt_${f.videoId}.${j['ext']}');
          f.sink = File(f.path!).openWrite();
        }
        break;
      case 'fetchEnd':
        final f = p.fetch;
        if (f != null && f.req == j['req'] && f.sink != null) {
          await f.sink!.close();
          p.fetch = null;
          f.completer.complete(f.path!);
        }
        break;
      case 'fetchError':
        final f = p.fetch;
        if (f != null && f.req == j['req']) {
          await f.sink?.close();
          p.fetch = null;
          f.completer.completeError('${p.name}: ${j['msg']}');
        }
        break;
      case 'hello':
        p.name = j['name'] as String? ?? 'Guest';
        p.platform = j['platform'] as String? ?? '?';
        p.fixNs = j['fix'] as int? ?? 0;
        p.caps = ((j['caps'] as List?) ?? const []).cast<String>();
        _updateRemote();
        p.wire.send({'t': 'welcome', 'id': p.id, 'host': deviceName, 'session': sessionKey, 'clock': controlPort + 1});
        final rejoin = j['session'] == sessionKey;
        event(rejoin ? '${p.name} reconnected' : '${p.name} joined');
        if (track != null && _trackBytes != null) {
          final t = track!, bytes = _trackBytes!;
          if (rejoin && j['track'] == t.id) {
            // Reconnect after a Wi-Fi blip: it already has the song.
            p.readyTrack = t.id;
            p.wire.send({'t': 'sched', 'track': t.id, ...sched.toJson()});
          } else {
            p.enqueue(() async {
              await _sendTrackNow(p, t, bytes);
              if (track?.id == t.id) p.wire.send({'t': 'sched', 'track': t.id, ...sched.toJson()});
            });
          }
        }
        break;
      case 'ready':
        p.readyTrack = j['track'] as int;
        break;
      case 'progress':
        p.dl = (j['p'] as num).toDouble();
        break;
      case 'stats':
        p.stats = j;
        p.fixNs = j['fix'] as int? ?? p.fixNs;
        break;
    }
    notify();
  }

  void _sendTrack(Peer p, TrackMeta meta, Uint8List bytes) => p.enqueue(() => _sendTrackNow(p, meta, bytes));

  Future<void> _sendTrackNow(Peer p, TrackMeta meta, Uint8List bytes) async {
    if (track?.id != meta.id) return; // superseded before we started
    p.readyTrack = -1;
    p.dl = 0;
    p.wire.send({'t': 'track', 'meta': meta.toJson(), 'size': bytes.length});
    const chunk = 128 * 1024;
    for (var o = 0; o < bytes.length && !p.wire.closed; o += chunk) {
      p.wire.sendBytes(Uint8List.sublistView(bytes, o, math.min(bytes.length, o + chunk)));
      if (p.wire.pendingBytes > 1024 * 1024) await p.wire.flush();
      if (track?.id != meta.id) {
        p.wire.send({'t': 'trackAbort', 'track': meta.id});
        return;
      }
    }
    p.wire.send({'t': 'trackEnd', 'track': meta.id});
  }

  int _fetchSeq = 0;

  /// iPhone host: let an Android guest run yt-dlp for us.
  void _updateRemote() {
    if (YtDlp.supported) return;
    final ok = peers.any((p) => p.caps.contains('ytdlp'));
    YouTubeSource.I.remote = ok ? _fetchViaPeer : null;
  }

  Future<String> _fetchViaPeer(String videoId, void Function(double) progress) async {
    final helpers = peers.where((p) => p.caps.contains('ytdlp') && p.fetch == null).toList();
    if (helpers.isEmpty) throw 'No Android phone free to fetch from YouTube right now';
    final p = helpers.first;
    status = 'Fetching via ${p.name}';
    notify();
    final f = _Fetch(++_fetchSeq, videoId, progress);
    p.fetch = f;
    p.wire.send({'t': 'fetch', 'req': f.req, 'id': videoId});
    return f.completer.future.timeout(const Duration(minutes: 3), onTimeout: () {
      p.fetch = null;
      throw '${p.name} took too long to fetch the song';
    });
  }

  void _broadcast(Map<String, dynamic> m) {
    for (final p in peers) {
      p.wire.send(m);
    }
  }

  void _setSched(Sched s) {
    sched = s;
    s.apply();
    if (track != null) _broadcast({'t': 'sched', 'track': track!.id, ...s.toJson()});
    notify();
  }

  // ------------------------------------------------------------ transport
  void enqueue(QueueItem item, {bool playNow = false}) {
    if (playNow || track == null) {
      _playItem(item);
    } else {
      queue.add(item);
      notify();
    }
  }

  Future<void> _playItem(QueueItem item) async {
    busy = true;
    error = null;
    loadProgress = 0;
    status = item.meta.source == 'youtube'
        ? 'Downloading "${item.meta.title}"'
        : (item.meta.source == 'file' ? 'Preparing "${item.meta.title}"' : 'Loading "${item.meta.title}"');
    notify();
    try {
      final path = await item.resolve((p) {
        loadProgress = p * 0.5;
        notify();
      });
      await _playFile(path, item.meta);
    } catch (e) {
      error = '$e';
      status = track == null ? 'Pick a song' : 'Playing';
      busy = false;
      notify();
    }
  }

  Future<void> _playFile(String path, TrackMeta meta) async {
    final id = ++_trackSeq;
    final m = meta.withId(id);
    _setSched(Sched()); // stop everyone
    track = m;
    _trackBytes = await File(path).readAsBytes();
    duet.trackLoad(path);
    status = 'Sending to ${peers.length} device(s)';
    notify();
    final targets = List<Peer>.from(peers);
    for (final p in targets) {
      _sendTrack(p, m, _trackBytes!);
    }
    // Wait for everyone (and ourselves) to have >= 8 s decoded.
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      if (track?.id != id) return;
      final me = duet.trackStatus();
      if (me.error != 0) {
        track = null;
        throw 'Could not decode this file (error ${me.error})';
      }
      final selfReady = me.done || me.decodedSec >= 8;
      final live = targets.where((p) => peers.contains(p)).toList();
      final readyN = live.where((p) => p.readyTrack == id).length;
      final avg = live.isEmpty ? 1.0 : live.map((p) => p.readyTrack == id ? 1.0 : p.dl).reduce((a, b) => a + b) / live.length;
      loadProgress = 0.5 + 0.5 * avg;
      status = 'Preparing devices $readyN/${live.length}';
      notify();
      if (selfReady && readyN == live.length) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    busy = false;
    status = 'Playing';
    // Start everyone 800 ms from now (master time).
    _setSched(Sched(playing: true, frame: 0, at: duet.masterNow() + 800000000));
  }

  void togglePlay() => sched.playing && sched.end == Duet.infinity ? pause() : resume();

  void pause() {
    if (!sched.playing) return;
    final tp = duet.masterNow() + 200000000;
    final f = sched.frameAt(tp).round();
    _setSched(Sched(playing: true, frame: sched.frame, at: sched.at, end: tp));
    // Remember the paused position (engine stops itself at `tp`).
    Future.delayed(const Duration(milliseconds: 250), () {
      if (sched.end == tp) {
        sched = Sched(playing: false, frame: f, at: 0);
        _broadcast({'t': 'sched', 'track': track?.id, ...sched.toJson()});
        notify();
      }
    });
  }

  void resume() {
    if (track == null) return;
    final f = sched.frameAt(duet.masterNow()).round();
    _setSched(Sched(playing: true, frame: f, at: duet.masterNow() + 500000000));
  }

  void seek(double sec) {
    if (track == null) return;
    final wasPlaying = sched.playing && sched.end == Duet.infinity;
    final f = (sec * kRate).round();
    if (wasPlaying) {
      _setSched(Sched(playing: true, frame: f, at: duet.masterNow() + 400000000));
    } else {
      _setSched(Sched(playing: false, frame: f));
    }
  }

  void next() {
    if (queue.isEmpty) return;
    _playItem(queue.removeAt(0));
  }

  void _onTick() {
    // Auto-advance at the end of the track.
    final st = duet.trackStatus();
    if (track != null && !busy && st.done && sched.playing && sched.end == Duet.infinity) {
      if (sched.frameAt(duet.masterNow()) >= st.decoded) {
        if (queue.isNotEmpty) {
          next();
        } else {
          sched = Sched(playing: false, frame: 0);
          _setSched(sched);
        }
      }
    }
    notify();
  }

  // ------------------------------------------------------------ acoustic sync check
  /// Every device chirps in its own slot; the host microphone records all of
  /// them. Since all slots are measured in the same recording, the host's own
  /// mic/speaker latency cancels out: we get each guest's real offset vs host.
  Future<void> syncCheck() async {
    if (checking) return;
    if (!micOk) {
      checkReport = 'Microphone permission is needed for the sync check.';
      notify();
      return;
    }
    if (peers.isEmpty) {
      checkReport = 'No guests connected yet. Join from another phone first.';
      notify();
      return;
    }
    checking = true;
    final wasPlaying = sched.playing && sched.end == Duet.infinity;
    if (wasPlaying) pause();
    await Future.delayed(const Duration(milliseconds: 500));
    final slots = List<Peer>.from(peers);
    for (final p in slots) {
      p.beforeMs = null;
      p.residualMs = null;
    }
    final lines = <String>[];
    for (var round = 0; round < 3; round++) {
      checkReport = round == 0 ? 'Listening… (measure)' : (round == 1 ? 'Listening… (correct)' : 'Listening… (verify)');
      notify();
      const spacing = 700000000;
      final first = duet.masterNow() + 1200000000;
      duet.recordStart();
      duet.chirpAt(first);
      for (var i = 0; i < slots.length; i++) {
        slots[i].wire.send({'t': 'chirp', 'at': first + (i + 1) * spacing});
      }
      await Future.delayed(Duration(milliseconds: 1200 + (slots.length + 1) * 700 + 400));
      final res = duet.recordAnalyze(first, slots.length + 1, spacing);
      if (res[0] == null) {
        checkReport = "Couldn't hear this phone's own chirp. Turn the volume up and put the phones next to each other.";
        checking = false;
        notify();
        return;
      }
      for (var i = 0; i < slots.length; i++) {
        final p = slots[i];
        final r = res[i + 1];
        if (r == null) {
          p.residualMs = null;
          continue;
        }
        p.residualMs = r / 1e6;
        if (round == 0) p.beforeMs = r / 1e6;
        if (round < 2 && r.abs() < 300e6) {
          // Late by r => present later => add r to its latency correction.
          p.fixNs += r.round();
          p.wire.send({'t': 'fix', 'ns': p.fixNs});
        }
      }
      notify();
      await Future.delayed(const Duration(milliseconds: 300));
    }
    for (final p in slots) {
      lines.add('${p.name}: ${p.beforeMs == null ? "not heard" : "${_ms(p.beforeMs!)} → ${p.residualMs == null ? "?" : _ms(p.residualMs!)}"}');
    }
    checkReport = slots.isEmpty ? 'No guests connected.' : lines.join('\n');
    checking = false;
    if (wasPlaying) resume();
    notify();
  }

  static String _ms(double v) => '${v >= 0 ? "+" : ""}${v.toStringAsFixed(2)} ms';

  @override
  Future<void> close() async {
    _tick?.cancel();
    for (final p in List<Peer>.from(peers)) {
      p.wire.send({'t': 'bye'});
      await p.wire.flush().timeout(const Duration(milliseconds: 300), onTimeout: () {});
      p.wire.close();
    }
    await _server?.close();
    try {
      await _bc?.stop();
    } catch (_) {}
    duet.trackUnload();
    duet.clockStop();
    duet.engineStop();
  }
}

// ============================================================== guest
class GuestSession extends Session {
  @override
  bool get isHost => false;
  /// Candidate addresses for the host (Bonjour can return several).
  final List<String> hostIps;
  String hostIp;
  Wire? _wire;
  int? _sessionKey;
  bool _closing = false;
  bool _hostEnded = false;
  bool reconnecting = false;
  String hostName = '';
  IOSink? _sink;
  String? _path;
  int _received = 0;
  int _size = 0;
  int _loadedTrack = -1;
  Map<String, dynamic>? _pendingSched;
  Timer? _stats;
  bool connected = false;
  bool readySent = false;
  void Function()? onDisconnect;

  /// [port] from discovery; null (manual IP) tries all known ports.
  final List<int> ports;
  int _clockPort = -1;
  GuestSession(List<String> ips, {int? port})
      : hostIps = ips.where((e) => e.isNotEmpty).toList(),
        hostIp = ips.first,
        ports = port != null ? [port] : kControlPorts;

  /// Tries every candidate address, retrying for [within] (the first attempt
  /// on iOS may fail while the Local Network permission prompt is showing).
  Future<Socket> _dial(Duration within) async {
    final end = DateTime.now().add(within);
    Object? last;
    while (!_closing) {
      for (final ip in hostIps) {
        for (final port in ports) {
          try {
            final s = await Socket.connect(ip, port, timeout: Duration(milliseconds: ports.length > 1 ? 1500 : 3000));
            hostIp = ip;
            return s;
          } on SocketException catch (e) {
            last = e;
            // Refused = host reachable but not on this port: try the next one quickly.
          }
        }
      }
      if (DateTime.now().isAfter(end)) break;
      await Future.delayed(const Duration(milliseconds: 800));
    }
    throw last ?? 'cancelled';
  }

  Future<void> connect(String name) async {
    deviceName = name;
    final s = await _dial(const Duration(seconds: 12));
    final fix = await _loadFix();
    duet.engineStart(mic: false);
    duet.latencyFixNs = fix;
    _attach(s);
    status = 'Syncing clock…';
    _stats = Timer.periodic(const Duration(seconds: 1), (_) => _sendStats());
    notify();
  }

  void _attach(Socket s) {
    final w = Wire(s);
    _wire = w;
    connected = true;
    reconnecting = false;
    w.send({
      't': 'hello',
      'name': deviceName,
      'platform': Platform.operatingSystem,
      'fix': duet.latencyFixNs,
      'session': _sessionKey,
      'track': readySent ? _loadedTrack : -1,
      'caps': [if (YtDlp.supported) 'ytdlp'],
    });
    // Process strictly in order (handlers are async: file sink creation etc).
    () async {
      await for (final m in w.messages) {
        try {
          await _onMsg(m);
        } catch (e) {
          debugPrint('guest msg error: $e');
        }
      }
      if (_closing || _wire != w) return;
      connected = false;
      if (_hostEnded) {
        _ended('The host ended the party');
      } else {
        _reconnect();
      }
    }();
  }

  /// Test hook: simulate a Wi-Fi drop.
  void debugDropConnection() => _wire?.socket.destroy();

  /// Wi-Fi blip: keep playing on our own clock model while we redial.
  Future<void> _reconnect() async {
    reconnecting = true;
    status = 'Reconnecting…';
    notify();
    await _sink?.close();
    _sink = null;
    try {
      final s = await _dial(const Duration(seconds: 30));
      if (_closing) {
        s.destroy();
        return;
      }
      if (track != null && !readySent) {
        status = 'Reconnected, fetching the song again';
      } else {
        status = sched.playing ? 'Playing' : 'Ready';
      }
      _attach(s);
      notify();
    } catch (_) {
      _ended('Lost connection to the host');
    }
  }

  void _ended(String why) {
    connected = false;
    reconnecting = false;
    status = why;
    duet.setSchedule(playing: false, frame: 0, atMaster: 0);
    notify();
    onDisconnect?.call();
  }

  ClockStats get clock => duet.clockStats();
  EngineStats get engine => duet.engineStats();

  void _sendStats() {
    if (_wire == null || _wire!.closed) return;
    final c = duet.clockStats();
    final e = duet.engineStats();
    _wire!.send({
      't': 'stats',
      'rtt': c.rttMs,
      'offset': c.offsetMs,
      'skew': c.skewPpm,
      'locked': c.locked,
      'err': e.ctrlErrorUs,
      'ppm': e.ratePpm,
      'lat': e.outLatencyMs,
      'under': e.underruns,
      'resync': e.hardResyncs,
      'fix': duet.latencyFixNs,
    });
    if (status == 'Syncing clock…' && c.locked) status = track == null ? 'Waiting for the host to pick a song' : status;
    notify();
  }

  Future<void> _onMsg(Msg m) async {
    if (m.bytes != null) {
      _sink?.add(m.bytes!);
      _received += m.bytes!.length;
      loadProgress = _size > 0 ? _received / _size : 0;
      if ((_received ~/ (256 * 1024)) != ((_received - m.bytes!.length) ~/ (256 * 1024))) {
        _wire?.send({'t': 'progress', 'p': loadProgress * 0.8});
      }
      notify();
      return;
    }
    final j = m.json!;
    switch (m.t) {
      case 'welcome':
        hostName = j['host'] as String? ?? 'Host';
        final key = j['session'] as int?;
        if (_sessionKey != null && key != _sessionKey) {
          // Different party (host restarted): forget the old song.
          _loadedTrack = -1;
          readySent = false;
          track = null;
          sched = Sched();
          duet.setSchedule(playing: false, frame: 0, atMaster: 0);
        }
        _sessionKey = key;
        final cp = j['clock'] as int? ?? kClockPort;
        if (cp != _clockPort) {
          _clockPort = cp;
          duet.clockClient(hostIp, cp);
        }
        break;
      case 'bye':
        _hostEnded = true;
        break;
      case 'fetch':
        _serveFetch(j['req'] as int, j['id'] as String); // not awaited: keep handling sched etc.
        break;
      case 'trackAbort':
        await _sink?.close();
        _sink = null;
        break;
      case 'track':
        error = null;
        track = TrackMeta.fromJson(j['meta'] as Map<String, dynamic>);
        _size = j['size'] as int;
        _received = 0;
        loadProgress = 0;
        readySent = false;
        _loadedTrack = -1;
        duet.setSchedule(playing: false, frame: 0, atMaster: 0);
        sched = Sched();
        await _sink?.close();
        _path = '${(await _work()).path}/rx_${track!.id}.bin';
        _sink = File(_path!).openWrite();
        status = 'Receiving "${track!.title}"';
        busy = true;
        break;
      case 'trackEnd':
        final id = j['track'] as int;
        await _sink?.flush();
        await _sink?.close();
        _sink = null;
        if (track?.id != id || _path == null) break;
        duet.trackLoad(_path!);
        _loadedTrack = id;
        status = 'Decoding';
        _waitReady(id);
        if (_pendingSched != null && _pendingSched!['track'] == id) {
          sched = Sched.fromJson(_pendingSched!);
          sched.apply();
        }
        break;
      case 'sched':
        if (j['track'] == _loadedTrack) {
          sched = Sched.fromJson(j);
          sched.apply();
          status = sched.playing ? 'Playing' : 'Paused';
        } else {
          _pendingSched = j;
        }
        break;
      case 'chirp':
        duet.chirpAt(j['at'] as int);
        break;
      case 'fix':
        duet.latencyFixNs = j['ns'] as int;
        _saveFix(j['ns'] as int);
        break;
    }
    notify();
  }

  /// Host (iPhone) asked us to fetch a YouTube song with yt-dlp.
  Future<void> _serveFetch(int req, String videoId) async {
    final w = _wire;
    if (w == null) return;
    try {
      var last = 0.0;
      final path = await YtDlp.download(videoId, Directory(await workPath('')), (p) {
        if (p - last >= 0.05 || p >= 1) {
          last = p;
          w.send({'t': 'fetchProgress', 'req': req, 'p': p});
        }
      });
      final bytes = await File(path).readAsBytes();
      w.send({'t': 'fetchBegin', 'req': req, 'size': bytes.length, 'ext': path.split('.').last});
      const chunk = 128 * 1024;
      for (var o = 0; o < bytes.length && !w.closed; o += chunk) {
        w.sendBytes(Uint8List.sublistView(bytes, o, math.min(bytes.length, o + chunk)));
        if (w.pendingBytes > 1024 * 1024) await w.flush();
      }
      w.send({'t': 'fetchEnd', 'req': req});
    } catch (e) {
      w.send({'t': 'fetchError', 'req': req, 'msg': '$e'});
    }
  }

  Future<void> _waitReady(int id) async {
    while (_loadedTrack == id && connected) {
      final s = duet.trackStatus();
      if (s.error != 0) {
        error = 'Could not decode the song (error ${s.error})';
        busy = false;
        notify();
        return;
      }
      if (s.done || s.decodedSec >= 8) {
        _wire?.send({'t': 'ready', 'track': id});
        readySent = true;
        busy = false;
        loadProgress = 1;
        if (!sched.playing) status = 'Ready';
        notify();
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<File> _fixFile() async => File('${(await getApplicationSupportDirectory()).path}/latency_fix.json');
  Future<int> _loadFix() async {
    try {
      final f = await _fixFile();
      if (f.existsSync()) return (jsonDecode(f.readAsStringSync())['ns'] as num).toInt();
    } catch (_) {}
    return 0;
  }

  Future<void> _saveFix(int ns) async {
    try {
      final f = await _fixFile();
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'ns': ns}));
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    _closing = true;
    _stats?.cancel();
    _wire?.close();
    await _sink?.close();
    duet.trackUnload();
    duet.clockStop();
    duet.engineStop();
  }
}

Future<String> workPath(String name) async => '${(await _work()).path}/$name';

/// Persisted device name (shown to other phones).
Future<String?> loadDeviceName() async {
  try {
    final f = File('${(await getApplicationSupportDirectory()).path}/name.txt');
    if (f.existsSync()) return f.readAsStringSync().trim();
  } catch (_) {}
  return null;
}

Future<void> saveDeviceName(String n) async {
  try {
    final f = File('${(await getApplicationSupportDirectory()).path}/name.txt');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(n);
  } catch (_) {}
}
