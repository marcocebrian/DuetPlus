import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/protocol.dart';
import '../core/session.dart';
import 'player.dart';
import 'theme.dart';

class _Found {
  final String name;
  List<String> ips = [];
  int? port;
  _Found(this.name);
  String? get ip => ips.isEmpty ? null : ips.first;
}

class JoinScreen extends StatefulWidget {
  final String name;
  final String? autoIp;
  const JoinScreen({super.key, required this.name, this.autoIp});
  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  BonsoirDiscovery? _disc;
  StreamSubscription? _sub;
  final Map<String, _Found> _found = {};
  final _ip = TextEditingController();
  bool _connecting = false;
  String? _connectingTo;
  String? _prefix; // our subnet, e.g. "192.168.1."
  bool _slow = false; // nothing found after a while -> show help
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
    localIPv4().then((me) {
      if (me == null || !mounted) return;
      final p = me.substring(0, me.lastIndexOf('.') + 1);
      setState(() {
        _prefix = p;
        if (_ip.text.isEmpty) _ip.text = p;
      });
    });
    Future.delayed(const Duration(seconds: 7), () {
      if (mounted && _found.isEmpty) setState(() => _slow = true);
    });
    if (widget.autoIp != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect(widget.autoIp!));
    }
  }

  Future<void> _startDiscovery() async {
    try {
      _disc = BonsoirDiscovery(type: kServiceType);
      await _disc!.initialize();
      _sub = _disc!.eventStream!.listen((e) {
        switch (e) {
          case BonsoirDiscoveryServiceFoundEvent():
            _found.putIfAbsent(e.service.name, () => _Found(e.service.name));
            e.service.resolve(_disc!.serviceResolver);
            break;
          case BonsoirDiscoveryServiceResolvedEvent():
            final f = _found.putIfAbsent(e.service.name, () => _Found(e.service.name));
            final all = e.service.hostAddresses;
            final v4 = all.where((a) => a.contains('.') && !a.startsWith('127.')).toList();
            final v6 = all.where((a) => a.contains(':') && !a.startsWith('fe80')).toList();
            f.port = e.service.port;
            f.ips = [...v4, ...v6, if (e.service.hostname != null) e.service.hostname!.replaceAll(RegExp(r'\.$'), '')];
            break;
          case BonsoirDiscoveryServiceLostEvent():
            _found.remove(e.service.name);
            break;
          default:
            break;
        }
        if (mounted) setState(() {});
      });
      await _disc!.start();
    } catch (e) {
      setState(() => _error = 'Discovery unavailable ($e). Enter the host IP below.');
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _sub?.cancel();
    _disc?.stop();
    _ip.dispose();
    super.dispose();
  }

  Future<void> _connect(String ip, {List<String>? all, String? name, int? port}) async {
    ip = ip.trim();
    if (_connecting || ip.isEmpty) return;
    // Typed only the last part ("23")? Complete it with our own subnet.
    if (RegExp(r'^\d{1,3}$').hasMatch(ip) && _prefix != null) ip = '$_prefix$ip';
    setState(() {
      _connecting = true;
      _connectingTo = name ?? ip;
      _error = null;
    });
    final s = GuestSession(all ?? [ip], port: port);
    try {
      await s.connect(widget.name.isEmpty ? 'Guest' : widget.name);
    } catch (e) {
      await s.close();
      setState(() {
        _connecting = false;
        _error = 'Could not reach ${name ?? ip}. Check that both phones are on the same Wi-Fi'
            '${Platform.isIOS ? ' and that Local Network is allowed for DuetPlus (Settings → Privacy)' : ''}.';
      });
      return;
    }
    WakelockPlus.enable();
    if (!mounted) return;
    setState(() => _connecting = false);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(session: s)));
    WakelockPlus.disable();
  }

  @override
  Widget build(BuildContext context) {
    final items = _found.values.toList();
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Join a party')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              height: 190,
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) => CustomPaint(painter: _RadarPainter(_pulse.value), child: const Center(
                  child: Icon(Icons.wifi_tethering_rounded, size: 46, color: Colors.white),
                )),
              ),
            ),
            Text(items.isEmpty ? 'Looking for parties nearby…' : 'Parties nearby',
                style: const TextStyle(fontSize: 15, color: AppColors.dim, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(children: [
                for (final f in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(18),
                      child: ListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(shape: BoxShape.circle, gradient: AppColors.grad),
                          child: const Icon(Icons.podcasts_rounded, color: Colors.white),
                        ),
                        title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(f.ip ?? 'resolving…', style: const TextStyle(color: AppColors.dim)),
                        trailing: _connecting && _connectingTo == f.name
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.arrow_forward_rounded),
                        onTap: f.ip == null ? null : () => _connect(f.ip!, all: f.ips, name: f.name, port: f.port),
                      ),
                    ),
                  ),
              ]),
            ),
            if (_slow && items.isEmpty && _error == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                    'Nothing yet? Make sure the host tapped "Host a party" and both phones are on the same Wi-Fi '
                    '(or this phone is on the host\'s hotspot)'
                    '${Platform.isIOS ? '. On iPhone, allow Local Network for DuetPlus in Settings → Privacy' : ''}. '
                    'You can also type the IP shown on the host.',
                    style: const TextStyle(color: AppColors.dim, fontSize: 12.5, height: 1.35)),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error!, style: const TextStyle(color: AppColors.bad)),
              ),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _ip,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(hintText: 'Host IP (shown on the host screen)'),
                  onSubmitted: _connect,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 54,
                child: FilledButton(
                  style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  onPressed: _connecting ? null : () => _connect(_ip.text),
                  child: const Text('Join'),
                ),
              ),
            ]),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double t;
  _RadarPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final r = 30 + p * size.height * 0.55;
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Color.lerp(AppColors.a3, AppColors.a1, p)!.withValues(alpha: (1 - p) * 0.8));
    }
    canvas.drawCircle(c, 34, Paint()..shader = AppColors.grad.createShader(Rect.fromCircle(center: c, radius: 34)));
    final sweep = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi / 2,
        colors: [AppColors.a3.withValues(alpha: 0), AppColors.a3.withValues(alpha: 0.25)],
        transform: GradientRotation(t * 2 * math.pi),
      ).createShader(Rect.fromCircle(center: c, radius: size.height * 0.6));
    canvas.drawCircle(c, size.height * 0.6, sweep);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) => old.t != t;
}
