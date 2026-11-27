"""Learn Satie's language from his scores: chord qualities, voicings, harmonic motion, melody habits."""
import sys, os, collections, json
sys.path.insert(0, os.path.dirname(__file__))
from midi_notes import parse

QUAL = {  # intervals above root (pitch classes)
    'maj7': {0,4,7,11}, 'm7': {0,3,7,10}, '7': {0,4,7,10}, 'm7b5': {0,3,6,10}, 'maj': {0,4,7}, 'min': {0,3,7},
    'maj9': {0,4,7,11,2}, 'm9': {0,3,7,10,2}, '9': {0,4,7,10,2}, 'add9': {0,4,7,2}, 'madd9': {0,3,7,2},
    'sus4': {0,5,7}, 'sus2': {0,2,7}, '7sus4': {0,5,7,10}, '6': {0,4,7,9}, 'm6': {0,3,7,9}, 'maj7#11': {0,4,7,11,6},
}
def name_chord(pcs, bass):
    best = None
    for root in range(12):
        rel = {(p - root) % 12 for p in pcs}
        for q, tpl in QUAL.items():
            if rel == tpl:
                score = (len(tpl), root == bass % 12)
                if best is None or score > best[0]: best = (score, root, q)
    if best is None:
        # closest template (most overlap) rooted on the bass
        rel = {(p - bass) % 12 for p in pcs}
        q = max(QUAL, key=lambda k: (len(QUAL[k] & rel) - len(QUAL[k] - rel), -len(QUAL[k])))
        return bass % 12, q + '?'
    return best[1], best[2]

def bars_of(path, beats):
    meta, tr = parse(path)
    notes = [(a, d, n, i) for i, t in enumerate(tr) for a, d, n, v in t]
    end = max(a + d for a, d, n, i in notes)
    out = []
    for b in range(int(end // beats)):
        s, e = b * beats, (b + 1) * beats
        out.append([(a - s, d, n, i) for a, d, n, i in notes if s <= a < e])
    return out

stats = {'qual': collections.Counter(), 'motion': collections.Counter(), 'voicing': collections.defaultdict(collections.Counter),
         'mel_int': collections.Counter(), 'mel_rhythm': collections.Counter(), 'mel_dur': collections.Counter(),
         'hold': collections.Counter(), 'mel_on_chordtone_strong': [0, 0], 'acc_rhythm': collections.Counter()}
for f, beats, kind in [('gymnopedie_1.mid', 3, 'gym'), ('gymnopedie_2.mid', 3, 'gym'), ('gymnopedie_3.mid', 3, 'gym'),
                       ('SatieSarabandes/sarabande_1.mid', 3, 'sara'), ('SatieSarabandes/sarabande_2.mid', 3, 'sara'), ('SatieSarabandes/sarabande_3.mid', 3, 'sara')]:
    bars = bars_of(os.path.join('sources', f), beats)
    prev = None; run = 0; prev_mel = None
    for bar in bars:
        if not bar: continue
        if kind == 'gym':
            acc = [x for x in bar if x[3] == 2 or (x[2] < 71 and sum(1 for y in bar if abs(y[0]-x[0])<1e-3 and y[2] < 71 and y[3]==1) >= 2)]
            mel = [x for x in bar if x not in acc]
        else:
            # Sarabandes: every onset is a chord; the top note of each chord is the melody
            by = collections.defaultdict(list)
            for x in bar: by[round(x[0], 3)].append(x)
            mel = [max(g, key=lambda x: x[2]) for g in by.values() if len(g) >= 2]
            acc = [x for x in bar if x not in mel]
        if not acc: continue
        bass = min(x[2] for x in acc)
        pcs = {x[2] % 12 for x in acc}
        root, q = name_chord(pcs, bass)
        stats['qual'][q] += 1
        upper = sorted({x[2] for x in acc if x[2] != bass})
        stats['voicing'][q][tuple(u - bass for u in upper)] += 1
        stats['acc_rhythm'][(kind, tuple(sorted({round(x[0], 2) for x in acc})))] += 1
        chord = (root, q)
        if prev is not None:
            if chord == prev: run += 1
            else:
                stats['hold'][run + 1] += 1; run = 0
                stats['motion'][((root - prev[0]) % 12, prev[1].rstrip('?'), q.rstrip('?'))] += 1
        prev = chord
        mel = sorted(mel)
        if kind == 'gym' and mel:
            stats['mel_rhythm'][tuple((round(a, 2), round(d, 2)) for a, d, n, i in mel)] += 1
        for a, d, n, i in mel:
            stats['mel_dur'][round(d, 2)] += 1
            if prev_mel is not None and abs(n - prev_mel) <= 12: stats['mel_int'][n - prev_mel] += 1
            prev_mel = n
            if abs(a % 1) < 1e-3 and a < 1e-3:
                rel = (n - root) % 12
                stats['mel_on_chordtone_strong'][0 if rel in QUAL[q.rstrip('?')] else 1] += 1

print('QUALITIES', stats['qual'].most_common(14))
print('HOLD (bars per chord)', sorted(stats['hold'].items())[:10])
print('MOTION (root interval, from, to)', stats['motion'].most_common(20))
for q, c in stats['qual'].most_common(8):
    print('VOICING', q, stats['voicing'][q].most_common(4))
print('ACC RHYTHM', stats['acc_rhythm'].most_common(8))
print('MEL INTERVALS', sorted(stats['mel_int'].items()))
print('MEL DURATIONS', stats['mel_dur'].most_common(8))
print('MEL RHYTHMS (gym)', stats['mel_rhythm'].most_common(10))
print('STRONG BEAT chord tone vs not', stats['mel_on_chordtone_strong'])
