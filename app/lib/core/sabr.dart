// YouTube audio over SABR (googlevideo) in a hidden WebView — works on iOS
// and Android. The JS side is assets/sabr.bundle.js (web_sabr/sabr_entry.ts).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class _Req {
  final IOSink sink;
  final String path;
  final void Function(double) progress;
  final done = Completer<String>();
  int size = 0, got = 0;
  DateTime last = DateTime.now();
  _Req(this.sink, this.path, this.progress);
}

class SabrFetcher {
  SabrFetcher._();
  static final SabrFetcher I = SabrFetcher._();

  HeadlessInAppWebView? _view;
  InAppWebViewController? _ctl;
  Completer<void>? _ready;
  final Map<int, _Req> _reqs = {};
  int _seq = 0;
  String? lastError;

  // The user agent must agree with the real engine and platform (BotGuard
  // cross-checks them): WebKit on iOS says Safari; Android's Chromium WebView
  // says desktop Chrome on Linux ARM with its real Chrome version (a desktop UA
  // so youtube.com serves the desktop page that carries the challenge).
  static Future<String> _userAgent() async {
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
    }
    var chrome = '140.0.0.0';
    try {
      final def = await InAppWebViewController.getDefaultUserAgent();
      chrome = RegExp(r'Chrome/([\d.]+)').firstMatch(def)?.group(1) ?? chrome;
    } catch (_) {}
    return 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$chrome Safari/537.36';
  }

  Future<void> _start() async {
    if (_ready != null) return _ready!.future;
    final ready = _ready = Completer<void>();
    final ua = await _userAgent();
    _view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('https://www.youtube.com/robots.txt')),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        userAgent: ua,
        mediaPlaybackRequiresUserGesture: false,
        cacheEnabled: true,
      ),
      onWebViewCreated: (c) {
        _ctl = c;
        c.addJavaScriptHandler(handlerName: 'duet', callback: _onEmit);
      },
      onLoadStop: (c, url) async {
        if (ready.isCompleted) return;
        try {
          await c.evaluateJavascript(
              source: "window.duetEmit = (e, r, p) => window.flutter_inappwebview.callHandler('duet', e, r, p);");
          final js = await rootBundle.loadString('assets/sabr.bundle.js');
          await c.evaluateJavascript(source: js);
          final ok = await c.evaluateJavascript(source: 'window.duetReady === true');
          if (ok != true) throw 'SABR bundle did not initialise';
          ready.complete();
        } catch (e) {
          ready.completeError(e);
        }
      },
      onReceivedError: (c, req, err) {
        if (req.isForMainFrame == true && !ready.isCompleted) ready.completeError('WebView: ${err.description}');
      },
    );
    _view!.run();
    return ready.future.timeout(const Duration(seconds: 20), onTimeout: () {
      _ready = null;
      throw 'WebView did not load';
    });
  }

  dynamic _onEmit(List<dynamic> a) {
    if (a.length < 2) return null;
    final ev = a[0] as String, id = (a[1] as num).toInt();
    if (ev == 'log') {
      debugPrint('SABR js: ${a.length > 2 ? a[2] : ''}');
      return null;
    }
    final r = _reqs[id];
    if (r == null) return null;
    final payload = a.length > 2 ? a[2] : null;
    r.last = DateTime.now();
    switch (ev) {
      case 'begin':
        r.size = ((payload as Map)['size'] as num?)?.toInt() ?? 0;
        break;
      case 'chunk':
        final b = base64Decode(payload as String);
        r.sink.add(b);
        r.got += b.length;
        if (r.size > 0) r.progress(r.got / r.size);
        break;
      case 'end':
        _finish(id, null);
        break;
      case 'error':
        _finish(id, '$payload');
        break;
    }
    return null;
  }

  Future<void> _finish(int id, String? error) async {
    final r = _reqs.remove(id);
    if (r == null) return;
    await r.sink.close();
    if (error == null && r.size > 0 && r.got < r.size) error = 'stream ended early (${r.got}/${r.size} bytes)';
    if (error != null) {
      lastError = error;
      try {
        File(r.path).deleteSync();
      } catch (_) {}
      r.done.completeError(error);
    } else {
      r.done.complete(r.path);
    }
  }

  /// Downloads the Opus/WebM audio of [videoId] into [path].
  /// Fails fast if no bytes arrive for 15 s (YouTube cuts unverified
  /// clients after ~1 MB).
  Future<String> fetch(String videoId, String path, void Function(double) progress) async {
    await _start();
    final id = ++_seq;
    final r = _Req(File(path).openWrite(), path, progress);
    _reqs[id] = r;
    await _ctl!.evaluateJavascript(source: 'window.duetFetchAudio(${jsonEncode(videoId)}, $id);');
    final watchdog = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!_reqs.containsKey(id)) return t.cancel();
      if (DateTime.now().difference(r.last).inSeconds > 15) {
        t.cancel();
        _finish(id, r.got > 0 ? 'YouTube stopped after ${(r.got / 1e6).toStringAsFixed(1)} MB (token refused)' : 'no response');
        _ctl?.evaluateJavascript(source: 'void 0'); // keep the view alive
      }
    });
    try {
      return await r.done.future;
    } finally {
      watchdog.cancel();
      debugPrint('SABR $videoId: ${r.got} bytes${lastError != null ? ' ($lastError)' : ''}');
    }
  }
}
