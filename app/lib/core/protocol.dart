// Wire protocol on the TCP control/data channel.
// Frame: [u32 BE length][u8 kind][payload]; kind 1 = JSON, 2 = file bytes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int kControlPort = 47800;
const int kClockPort = 47801;
/// Control ports tried in order (clock = control + 1) if one is busy.
const List<int> kControlPorts = [47800, 47810, 47820, 47830];
const String kServiceType = '_duetplus._tcp';

class Msg {
  final Map<String, dynamic>? json;
  final Uint8List? bytes;
  Msg.json(this.json) : bytes = null;
  Msg.bytes(this.bytes) : json = null;
  String get t => json?['t'] as String? ?? '';
}

class Wire {
  final Socket socket;
  final _out = StreamController<Msg>();
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  late final StreamSubscription _sub;
  bool _closed = false;

  Wire(this.socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = socket.listen(_onData, onDone: close, onError: (_) => close(), cancelOnError: true);
  }

  Stream<Msg> get messages => _out.stream;
  bool get closed => _closed;

  void _onData(Uint8List data) {
    if (_pending.isNotEmpty) {
      _buf.add(_pending);
      _buf.add(data);
      _pending = _buf.takeBytes();
    } else {
      _pending = data;
    }
    var off = 0;
    while (_pending.length - off >= 5) {
      final bd = ByteData.sublistView(_pending, off);
      final len = bd.getUint32(0);
      if (_pending.length - off - 4 < len) break;
      final kind = _pending[off + 4];
      final payload = Uint8List.sublistView(_pending, off + 5, off + 4 + len);
      off += 4 + len;
      if (kind == 1) {
        _out.add(Msg.json(jsonDecode(utf8.decode(payload)) as Map<String, dynamic>));
      } else {
        _out.add(Msg.bytes(Uint8List.fromList(payload)));
      }
    }
    _pending = off == _pending.length ? Uint8List(0) : Uint8List.fromList(Uint8List.sublistView(_pending, off));
  }

  // All writes go through one queue: a Dart socket must not be written to
  // while a flush is in progress (control messages during file transfer).
  final List<List<int>> _q = [];
  int _queued = 0;
  bool _pumping = false;
  Completer<void>? _idle;

  /// Bytes waiting to be written (for backpressure on big transfers).
  int get pendingBytes => _queued;

  void _frame(int kind, List<int> payload) {
    if (_closed) return;
    final h = ByteData(5)
      ..setUint32(0, payload.length + 1)
      ..setUint8(4, kind);
    _q.add(h.buffer.asUint8List());
    _q.add(payload);
    _queued += payload.length + 5;
    _pump();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_q.isNotEmpty && !_closed) {
        final batch = List<List<int>>.from(_q);
        _q.clear();
        var n = 0;
        for (final b in batch) {
          socket.add(b);
          n += b.length;
        }
        await socket.flush();
        _queued -= n;
      }
    } catch (_) {
      close();
    } finally {
      _pumping = false;
      final i = _idle;
      _idle = null;
      i?.complete();
    }
  }

  void send(Map<String, dynamic> m) => _frame(1, utf8.encode(jsonEncode(m)));
  void sendBytes(List<int> b) => _frame(2, b);

  /// Completes once everything queued so far has been handed to the OS.
  Future<void> flush() async {
    if (_closed || (!_pumping && _q.isEmpty)) return;
    _idle ??= Completer<void>();
    await _idle!.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _idle?.complete();
    _idle = null;
    _sub.cancel();
    socket.destroy();
    _out.close();
  }
}

/// All non-loopback IPv4 addresses (Wi-Fi first, then hotspot/bridge/other).
Future<List<String>> localIPv4s() async {
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final wifi = <String>[], other = <String>[];
    for (final i in ifs) {
      final n = i.name.toLowerCase();
      if (n.startsWith('pdp_ip') || n.startsWith('rmnet') || n.startsWith('utun') || n.startsWith('ipsec')) continue; // cellular/VPN
      for (final a in i.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        (n.startsWith('en') || n.startsWith('wlan') ? wifi : other).add(a.address);
      }
    }
    return [...wifi, ...other];
  } catch (_) {
    return [];
  }
}

/// Best-effort LAN IPv4 of this device (for display / manual join).
Future<String?> localIPv4() async {
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    String? fallback;
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (a.isLoopback) continue;
        final n = i.name.toLowerCase();
        if (n.startsWith('en') || n.startsWith('wlan') || n.startsWith('ap') || n.startsWith('swlan')) return a.address;
        fallback ??= a.address;
      }
    }
    return fallback;
  } catch (_) {
    return null;
  }
}
