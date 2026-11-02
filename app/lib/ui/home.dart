import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/session.dart';
import '../core/sources.dart';
import 'join.dart';
import 'player.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _bg = AnimationController(vsync: this, duration: const Duration(seconds: 18))..repeat();
  final _name = TextEditingController(
      text: '${Platform.isIOS ? 'iPhone' : 'Android'} ${100 + math.Random().nextInt(900)}');
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    loadDeviceName().then((n) {
      if (n != null && n.isNotEmpty && mounted) setState(() => _name.text = n);
    });
    // Test hook: DUET_AUTO=host | join:<ip>  (DUET_DEMO=1 auto-plays the demo beat as host)
    const def = String.fromEnvironment('DUET_AUTO');
    final auto = def.isNotEmpty ? def : Platform.environment['DUET_AUTO'];
    debugPrint('DUET_AUTO=$auto');
    if (auto != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (auto == 'host') {
          _host();
        } else if (auto.startsWith('join:')) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => JoinScreen(name: _name.text.trim(), autoIp: auto.substring(5))));
        }
      });
    }
  }

  @override
  void dispose() {
    _bg.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _host() async {
    saveDeviceName(_name.text.trim());
    setState(() => _starting = true);
    final micOk = Platform.isIOS ? await duet.requestMicIOS() : (await Permission.microphone.request()).isGranted;
    final s = HostSession();
    try {
      await s.start(_name.text.trim().isEmpty ? 'DuetPlus' : _name.text.trim(), mic: micOk);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start session: $e')));
        setState(() => _starting = false);
      }
      return;
    }
    WakelockPlus.enable();
    if (!mounted) return;
    setState(() => _starting = false);
    const demo = int.fromEnvironment('DUET_DEMO'); // test hook: auto-play demo after N s
    if (demo > 0) {
      const file = String.fromEnvironment('DUET_FILE'); // test hook: play a local file instead
      const ytq = String.fromEnvironment('DUET_YTQ'); // test hook: play first YouTube Music result
      if (ytq.isNotEmpty) {
        Future.delayed(const Duration(seconds: demo), () async {
          final r = await YouTubeSource.I.searchMusic(ytq);
          if (r.isNotEmpty) s.enqueue(YouTubeSource.I.item(r.first), playNow: true);
        });
      } else {
        const yt = String.fromEnvironment('DUET_YT'); // test hook: play a YouTube video id
        Future.delayed(
            const Duration(seconds: demo),
            () => s.enqueue(
                yt.isNotEmpty
                    ? YouTubeSource.I.item(YtResult(yt, 'YouTube test', 'yt-dlp', 'https://i.ytimg.com/vi/$yt/maxresdefault.jpg', null))
                    : (file.isEmpty ? demoItem() : fileItem(file, file.split('/').last)),
                playNow: true));
      }
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(session: s)));
    WakelockPlus.disable();
  }

  void _join() {
    saveDeviceName(_name.text.trim());
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => JoinScreen(name: _name.text.trim())));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Stack(children: [
        Positioned.fill(child: AnimatedBuilder(animation: _bg, builder: (_, __) => CustomPaint(painter: _OrbsPainter(_bg.value)))),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: c.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(height: 40),
                    Column(children: [
                      const _Logo(size: 120),
                      const SizedBox(height: 28),
                      const GradientText('DuetPlus', style: TextStyle(fontSize: 46, fontWeight: FontWeight.w900, letterSpacing: -1)),
                      const SizedBox(height: 10),
                      Text('Every phone. One sound.\nSample-accurate sync over Wi-Fi.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.dim, fontSize: 16, height: 1.4)),
                    ]),
                    Column(children: [
                      const SizedBox(height: 32),
                      TextField(
                        controller: _name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.smartphone_rounded, color: AppColors.dim), hintText: 'This phone\'s name'),
                      ),
                      const SizedBox(height: 18),
                      GradientButton(
                          label: _starting ? 'Starting…' : 'Host a party',
                          icon: Icons.podcasts_rounded,
                          onTap: _starting ? null : _host),
                      const SizedBox(height: 14),
                      GradientButton(label: 'Join a party', icon: Icons.wifi_tethering_rounded, outlined: true, onTap: _join),
                      const SizedBox(height: 18),
                      Text('All phones must be on the same Wi-Fi (or the host\'s hotspot).',
                          textAlign: TextAlign.center, style: TextStyle(color: AppColors.dim.withValues(alpha: 0.8), fontSize: 12.5)),
                      const SizedBox(height: 24),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Logo extends StatelessWidget {
  final double size;
  const _Logo({required this.size});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 1.5,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        Positioned(
          left: 0,
          child: _circle(size, const [AppColors.a1, AppColors.a2]),
        ),
        Positioned(
          right: 0,
          child: _circle(size, const [AppColors.a2, AppColors.a3]),
        ),
        const Icon(Icons.graphic_eq_rounded, size: 54, color: Colors.white),
      ]),
    );
  }

  Widget _circle(double s, List<Color> c) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: c.map((e) => e.withValues(alpha: 0.75)).toList()),
          boxShadow: [BoxShadow(color: c.last.withValues(alpha: 0.5), blurRadius: 40)],
        ),
      );
}

class _OrbsPainter extends CustomPainter {
  final double t;
  _OrbsPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    void orb(Color c, double phase, double r, double ax, double ay) {
      final a = 2 * math.pi * (t + phase);
      final center = Offset(size.width * (0.5 + ax * math.cos(a)), size.height * (0.4 + ay * math.sin(a)));
      final p = Paint()
        ..shader = RadialGradient(colors: [c.withValues(alpha: 0.35), c.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: center, radius: r));
      canvas.drawCircle(center, r, p);
    }

    orb(AppColors.a1, 0.0, size.width * 0.8, 0.35, 0.18);
    orb(AppColors.a2, 0.33, size.width * 0.9, 0.3, 0.25);
    orb(AppColors.a3, 0.66, size.width * 0.7, 0.4, 0.2);
  }

  @override
  bool shouldRepaint(covariant _OrbsPainter old) => old.t != t;
}
