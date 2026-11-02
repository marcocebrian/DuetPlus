// Minimal tag reader: title, artist and embedded cover art from
// MP3 (ID3v2), M4A/MP4 (ilst) and FLAC (Vorbis comments + PICTURE).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Tags {
  String? title, artist, album;
  Uint8List? art;
  bool get isEmpty => title == null && artist == null && art == null;
}

Future<Tags> readTags(String path) async {
  final t = Tags();
  try {
    final f = await File(path).open();
    final len = await f.length();
    // Tags live at the start (ID3, FLAC) or in moov (MP4, usually < 8 MB).
    final head = await f.read(len < 8 * 1024 * 1024 ? len : 8 * 1024 * 1024);
    await f.close();
    if (head.length > 10 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
      _id3(head, t);
    } else if (head.length > 4 && head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
      _flac(head, t);
    } else if (head.length > 8 && String.fromCharCodes(head.sublist(4, 8)) == 'ftyp') {
      _mp4(head, 0, head.length, t);
    }
  } catch (_) {}
  return t;
}

// ------------------------------------------------------------------ ID3v2
void _id3(Uint8List b, Tags t) {
  final ver = b[3];
  final size = _syncsafe(b, 6);
  var p = 10;
  if (b[5] & 0x40 != 0) p += ver == 4 ? _syncsafe(b, 10) : _u32(b, 10) + 4; // extended header
  final end = (10 + size).clamp(0, b.length);
  while (p + 10 <= end) {
    final id = String.fromCharCodes(b.sublist(p, p + 4));
    if (id.codeUnits.every((c) => c == 0)) break;
    final fs = ver == 4 ? _syncsafe(b, p + 4) : _u32(b, p + 4);
    final d = p + 10;
    if (fs <= 0 || d + fs > b.length) break;
    final data = Uint8List.sublistView(b, d, d + fs);
    if (id == 'TIT2') t.title ??= _id3Text(data);
    if (id == 'TPE1') t.artist ??= _id3Text(data);
    if (id == 'TALB') t.album ??= _id3Text(data);
    if (id == 'APIC' && t.art == null) t.art = _apic(data);
    p = d + fs;
  }
}

String? _id3Text(Uint8List d) {
  if (d.isEmpty) return null;
  final enc = d[0];
  final body = d.sublist(1);
  String s;
  if (enc == 1 || enc == 2) {
    s = _utf16(body, bigEndianDefault: enc == 2);
  } else if (enc == 3) {
    s = utf8.decode(body, allowMalformed: true);
  } else {
    s = latin1.decode(body);
  }
  s = s.replaceAll('\u0000', ' ').trim();
  return s.isEmpty ? null : s;
}

Uint8List? _apic(Uint8List d) {
  final enc = d[0];
  var p = 1;
  while (p < d.length && d[p] != 0) {
    p++; // mime
  }
  p += 2; // NUL + picture type
  // description (NUL-terminated, 2 NULs for UTF-16)
  if (enc == 1 || enc == 2) {
    while (p + 1 < d.length && !(d[p] == 0 && d[p + 1] == 0)) {
      p += 2;
    }
    p += 2;
  } else {
    while (p < d.length && d[p] != 0) {
      p++;
    }
    p += 1;
  }
  return p < d.length ? Uint8List.fromList(d.sublist(p)) : null;
}

String _utf16(Uint8List b, {bool bigEndianDefault = false}) {
  var be = bigEndianDefault, i = 0;
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
    be = false;
    i = 2;
  } else if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
    be = true;
    i = 2;
  }
  final units = <int>[];
  for (; i + 1 < b.length; i += 2) {
    units.add(be ? (b[i] << 8 | b[i + 1]) : (b[i + 1] << 8 | b[i]));
  }
  return String.fromCharCodes(units);
}

int _syncsafe(Uint8List b, int o) => (b[o] & 0x7f) << 21 | (b[o + 1] & 0x7f) << 14 | (b[o + 2] & 0x7f) << 7 | (b[o + 3] & 0x7f);
int _u32(Uint8List b, int o) => b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

// ------------------------------------------------------------------ FLAC
void _flac(Uint8List b, Tags t) {
  var p = 4;
  while (p + 4 <= b.length) {
    final last = b[p] & 0x80 != 0;
    final type = b[p] & 0x7f;
    final len = b[p + 1] << 16 | b[p + 2] << 8 | b[p + 3];
    final d = p + 4;
    if (d + len > b.length) break;
    final blk = ByteData.sublistView(b, d, d + len);
    if (type == 4) {
      // Vorbis comments (little-endian lengths)
      var q = 0;
      final vlen = blk.getUint32(q, Endian.little);
      q += 4 + vlen;
      final n = blk.getUint32(q, Endian.little);
      q += 4;
      for (var i = 0; i < n && q + 4 <= len; i++) {
        final l = blk.getUint32(q, Endian.little);
        q += 4;
        final s = utf8.decode(b.sublist(d + q, d + q + l), allowMalformed: true);
        q += l;
        final k = s.indexOf('=');
        if (k < 0) continue;
        final key = s.substring(0, k).toUpperCase(), v = s.substring(k + 1).trim();
        if (key == 'TITLE') t.title ??= v;
        if (key == 'ARTIST') t.artist ??= v;
        if (key == 'ALBUM') t.album ??= v;
      }
    } else if (type == 6 && t.art == null) {
      var q = 4;
      final ml = blk.getUint32(q);
      q += 4 + ml;
      final dl = blk.getUint32(q);
      q += 4 + dl + 16;
      final pl = blk.getUint32(q);
      q += 4;
      if (q + pl <= len) t.art = Uint8List.fromList(b.sublist(d + q, d + q + pl));
    }
    p = d + len;
    if (last) break;
  }
}

// ------------------------------------------------------------------ MP4
void _mp4(Uint8List b, int start, int end, Tags t) {
  var p = start;
  while (p + 8 <= end) {
    var size = _u32(b, p);
    final type = String.fromCharCodes(b.sublist(p + 4, p + 8));
    var hdr = 8;
    if (size == 1 && p + 16 <= end) {
      size = _u32(b, p + 12); // 64-bit size (low word is enough here)
      hdr = 16;
    } else if (size == 0) {
      size = end - p;
    }
    if (size < hdr || p + size > end) break;
    final cs = p + hdr, ce = p + size;
    switch (type) {
      case 'moov':
      case 'udta':
      case 'ilst':
        _mp4(b, cs, ce, t);
        break;
      case 'meta':
        _mp4(b, cs + 4, ce, t); // full box: skip version/flags
        break;
      case '©nam':
      case '©ART':
      case '©alb':
      case 'aART':
      case 'covr':
        final v = _mp4Data(b, cs, ce);
        if (v != null) {
          if (type == 'covr') {
            t.art ??= v;
          } else {
            final s = utf8.decode(v, allowMalformed: true).trim();
            if (type == '©nam') t.title ??= s;
            if (type == '©ART' || type == 'aART') t.artist ??= s;
            if (type == '©alb') t.album ??= s;
          }
        }
        break;
    }
    p += size;
  }
}

Uint8List? _mp4Data(Uint8List b, int s, int e) {
  // child 'data' box: size, 'data', type(4), locale(4), payload
  if (s + 16 > e) return null;
  final size = _u32(b, s);
  if (String.fromCharCodes(b.sublist(s + 4, s + 8)) != 'data' || s + size > e) return null;
  return Uint8List.fromList(b.sublist(s + 16, s + size));
}
