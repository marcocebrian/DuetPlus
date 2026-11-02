import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/session.dart';
import 'devices.dart';
import 'music_sheet.dart';
import 'theme.dart';
import 'visualizer.dart';

class PlayerScreen extends StatefulWidget {
  final Session session;
  const PlayerScreen({super.key, required this.session});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with SingleTickerProviderStateMixin {
  final spec = SpectrumModel();
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final _pos = ValueNotifier<double>(0);
  final _spin = ValueNotifier<double>(0);
  double _spinSpeed = 0;
  double? _dragging;
  int? _paletteFor;
  List<Color> _palette = const [AppColors.a1, AppColors.a2, AppColors.a3];
  StreamSubscription<String>? _evSub;
  final List<_Toast> _toasts = [];

  Session get s => widget.session;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      final dt = (d - _last).inMicroseconds / 1e6;
      _last = d;
      final audible = s.audible;
      spec.tick(dt, playing: audible);
      if (const bool.fromEnvironment('DUET_DEBUG') && (d.inMilliseconds ~/ 5000) != (_last.inMilliseconds - (dt * 1000).round()) ~/ 5000) {
        debugPrint('beats=${spec.beats} energy=${spec.energy.toStringAsFixed(2)} bass=${spec.bass.toStringAsFixed(2)}');
      }
      _pos.value = s.positionSec;
      // Record spin: eases in/out with playback.
      _spinSpeed += ((audible ? 1.0 : 0.0) - _spinSpeed) * math.min(1.0, dt * 2.5);
      _spin.value = (_spin.value + dt * _spinSpeed * 2 * math.pi / 14) % (2 * math.pi);
      _maybePalette();
    })
      ..start();
    _evSub = s.events.listen((e) {
      final t = _Toast(e);
      setState(() => _toasts.add(t));
      Future.delayed(const Duration(milliseconds: 2600), () {
        if (mounted) setState(() => _toasts.remove(t));
      });
    });
    if (s is GuestSession) {
      (s as GuestSession).onDisconnect = () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.status)));
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.of(context).maybePop();
        });
      };
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _evSub?.cancel();
    _spin.dispose();
    spec.dispose();
    _pos.dispose();
    s.close();
    s.dispose();
    super.dispose();
  }

  void _maybePalette() {
    final t = s.track;
    if (t == null || t.id == _paletteFor) return;
    _paletteFor = t.id;
    Future<void> apply(List<Color> p) async {
      if (!mounted || _paletteFor != t.id) return;
      setState(() => _palette = p);
      spec.palette = p;
    }

    if (t.image != null) {
      extractPalette(t.image!).then((p) => apply(p ?? paletteFromSeed(t.title)));
    } else if (t.source == 'demo') {
      apply(const [AppColors.a1, AppColors.a2, AppColors.a3]);
    } else {
      apply(paletteFromSeed(t.title));
    }
  }

  Future<bool> _confirmLeave() async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(s.isHost ? 'End the party?' : 'Leave the party?'),
        content: Text(s.isHost ? 'All guests will be disconnected.' : 'This phone will stop playing.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.isHost ? 'End' : 'Leave')),
        ],
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: ListenableBuilder(
        listenable: s,
        builder: (context, _) => Scaffold(
          body: Stack(children: [
            Positioned.fill(child: _Backdrop(image: s.track?.image, artKey: s.track?.id, palette: _palette)),
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: AmbientPainter(spec)))),
            SafeArea(
              child: Column(children: [
                _topBar(context),
                if (s is HostSession && (s as HostSession).peers.isEmpty) _inviteCard(s as HostSession),
                Expanded(child: _art()),
                _titleBlock(),
                const SizedBox(height: 10),
                SizedBox(
                  height: 56,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 26),
                    child: CustomPaint(painter: BarsPainter(spec), size: Size.infinite),
                  ),
                ),
                const SizedBox(height: 8),
                _progress(),
                const SizedBox(height: 6),
                s.isHost ? _hostControls(context) : _guestPanel(),
                const SizedBox(height: 14),
              ]),
            ),
            if (s.busy) _busyOverlay(),
            if (!s.busy && s.error != null) _errorBanner(),
            if (s is HostSession && (s as HostSession).checking) _checkOverlay(s as HostSession),
            Positioned(
              top: MediaQuery.of(context).padding.top + 64,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Column(children: [for (final t in _toasts) _ToastView(key: ValueKey(t), text: t.text)]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final host = s is HostSession ? s as HostSession : null;
    final guest = s is GuestSession ? s as GuestSession : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
          onPressed: () async {
            if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
          },
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(host != null ? 'HOSTING' : 'LISTENING WITH',
                style: const TextStyle(fontSize: 11, letterSpacing: 1.6, color: AppColors.dim, fontWeight: FontWeight.w700)),
            Text(host != null ? '${s.deviceName}${host.ip != null ? ' · ${host.ip}' : ''}' : (guest!.hostName.isEmpty ? guest.hostIp : guest.hostName),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (host != null)
          _Chip(
            icon: Icons.devices_rounded,
            label: '${host.peers.length + 1}',
            onTap: () => showDevicesSheet(context, host),
          ),
        if (guest != null) _SyncBadge(guest: guest),
      ]),
    );
  }

  Widget _art() {
    final t = s.track;
    return LayoutBuilder(builder: (context, c) {
      final side = (c.biggest.shortestSide * 0.60).clamp(120.0, 340.0);
      return Stack(alignment: Alignment.center, children: [
        Positioned.fill(child: CustomPaint(painter: GlowPainter(spec, side / 2))),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: Curves.easeOutBack,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 0.7, end: 1.0).animate(a), child: child),
          ),
          child: AnimatedBuilder(
            key: ValueKey(t?.id ?? -1),
            animation: Listenable.merge([spec, _spin]),
            builder: (_, child) => Transform.scale(
              scale: 1 + spec.bass * 0.03 + spec.beat * 0.025,
              child: Transform.rotate(angle: _spin.value, child: child),
            ),
            child: _Disc(side: side, image: t?.image, palette: _palette),
          ),
        ),
      ]);
    });
  }

  Widget _titleBlock() {
    final t = s.track;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: child),
      ),
      child: Padding(
      key: ValueKey('${t?.id}-${t == null ? s.status : ''}'),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(children: [
        Text(t?.title ?? (s.isHost ? 'Pick a song to start the party' : 'Waiting for the host'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.2)),
        const SizedBox(height: 6),
        Text(t?.artist ?? s.status,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, color: AppColors.dim)),
      ]),
    ));
  }

  Widget _progress() {
    return ValueListenableBuilder<double>(
      valueListenable: _pos,
      builder: (context, pos, _) {
        final dur = s.track == null ? 0.0 : s.durationSec;
        final v = _dragging ?? (dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: _palette[2],
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: s.isHost ? 7 : 0),
              ),
              child: Slider(
                value: v.toDouble(),
                onChanged: s.isHost && dur > 0 ? (x) => setState(() => _dragging = x) : null,
                onChangeEnd: s.isHost && dur > 0
                    ? (x) {
                        (s as HostSession).seek(x * dur);
                        setState(() => _dragging = null);
                      }
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(_fmt(_dragging != null ? _dragging! * dur : pos), style: const TextStyle(color: AppColors.dim, fontSize: 12)),
                Text(_fmt(dur), style: const TextStyle(color: AppColors.dim, fontSize: 12)),
              ]),
            ),
          ]),
        );
      },
    );
  }

  Widget _hostControls(BuildContext context) {
    final h = s as HostSession;
    final playing = h.sched.playing && h.sched.end > duet.masterNow();
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _RoundBtn(
          icon: Icons.hearing_rounded,
          label: 'Sync check',
          busy: h.checking,
          onTap: h.checking ? null : () => _runSyncCheck(context, h),
        ),
        GestureDetector(
          onTap: h.track == null ? () => showMusicSheet(context, h) : h.togglePlay,
          child: Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: _palette), boxShadow: [
              BoxShadow(color: _palette[1].withValues(alpha: 0.6), blurRadius: 26),
            ]),
            child: Icon(h.track == null ? Icons.add_rounded : (playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                size: 44, color: Colors.white),
          ),
        ),
        _RoundBtn(
          icon: Icons.skip_next_rounded,
          label: h.queue.isEmpty ? 'Next' : 'Next (${h.queue.length})',
          onTap: h.queue.isEmpty ? null : h.next,
        ),
      ]),
      const SizedBox(height: 14),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: GradientButton(
          label: 'Add music',
          icon: Icons.library_music_rounded,
          outlined: true,
          onTap: () => showMusicSheet(context, h),
        ),
      ),
    ]);
  }

  Future<void> _runSyncCheck(BuildContext context, HostSession h) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Acoustic sync check'),
        content: const Text(
            'Put all phones next to this one with the volume up and keep the room quiet.\n\n'
            'Each phone plays a short chirp at a precise time. This phone\'s microphone '
            'measures when each chirp really comes out of the speaker, then corrects each phone '
            'and checks again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Start')),
        ],
      ),
    );
    if (go != true) return;
    await h.syncCheck();
    if (!context.mounted) return;
    showDevicesSheet(context, h, title: 'Sync check result');
  }

  Widget _guestPanel() {
    final g = s as GuestSession;
    final c = g.clock;
    final e = g.engine;
    Widget stat(String k, String v, [Color? col]) => Expanded(
          child: Column(children: [
            Text(v, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: col ?? AppColors.text)),
            const SizedBox(height: 2),
            Text(k, style: const TextStyle(fontSize: 11, color: AppColors.dim, letterSpacing: 0.5)),
          ]),
        );
    final errMs = e.ctrlErrorUs / 1000;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(color: AppColors.surface.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(22)),
        child: Column(children: [
          Text(g.status, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(children: [
            stat('NETWORK RTT', '${c.rttMs.toStringAsFixed(1)} ms'),
            stat('PLAYOUT ERR', '${errMs.abs() < 0.05 ? '0.0' : errMs.toStringAsFixed(2)} ms',
                errMs.abs() < 1 ? AppColors.good : (errMs.abs() < 5 ? AppColors.warn : AppColors.bad)),
            stat('ACOUSTIC FIX', '${(duet.latencyFixNs / 1e6).toStringAsFixed(1)} ms'),
          ]),
        ]),
      ),
    );
  }

  Widget _busyOverlay() {
    return Positioned(
      left: 20,
      right: 20,
      top: MediaQuery.of(context).padding.top + 70,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.surface.withValues(alpha: 0.7),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.status, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: s.loadProgress > 0 ? s.loadProgress : null,
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  color: AppColors.a3,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _inviteCard(HostSession h) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _palette[1].withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          const _PulseDot(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Invite friends', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(
                'On their phone: DuetPlus → Join a party → "${h.deviceName}"'
                '${h.ips.isNotEmpty ? '\nor type ${h.ips.join('  ·  ')}' : ''}',
                style: const TextStyle(color: AppColors.dim, fontSize: 12.5, height: 1.35),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _errorBanner() {
    return Positioned(
      left: 16,
      right: 16,
      top: MediaQuery.of(context).padding.top + 66,
      child: Material(
        color: const Color(0xFF2A1218),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.bad),
            const SizedBox(width: 10),
            Expanded(child: Text(s.error!, style: const TextStyle(fontSize: 13.5, height: 1.3))),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () {
                s.error = null;
                s.notify();
              },
            ),
          ]),
        ),
      ),
    );
  }

  Widget _checkOverlay(HostSession h) {
    return Positioned.fill(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            color: AppColors.bg.withValues(alpha: 0.6),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(
                width: 260,
                height: 260,
                child: AnimatedBuilder(
                  animation: spec,
                  builder: (_, __) => CustomPaint(
                    painter: _WavesPainter((spec.phase * 3) % 1.0 + (DateTime.now().millisecondsSinceEpoch % 1600) / 1600),
                    child: const Center(child: Icon(Icons.hearing_rounded, size: 52, color: Colors.white)),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(h.checkReport, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text('Keep the phones together and the room quiet',
                  style: TextStyle(color: AppColors.dim)),
            ]),
          ),
        ),
      ),
    );
  }

  static String _fmt(double sec) {
    if (sec.isNaN || sec < 0) sec = 0;
    final m = sec ~/ 60, x = (sec % 60).floor();
    return '$m:${x.toString().padLeft(2, '0')}';
  }
}

class _ArtPlaceholder extends StatelessWidget {
  const _ArtPlaceholder();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Backdrop extends StatelessWidget {
  final ImageProvider? image;
  final int? artKey;
  final List<Color> palette;
  const _Backdrop({this.image, this.artKey, required this.palette});
  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: palette[1]),
        duration: const Duration(milliseconds: 1200),
        builder: (_, c1, __) => TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: palette[0]),
          duration: const Duration(milliseconds: 1200),
          builder: (_, c0, __) => DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.35),
                radius: 1.1,
                colors: [c1!.withValues(alpha: 0.38), c0!.withValues(alpha: 0.12), AppColors.bg],
                stops: const [0, 0.5, 1],
              ),
            ),
          ),
        ),
      ),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 900),
        child: image == null
            ? const SizedBox.expand()
            : Opacity(
                key: ValueKey(artKey),
                opacity: 0.45,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                  child: Image(image: image!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
                ),
              ),
      ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0x99000000), AppColors.bg],
            stops: [0.3, 0.75, 1],
          ),
        ),
      ),
    ]);
  }
}

/// Album art pressed into a spinning record.
class _Disc extends StatelessWidget {
  final double side;
  final ImageProvider? image;
  final List<Color> palette;
  const _Disc({required this.side, this.image, required this.palette});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.65), blurRadius: 34, offset: const Offset(0, 14))],
        gradient: LinearGradient(colors: palette, begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        if (image != null)
          Image(image: image!, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) => const _ArtPlaceholder())
        else
          const _ArtPlaceholder(),
        // Vinyl grooves + sheen
        CustomPaint(painter: _GroovePainter()),
        Center(
          child: Container(
            width: side * 0.16,
            height: side * 0.16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.bg,
              border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 2),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 6)],
            ),
          ),
        ),
      ]),
    );
  }
}

class _GroovePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.black.withValues(alpha: 0.10);
    for (var k = 0.30; k < 0.98; k += 0.035) {
      canvas.drawCircle(c, r * k, p);
    }
    // Light sheen that rotates with the disc
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = SweepGradient(colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.16),
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0),
          ], stops: const [0, 0.12, 0.3, 0.62, 0.8])
              .createShader(Rect.fromCircle(center: c, radius: r)));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => SizedBox(
          width: 28,
          height: 28,
          child: Stack(alignment: Alignment.center, children: [
            Container(
              width: 10 + 18 * _c.value,
              height: 10 + 18 * _c.value,
              decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.a3.withValues(alpha: 0.5 * (1 - _c.value))),
            ),
            Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.a3)),
          ]),
        ),
      );
}

class _Toast {
  final String text;
  _Toast(this.text);
}

class _ToastView extends StatelessWidget {
  final String text;
  const _ToastView({super.key, required this.text});
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutBack,
      builder: (_, v, child) => Opacity(
        opacity: v.clamp(0, 1),
        child: Transform.translate(offset: Offset(0, (1 - v) * -24), child: child),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface2.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.a2.withValues(alpha: 0.5)),
          boxShadow: [BoxShadow(color: AppColors.a2.withValues(alpha: 0.3), blurRadius: 18)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(text.endsWith('left') ? Icons.logout_rounded : Icons.waving_hand_rounded, size: 18, color: AppColors.a3),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// Expanding sound waves while the host listens to everyone's chirps.
class _WavesPainter extends CustomPainter {
  final double t;
  _WavesPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (var i = 0; i < 4; i++) {
      final p = (t + i / 4) % 1.0;
      canvas.drawCircle(
          c,
          24 + p * size.shortestSide * 0.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 * (1 - p) + 0.5
            ..color = Color.lerp(AppColors.a3, AppColors.a1, p)!.withValues(alpha: 1 - p));
    }
  }

  @override
  bool shouldRepaint(covariant _WavesPainter old) => old.t != t;
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Chip({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface2.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(children: [
              Icon(icon, size: 18),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
          ),
        ),
      );
}

class _SyncBadge extends StatelessWidget {
  final GuestSession guest;
  const _SyncBadge({required this.guest});
  @override
  Widget build(BuildContext context) {
    final c = guest.clock;
    final ok = guest.connected && c.locked;
    final col = guest.reconnecting ? AppColors.warn : (!guest.connected ? AppColors.bad : (ok ? AppColors.good : AppColors.warn));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(color: col.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Text(guest.reconnecting ? 'Reconnecting' : (!guest.connected ? 'Offline' : (ok ? 'In sync' : 'Syncing')),
            style: TextStyle(color: col, fontWeight: FontWeight.w800, fontSize: 13)),
      ]),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  const _RoundBtn({required this.icon, required this.label, this.onTap, this.busy = false});
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null && !busy ? 0.4 : 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(40),
          onTap: onTap,
          child: SizedBox(
            width: 92,
            child: Column(children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: AppColors.surface2.withValues(alpha: 0.9), shape: BoxShape.circle),
                child: busy
                    ? const Padding(padding: EdgeInsets.all(15), child: CircularProgressIndicator(strokeWidth: 2.4))
                    : Icon(icon, size: 26),
              ),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 12, color: AppColors.dim)),
            ]),
          ),
        ),
      );
}
