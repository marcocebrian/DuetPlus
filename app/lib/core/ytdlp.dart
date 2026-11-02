// Dart side of the Android yt-dlp bridge (see MainActivity.kt).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class YtDlp {
  YtDlp._();
  static const _ch = MethodChannel('duet/ytdlp');
  static final _progress = <String, void Function(double)>{};
  static Future<String?>? _init;
  static String? version;
  static String? lastError;

  /// yt-dlp runs on Android only (Python + QuickJS bundled in the APK).
  static bool get supported => Platform.isAndroid;

  static Future<String?> init() => _init ??= () async {
        _ch.setMethodCallHandler((c) async {
          if (c.method == 'progress') {
            final m = c.arguments as Map;
            _progress[m['id'] as String]?.call((m['p'] as num).toDouble().clamp(0.0, 1.0));
          }
        });
        try {
          version = await _ch.invokeMethod<String>('init');
        } on PlatformException catch (e) {
          lastError = 'yt-dlp could not start: ${e.message}';
          _init = null;
          throw lastError!;
        } catch (e) {
          lastError = '$e';
          _init = null;
          rethrow;
        }
        return version;
      }();

  /// Keeps yt-dlp current (YouTube changes often). At most once a day.
  static Future<void> updateInBackground() async {
    if (!supported) return;
    try {
      final stamp = File('${(await getApplicationSupportDirectory()).path}/ytdlp_updated');
      if (stamp.existsSync() && DateTime.now().difference(stamp.lastModifiedSync()).inHours < 20) {
        await init();
        return;
      }
      await init();
      final r = await _ch.invokeMethod<String>('update');
      final v = r?.split(':').last;
      if (v != null && v.isNotEmpty && v != 'null') version = v;
      stamp.parent.createSync(recursive: true);
      stamp.writeAsStringSync(r ?? '');
      debugPrint('yt-dlp update: $r');
    } catch (e) {
      debugPrint('yt-dlp update failed: $e');
    }
  }

  /// Downloads the best audio for a YouTube / YouTube Music video id.
  static Future<String> download(String videoId, Directory dir, void Function(double) progress) async {
    for (final ext in ['webm', 'm4a', 'opus']) {
      final f = File('${dir.path}/yt_$videoId.$ext');
      if (f.existsSync() && f.lengthSync() > 0) return f.path;
    }
    await init();
    _progress[videoId] = progress;
    try {
      final path = await _ch.invokeMethod<String>('download', {
        'url': 'https://www.youtube.com/watch?v=$videoId',
        'dir': dir.path,
        'name': 'yt_$videoId',
        'id': videoId,
      });
      if (path == null) throw 'yt-dlp returned nothing';
      return path;
    } on PlatformException catch (e) {
      final all = e.message ?? '';
      final err = all.split('\n').where((l) => l.contains('ERROR')).join(' ').trim();
      throw err.isNotEmpty ? err : 'yt-dlp failed: ${all.length > 400 ? all.substring(0, 400) : all}';
    } finally {
      _progress.remove(videoId);
    }
  }
}
