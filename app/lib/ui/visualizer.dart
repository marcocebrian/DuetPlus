import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/session.dart';
import 'theme.dart';

/// Pulls the spectrum of what *this* phone is outputting (from the C++ engine)
/// every frame. Since every phone plays the same samples at the same time,
/// visuals and beat bursts are in sync across phones too.
class SpectrumModel extends ChangeNotifier {
  static const bands = 40;
  final Float32List levels = Float32List(bands);
  double bass = 0, energy = 0, phase = 0, beat = 0; // beat: 1 on onset, decays
  double _fluxAvg = 0.02, _sinceBeat = 1;
  final Float32List _prev = Float32List(bands);
  int beats = 0; // increments on each detected onset
  List<Color> palette = const [AppColors.a1, AppColors.a2, AppColors.a3];
  final particles = ParticleSystem();

  void tick(double dt, {required bool playing}) {
    dt = dt.clamp(0.0, 0.05);
    final s = duet.spectrum(bands);
    double e = 0;
    for (var i = 0; i < bands; i++) {
      final v = s[i];
      final cur = levels[i];
      levels[i] = v > cur ? cur + (v - cur) * 0.6 : cur + (v - cur) * 0.12;
      e += levels[i];
    }
    final b = (s[0] + s[1] + s[2] + s[3] + s[4]) / 5;
    bass = b > bass ? bass + (b - bass) * 0.5 : bass + (b - bass) * 0.1;
    energy = e / bands;
    phase += dt * (0.05 + energy * 0.5);
    // Onset detection: spectral flux (sudden rises) in the low/mid bands,
    // compared with its own running average.
    double flux = 0;
    for (var i = 0; i < 14; i++) {
      final d = s[i] - _prev[i];
      if (d > 0) flux += d * (i < 6 ? 1.5 : 1.0);
      _prev[i] = s[i];
    }
    for (var i = 14; i < bands; i++) {
      _prev[i] = s[i];
    }
    _sinceBeat += dt;
    if (flux > _fluxAvg * 2.2 + 0.25 && _sinceBeat > 0.18) {
      _sinceBeat = 0;
      beat = 1;
      beats++;
      particles.burst(palette, strength: math.min(1.0, flux / (_fluxAvg * 4 + 0.5)));
    }
    _fluxAvg += (flux - _fluxAvg) * math.min(1.0, dt * 3);
    beat = math.max(0, beat - dt * 3.5);
    particles.step(dt, energy: playing ? energy : 0, palette: palette);
    notifyListeners();
  }
}

class _P {
  double x, y, vx, vy, size, life, maxLife;
  Color color;
  _P(this.x, this.y, this.vx, this.vy, this.size, this.life, this.color) : maxLife = life;
}

/// Ambient "dust" drifting up (normalized coords) + radial bursts on beats
/// (polar coords around the artwork, in units of the artwork radius).
class ParticleSystem {
  final _rnd = math.Random(7);
  final List<_P> ambient = [];
  final List<_P> bursts = [];

  ParticleSystem() {
    for (var i = 0; i < 60; i++) {
      ambient.add(_spawnAmbient(const [AppColors.a1, AppColors.a2, AppColors.a3], randomY: true));
    }
  }

  _P _spawnAmbient(List<Color> pal, {bool randomY = false}) => _P(
        _rnd.nextDouble(),
        randomY ? _rnd.nextDouble() : 1.05,
        (_rnd.nextDouble() - 0.5) * 0.01,
        -(0.01 + _rnd.nextDouble() * 0.03),
        0.8 + _rnd.nextDouble() * 2.6,
        1,
        pal[_rnd.nextInt(pal.length)],
      );

  void burst(List<Color> pal, {required double strength}) {
    final n = (10 + strength * 22).round();
    for (var i = 0; i < n; i++) {
      final a = _rnd.nextDouble() * 2 * math.pi;
      final sp = 0.5 + _rnd.nextDouble() * 1.4 * (0.6 + strength);
      bursts.add(_P(a, 1.05, sp, 0, 1.5 + _rnd.nextDouble() * 3, 0.7 + _rnd.nextDouble() * 0.8, pal[_rnd.nextInt(pal.length)]));
    }
    if (bursts.length > 400) bursts.removeRange(0, bursts.length - 400);
  }

  void step(double dt, {required double energy, required List<Color> palette}) {
    final speed = 1 + energy * 6;
    for (var i = 0; i < ambient.length; i++) {
      final p = ambient[i];
      p.x += p.vx * dt * speed;
      p.y += p.vy * dt * speed;
      if (p.y < -0.05 || p.x < -0.05 || p.x > 1.05) ambient[i] = _spawnAmbient(palette);
    }
    for (final p in bursts) {
      p.y += p.vx * dt; // radius grows (x = angle, y = radius, vx = radial speed)
      p.vx *= math.pow(0.35, dt).toDouble();
      p.life -= dt;
    }
    bursts.removeWhere((p) => p.life <= 0);
  }
}

class AmbientPainter extends CustomPainter {
  final SpectrumModel m;
  AmbientPainter(this.m) : super(repaint: m);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    for (final p in m.particles.ambient) {
      final tw = 0.5 + 0.5 * math.sin(m.phase * 6 + p.size * 10 + p.x * 20);
      paint.color = p.color.withValues(alpha: (0.15 + 0.35 * tw) * (0.6 + m.energy));
      canvas.drawCircle(Offset(p.x * size.width, p.y * size.height), p.size * (1 + m.bass * 0.6), paint);
    }
  }

  @override
  bool shouldRepaint(covariant AmbientPainter old) => false;
}

class BarsPainter extends CustomPainter {
  final SpectrumModel m;
  BarsPainter(this.m) : super(repaint: m);

  @override
  void paint(Canvas canvas, Size size) {
    const n = SpectrumModel.bands;
    const gap = 3.0;
    final w = (size.width - gap * (n - 1)) / n;
    final mid = size.height / 2;
    final p = Paint()..shader = LinearGradient(colors: m.palette).createShader(Offset.zero & size);
    final glow = Paint()
      ..shader = LinearGradient(colors: m.palette.map((c) => c.withValues(alpha: 0.35)).toList()).createShader(Offset.zero & size)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    for (var i = 0; i < n; i++) {
      final v = math.max(0.03, m.levels[i]);
      final h = v * size.height * 0.5;
      final x = i * (w + gap);
      final r = RRect.fromRectAndRadius(Rect.fromLTRB(x, mid - h, x + w, mid + h), Radius.circular(w / 2));
      if (v > 0.25) canvas.drawRRect(r, glow);
      canvas.drawRRect(r, p);
    }
  }

  @override
  bool shouldRepaint(covariant BarsPainter old) => false;
}

/// Glow, rotating ring, symmetric spectrum spikes and beat bursts around the art.
class GlowPainter extends CustomPainter {
  final SpectrumModel m;
  final double artRadius;
  GlowPainter(this.m, this.artRadius) : super(repaint: m);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = artRadius * (1.0 + m.bass * 0.06 + m.beat * 0.04);
    final pal = m.palette;
    // Bloom
    canvas.drawCircle(
        c,
        r * 1.7,
        Paint()
          ..shader = RadialGradient(colors: [
            pal[1].withValues(alpha: 0.30 + m.bass * 0.35 + m.beat * 0.2),
            pal[0].withValues(alpha: 0.10 + m.bass * 0.15),
            Colors.transparent
          ], stops: const [0.45, 0.7, 1]).createShader(Rect.fromCircle(center: c, radius: r * 1.7)));
    // Rotating gradient ring
    canvas.drawCircle(
        c,
        r * 1.04,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 + m.bass * 5
          ..shader = SweepGradient(
            colors: [pal[0], pal[1], pal[2], pal[0]],
            transform: GradientRotation(m.phase * 2 * math.pi),
          ).createShader(Rect.fromCircle(center: c, radius: r)));
    // Spectrum spikes, mirrored left/right so it looks balanced.
    const n = SpectrumModel.bands;
    final spikes = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    const count = 96;
    for (var k = 0; k < count; k++) {
      final half = k < count / 2 ? k : count - 1 - k;
      final band = (half / (count / 2) * (n - 1)).round();
      final a = -math.pi / 2 + k / count * 2 * math.pi;
      final v = m.levels[band];
      final r0 = r * 1.10;
      final r1 = r0 + 4 + v * artRadius * 0.38;
      spikes.color = Color.lerp(pal[2], pal[0], band / n)!.withValues(alpha: 0.25 + v * 0.7);
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * r0, c + d * r1, spikes);
    }
    // Beat bursts
    final bp = Paint();
    for (final p in m.particles.bursts) {
      final t = (p.life / p.maxLife).clamp(0.0, 1.0);
      final d = Offset(math.cos(p.x), math.sin(p.x));
      bp.color = p.color.withValues(alpha: t * 0.9);
      canvas.drawCircle(c + d * (artRadius * p.y), p.size * (0.4 + t * 0.6), bp);
    }
  }

  @override
  bool shouldRepaint(covariant GlowPainter old) => old.artRadius != artRadius;
}

/// Picks 3 vivid colors from an image (for backdrop, ring and particles).
Future<List<Color>?> extractPalette(ImageProvider provider) async {
  try {
    final stream = provider.resolve(const ImageConfiguration(size: Size(64, 64)));
    final completer = Future<ui.Image>(() async {
      final c = _ImgCompleter();
      final l = ImageStreamListener((info, _) => c.done(info.image), onError: (e, _) => c.fail(e));
      stream.addListener(l);
      try {
        return await c.future.timeout(const Duration(seconds: 8));
      } finally {
        stream.removeListener(l);
      }
    });
    final img = await completer;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final w = img.width, h = img.height;
    final buckets = <int, List<double>>{}; // hue bucket -> [score, r, g, b, n]
    final step = math.max(1, (w * h / 2500).floor());
    for (var i = 0; i < w * h; i += step) {
      final r = data.getUint8(i * 4), g = data.getUint8(i * 4 + 1), b = data.getUint8(i * 4 + 2);
      final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
      if (hsv.saturation < 0.25 || hsv.value < 0.25) continue;
      final k = (hsv.hue / 30).floor();
      final e = buckets.putIfAbsent(k, () => [0, 0, 0, 0, 0]);
      e[0] += hsv.saturation * hsv.value;
      e[1] += r;
      e[2] += g;
      e[3] += b;
      e[4] += 1;
    }
    if (buckets.isEmpty) return null;
    final top = buckets.values.toList()..sort((a, b) => b[0].compareTo(a[0]));
    final cols = top.take(3).map((e) {
      final c = Color.fromARGB(255, (e[1] / e[4]).round(), (e[2] / e[4]).round(), (e[3] / e[4]).round());
      final hsv = HSVColor.fromColor(c);
      return hsv.withSaturation(math.max(hsv.saturation, 0.6)).withValue(math.max(hsv.value, 0.85)).toColor();
    }).toList();
    while (cols.length < 3) {
      final hsv = HSVColor.fromColor(cols.last);
      cols.add(hsv.withHue((hsv.hue + 40) % 360).toColor());
    }
    return cols;
  } catch (_) {
    return null;
  }
}

class _ImgCompleter {
  final _c = <void Function(ui.Image)>[];
  ui.Image? _img;
  Object? _err;
  void done(ui.Image i) {
    _img ??= i;
    for (final f in _c) {
      f(i);
    }
  }

  void fail(Object e) => _err = e;
  Future<ui.Image> get future async {
    while (_img == null) {
      if (_err != null) throw _err!;
      await Future.delayed(const Duration(milliseconds: 30));
    }
    return _img!;
  }
}

/// Deterministic palette from a string (local files without artwork).
List<Color> paletteFromSeed(String s) {
  final h = s.codeUnits.fold<int>(17, (a, b) => (a * 31 + b) & 0x7fffffff);
  final base = (h % 360).toDouble();
  return [
    HSVColor.fromAHSV(1, base, 0.75, 1).toColor(),
    HSVColor.fromAHSV(1, (base + 45) % 360, 0.7, 0.95).toColor(),
    HSVColor.fromAHSV(1, (base + 100) % 360, 0.65, 1).toColor(),
  ];
}
