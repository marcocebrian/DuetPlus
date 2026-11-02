// Music sources: YouTube Music / YouTube (search via InnerTube, audio via
// yt-dlp on Android), local files, demo track.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'native.dart';
import 'sabr.dart';
import 'session.dart';
import 'tags.dart';
import 'ytdlp.dart';

class YtResult {
  final String id, title, author, thumb;
  final Duration? duration;
  final bool music; // YouTube Music song (square art)
  YtResult(this.id, this.title, this.author, this.thumb, this.duration, {this.music = false});
}

/// Fetches audio for a video id on another phone (iPhone host -> Android guest).
typedef RemoteFetcher = Future<String> Function(String videoId, void Function(double) progress);

class YouTubeSource {
  YouTubeSource._();
  static final YouTubeSource I = YouTubeSource._();
  final YoutubeExplode _yt = YoutubeExplode();

  /// Set by the host session when an Android guest can run yt-dlp for us.
  RemoteFetcher? remote;

  bool get canFetch => true; // SABR works on every platform; fallbacks cover the rest

  // ---------------------------------------------------------------- search
  Future<List<YtResult>> searchVideos(String q) async {
    final res = await _yt.search.search(q);
    return res
        .where((v) => !v.isLive)
        .map((v) => YtResult(v.id.value, v.title, v.author, v.thumbnails.maxResUrl, v.duration))
        .toList();
  }

  /// YouTube Music "Songs" search (InnerTube WEB_REMIX client).
  Future<List<YtResult>> searchMusic(String q) async {
    final c = HttpClient();
    try {
      final req = await c.postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/search?prettyPrint=false'));
      req.headers.contentType = ContentType.json;
      req.headers.set('Origin', 'https://music.youtube.com');
      req.headers.set('User-Agent', 'Mozilla/5.0');
      req.write(jsonEncode({
        'context': {
          'client': {'clientName': 'WEB_REMIX', 'clientVersion': '1.20251027.01.00', 'hl': 'en', 'gl': 'US'}
        },
        'query': q,
        'params': 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D', // filter: songs
      }));
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw 'YouTube Music search failed (HTTP ${res.statusCode})';
      final out = <YtResult>[];
      void walk(dynamic n) {
        if (n is Map) {
          final r = n['musicResponsiveListItemRenderer'];
          if (r is Map) {
            final id = r['playlistItemData']?['videoId'] as String?;
            final cols = (r['flexColumns'] as List?) ?? const [];
            String runs(int i) => i < cols.length
                ? ((cols[i]['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?) ?? const [])
                    .map((e) => e['text']).join()
                : '';
            final thumbs = r['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
            var thumb = thumbs != null && thumbs.isNotEmpty ? thumbs.last['url'] as String : '';
            thumb = thumb.replaceAll(RegExp(r'=w\d+-h\d+'), '=w544-h544'); // big square cover
            final parts = runs(1).split(' • ');
            Duration? dur;
            final m = RegExp(r'^(\d+):(\d\d)$').firstMatch(parts.last.trim());
            if (m != null) dur = Duration(minutes: int.parse(m[1]!), seconds: int.parse(m[2]!));
            final artist = parts.length >= 2 ? parts.sublist(0, parts.length - (dur != null ? 1 : 0)).join(' • ') : runs(1);
            if (id != null) out.add(YtResult(id, runs(0), artist, thumb, dur, music: true));
            return;
          }
          n.values.forEach(walk);
        } else if (n is List) {
          n.forEach(walk);
        }
      }

      walk(jsonDecode(body));
      return out;
    } finally {
      c.close();
    }
  }

  /// Video id from a pasted YouTube / YouTube Music link (or null).
  static String? idFromLink(String s) {
    final m = RegExp(r'(?:v=|youtu\.be/|shorts/|embed/)([A-Za-z0-9_-]{11})').firstMatch(s.trim());
    return m?.group(1);
  }

  Future<YtResult> lookup(String id) async {
    final v = await _yt.videos.get(id);
    return YtResult(id, v.title, v.author, v.thumbnails.maxResUrl, v.duration);
  }

  // ---------------------------------------------------------------- audio
  /// Full audio via yt-dlp (this phone if Android, else an Android guest).
  Future<String> fetchAudio(String id, void Function(double) progress) async {
    String path;
    final cached = File(await workPath('yt_$id.webm'));
    if (cached.existsSync() && cached.lengthSync() > 0) return cached.path;
    // Per platform, the proven route first:
    //  - Android: yt-dlp (bundled), then SABR in a WebView.
    //  - iPhone:  SABR in a WebView (WebKit), then an Android guest's yt-dlp.
    final errors = <String>[];
    if (YtDlp.supported) {
      try {
        path = await YtDlp.download(id, Directory(await workPath('')), progress);
      } catch (e) {
        errors.add('yt-dlp: $e');
        try {
          return await SabrFetcher.I.fetch(id, cached.path, progress);
        } catch (e2) {
          throw 'Could not get this song. ${errors.first} · SABR: $e2';
        }
      }
    } else {
      try {
        return await SabrFetcher.I.fetch(id, cached.path, progress);
      } catch (e) {
        debugPrint('SABR failed for $id: $e');
        if (remote == null) throw 'YouTube refused this phone ($e). An Android phone in the party can fetch it instead.';
        path = await remote!(id, progress);
      }
    }
    if (path.endsWith('.webm')) return path;
    // Not Opus/WebM (e.g. m4a): convert once so every phone decodes the same stream.
    final out = '${path.substring(0, path.lastIndexOf('.'))}.duop';
    if (!File(out).existsSync()) await Duet.I.transcode(path, out, (_) {});
    return out;
  }

  QueueItem item(YtResult r) {
    final meta = TrackMeta(id: 0, title: r.title, artist: r.author, thumb: r.thumb, source: 'youtube');
    return QueueItem(meta, (p) async {
      // Artwork bytes travel with the song so guests don't need internet for it.
      // maxresdefault doesn't exist for every video: fall back to hqdefault.
      final art = _download(r.thumb).then((b) async => b ?? await _download(r.thumb.replaceAll('maxresdefault', 'hqdefault')));
      final path = await fetchAudio(r.id, p);
      meta.art ??= await art;
      return path;
    });
  }
}

Future<Uint8List?> _download(String url) async {
  if (url.isEmpty) return null;
  final c = HttpClient();
  try {
    final res = await (await c.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final bb = BytesBuilder(copy: false);
    await for (final d in res) {
      bb.add(d);
    }
    final b = bb.takeBytes();
    return b.length < 1500 * 1024 ? b : null;
  } catch (_) {
    return null;
  } finally {
    c.close();
  }
}

/// Formats every phone decodes bit-identically with the shared core.
const _direct = {'mp3', 'flac', 'wav', 'webm'};

QueueItem fileItem(String path, String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  final meta = TrackMeta(
      id: 0,
      title: dot > 0 ? name.substring(0, dot) : name,
      artist: 'From ${Platform.isIOS ? 'Files' : 'phone storage'} · ${ext.toUpperCase()}',
      source: 'file');
  return QueueItem(meta, (p) async {
    final tags = await readTags(path);
    if (tags.title != null) meta.title = tags.title!;
    if (tags.artist != null) meta.artist = tags.album != null ? '${tags.artist} · ${tags.album}' : tags.artist!;
    if (tags.art != null && tags.art!.length < 1500 * 1024) meta.art = tags.art;
    if (_direct.contains(ext)) return path;
    // AAC/M4A/ALAC/OGG/…: platform decoders differ (e.g. AAC priming), so the
    // host transcodes once to Opus and every phone decodes the same stream.
    final out = await workPath('local_${path.hashCode.toRadixString(16)}.duop');
    if (File(out).existsSync() && File(out).lengthSync() > 64) return out;
    await Duet.I.transcode(path, out, p);
    return out;
  });
}

QueueItem demoItem() => QueueItem(
      TrackMeta(id: 0, title: 'Sync Test Beat', artist: 'DuetPlus demo · 120 BPM', source: 'demo'),
      (_) async {
        final path = await workPath('demo.webm');
        final data = await rootBundle.load('assets/demo.webm');
        await File(path).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        return path;
      },
    );
