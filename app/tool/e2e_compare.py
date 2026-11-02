#!/usr/bin/env python3
"""Compare guest playheads with the host's: how far apart is the audio?"""
import bisect, json, os, statistics as st, sys
D = '/tmp/duettest/e2e'
host = json.load(open(f'{D}/host.json'))
H = sorted((m, f) for m, f in host['log'] if f >= 0)
Hm = [m for m, _ in H]
ev = {e.split()[0]: int(e.split()[1]) for e in host['events']}
toasts = host.get('toasts', [])
print('host events:', toasts)
ok_peers = any('reconnected' in t for t in toasts) and sum('joined' in t for t in toasts) == 2
print('host events (s from play):', {k: round((v - ev['play']) / 1e9, 2) for k, v in ev.items()})
ok = ok_peers
for role in ['guest', 'late']:
    p = f'{D}/{role}.json'
    if not os.path.exists(p):
        print(role, 'MISSING'); ok = False; continue
    G = [(m, f) for m, f in json.load(open(p))['log'] if f >= 0]
    diffs = []
    for m, f in G:
        i = bisect.bisect_left(Hm, m)
        if i == 0 or i >= len(H): continue
        (m1, f1), (m2, f2) = H[i - 1], H[i]
        if m2 - m1 > 40e6: continue  # host silent/transition in between
        if abs((f2 - f1) - (m2 - m1) * 48000 / 1e9) > 48 * 2: continue  # seek between samples
        pred = f1 + (m - m1) * 48000 / 1e9
        diffs.append((f - pred) / 48.0)
    if not diffs:
        print(role, 'no overlapping playback'); ok = False; continue
    a = sorted(abs(d) for d in diffs)
    p95 = a[int(len(a) * 0.95) - 1]
    print(f'{role}: n={len(diffs)} median={st.median(diffs):+.3f}ms p95|d|={p95:.3f}ms max|d|={a[-1]:.3f}ms')
    if p95 > 1.0: ok = False
    if role == 'guest':
        # Must be silent while paused (pause takes effect 200 ms after the command).
        loud = [m for m, f in G if ev['pause'] + 300e6 < m < ev['resume']]
        print(f'  samples playing during pause window: {len(loud)}')
        if loud: ok = False
        # After the seek the guest must be ~40 s in.
        after = [f / 48000 for m, f in G if m > ev['seek'] + 600e6]
        print(f'  first position after seek: {after[0]:.2f}s' if after else '  no samples after seek')
        if not after or not (40 <= after[0] < 41.5): ok = False
        # Across the simulated Wi-Fi drop the guest must keep playing (no gaps).
        ms = [m for m, f in G]
        gaps = [(b - a) / 1e6 for a, b in zip(ms, ms[1:]) if a > ev['seek'] + 600e6 and b - a > 150e6]
        print(f'  playback gaps after seek (incl. reconnect): {[round(g) for g in gaps]} ms')
        if gaps: ok = False
print('E2E', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
