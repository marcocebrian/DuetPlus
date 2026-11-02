import 'package:flutter/material.dart';

import '../core/session.dart';
import 'theme.dart';

void showDevicesSheet(BuildContext context, HostSession host, {String title = 'Devices'}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.8,
      child: ListenableBuilder(listenable: host, builder: (_, __) => _DevicesSheet(host: host, title: title)),
    ),
  );
}

class _DevicesSheet extends StatelessWidget {
  final HostSession host;
  final String title;
  const _DevicesSheet({required this.host, required this.title});

  @override
  Widget build(BuildContext context) {
    final engine = duet.engineStats();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
            'Join with this IP: ${host.ip ?? "?"}  ·  ${host.peers.length + 1} device(s)\n'
            'Playout err = how far each phone\'s audio is from where it should be (from hardware timestamps). '
            'Acoustic = measured with this phone\'s mic (Sync check).',
            style: const TextStyle(color: AppColors.dim, fontSize: 12.5, height: 1.35)),
        if (host.checkReport.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              host.checking
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.hearing_rounded, color: AppColors.a3),
              const SizedBox(width: 10),
              Expanded(child: Text(host.checkReport, style: const TextStyle(fontSize: 13, height: 1.4))),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: ListView(children: [
            _row(
              name: '${host.deviceName} (host)',
              platform: host.isHost ? 'host' : '',
              lines: [
                ('Clock', 'master'),
                ('Out latency', '${engine.outLatencyMs.toStringAsFixed(1)} ms'),
                ('Rate', '${engine.deviceRate.toStringAsFixed(0)} Hz'),
              ],
              status: host.micOk ? 'Reference' : 'Reference (no mic)',
              statusColor: AppColors.a3,
            ),
            for (final p in host.peers) _peerRow(p),
            if (host.peers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No guests yet. Open DuetPlus on another phone → Join a party.',
                    textAlign: TextAlign.center, style: TextStyle(color: AppColors.dim)),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _peerRow(Peer p) {
    final st = p.stats;
    double d(String k) => (st[k] as num?)?.toDouble() ?? 0;
    final err = d('err') / 1000;
    final ready = host.track != null && p.readyTrack == host.track!.id;
    String status;
    Color col;
    if (!p.locked) {
      status = 'Syncing clock';
      col = AppColors.warn;
    } else if (host.track != null && !ready) {
      status = 'Loading ${(p.dl * 100).round()}%';
      col = AppColors.warn;
    } else {
      status = err.abs() < 1 ? 'In sync' : 'Converging';
      col = err.abs() < 1 ? AppColors.good : AppColors.warn;
    }
    return _row(
      name: p.name,
      platform: p.platform,
      lines: [
        ('RTT', '${d('rtt').toStringAsFixed(1)} ms'),
        ('Playout err', '${err.toStringAsFixed(2)} ms'),
        ('Drift', '${d('skew').toStringAsFixed(1)} ppm'),
        ('Out latency', '${d('lat').toStringAsFixed(1)} ms'),
        ('Acoustic fix', '${(p.fixNs / 1e6).toStringAsFixed(2)} ms'),
        ('Acoustic', p.residualMs == null ? '—' : '${p.residualMs! >= 0 ? '+' : ''}${p.residualMs!.toStringAsFixed(2)} ms'),
      ],
      status: status,
      statusColor: col,
    );
  }

  Widget _row({
    required String name,
    required String platform,
    required List<(String, String)> lines,
    required String status,
    required Color statusColor,
  }) {
    final icon = platform == 'ios' ? Icons.phone_iphone_rounded : (platform == 'android' ? Icons.phone_android_rounded : Icons.podcasts_rounded);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: AppColors.a3),
          const SizedBox(width: 10),
          Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
            child: Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.w700, fontSize: 12)),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 16, runSpacing: 6, children: [
          for (final (k, v) in lines)
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k.toUpperCase(), style: const TextStyle(fontSize: 9.5, letterSpacing: 0.8, color: AppColors.dim)),
              Text(v, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
        ]),
      ]),
    );
  }
}
