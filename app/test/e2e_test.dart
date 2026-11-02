// Cross-process end-to-end test on macOS with the desktop core (null audio
// backend). Run via tool/e2e.sh: one host process + guests over localhost.
import 'dart:convert';
import 'dart:io';

import 'package:duetplus/core/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

const role = String.fromEnvironment('ROLE');
const out = '/tmp/duettest/e2e';

Future<void> waitFor(bool Function() c, String what, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!c()) {
    if (DateTime.now().isAfter(end)) throw 'timeout waiting for $what';
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

/// Logs (masterNs, frame) playheads every 20 ms while [run] executes.
Future<List<List<num>>> record(Future<void> Function() run) async {
  final log = <List<num>>[];
  var going = true;
  () async {
    while (going) {
      final (m, f) = duet.playhead();
      log.add([m, f]);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }();
  await run();
  going = false;
  return log;
}

void main() {
  setUpAll(() {
    PathProviderPlatform.instance = _Paths('$out/$role');
    Directory('$out/$role').createSync(recursive: true);
  });

  test('e2e $role', () async {
    if (role == 'host') {
      final h = HostSession();
      final toasts = <String>[];
      h.events.listen(toasts.add);
      await h.start('E2E host', mic: false);
      await waitFor(() => h.peers.isNotEmpty && h.peers.first.locked, 'guest clock lock');
      final events = <String>[];

      final log = await record(() async {
        h.enqueue(QueueItem(
            TrackMeta(id: 0, title: 'demo', artist: 'e2e', source: 'demo'), (_) async => '/tmp/duettest/demo.webm'));
        await waitFor(() => h.sched.playing && !h.busy, 'playing');
        events.add('play ${duet.masterNow()}');
        await Future.delayed(const Duration(seconds: 3));
        h.pause();
        events.add('pause ${duet.masterNow()}');
        await Future.delayed(const Duration(seconds: 2));
        h.resume();
        events.add('resume ${duet.masterNow()}');
        await Future.delayed(const Duration(seconds: 3));
        h.seek(40);
        events.add('seek ${duet.masterNow()}');
        await Future.delayed(const Duration(seconds: 3));
        // late guest joins around here (started by the script)
        await waitFor(() => h.peers.length >= 2, 'late guest', seconds: 40);
        await waitFor(() => h.peers.every((p) => p.readyTrack == h.track!.id), 'late guest ready');
        await Future.delayed(const Duration(seconds: 5));
      });
      File('$out/host.json').writeAsStringSync(jsonEncode({'log': log, 'events': events, 'toasts': toasts}));
      await h.close();
    } else {
      final g = GuestSession(['127.0.0.1']);
      await g.connect('E2E $role');
      final log = await record(() async {
        if (role == 'guest') {
          await Future.delayed(const Duration(seconds: 16));
          g.debugDropConnection(); // Wi-Fi blip: must reconnect without re-downloading
          await Future.delayed(const Duration(seconds: 9));
        } else {
          await Future.delayed(const Duration(seconds: 12));
        }
      });
      File('$out/$role.json').writeAsStringSync(jsonEncode({'log': log, 'fix': duet.latencyFixNs}));
      await g.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
