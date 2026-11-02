import 'dart:io';

import 'package:duetplus/core/tags.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cover = File('/tmp/duettest/cover.jpg').lengthSync();
  for (final ext in ['mp3', 'm4a', 'flac']) {
    test('tags $ext', () async {
      final t = await readTags('/tmp/duettest/tagged.$ext');
      expect(t.title, 'Night Drive');
      expect(t.artist, 'DuetPlus Band');
      expect(t.album, 'Demo LP');
      expect(t.art, isNotNull);
      expect(t.art!.sublist(0, 2), [0xFF, 0xD8], reason: 'JPEG magic');
      expect((t.art!.length - cover).abs() < 64, true, reason: 'art ${t.art!.length} vs cover $cover');
    });
  }
}
