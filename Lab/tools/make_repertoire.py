"""Generate Sources/AcousticCore/Audio/SatieRepertoireData.swift from Lab/sources/**.mid.

The compositions are public domain. The MIDI engravings come from the Mutopia Project
(mutopiaproject.org) under public domain or CC BY-SA licenses (see Lab/sources/README.md);
only the notes are used. Re-run after changing sources:  python3 Lab/tools/make_repertoire.py [out]
"""
import os, sys, base64, struct
sys.path.insert(0, os.path.dirname(__file__))
from midi_notes import parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'Lab', 'sources')
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'Sources', 'AcousticCore', 'Audio', 'SatieRepertoireData.swift')
TPB = 96  # ticks per quarter-note beat

# Collections: 0 Gymnopédies, 1 Gnossiennes, 2 Debussy, 3 Fauré, 4 Scriabin, 5 Sarabandes (Satie).
# split: 'satie' (right-hand chords = accompaniment, single/high notes = melody), 'whole' (as written,
# top voice of the right hand sings), or ('track', n) (track n is the melody, e.g. a voice or flute part).
# breathing: whether the melody may rest for a phrase while the accompaniment continues.
PIECES = [
    # file, collection, title, composer, quarter-note BPM, split, breathing, bars dropped at the end
    ('gymnopedie_1.mid', 0, 'Gymnopédie No. 1', 'Satie', 66, 'satie', True, 1),
    ('gymnopedie_2.mid', 0, 'Gymnopédie No. 2', 'Satie', 66, 'satie', True, 1),
    ('gymnopedie_3.mid', 0, 'Gymnopédie No. 3', 'Satie', 62, 'satie', True, 1),
    ('gnossienne_1.mid', 1, 'Gnossienne No. 1', 'Satie', 56, 'satie', True, 1),
    ('gnossienne_2.mid', 1, 'Gnossienne No. 2', 'Satie', 66, 'satie', True, 1),
    ('gnossienne_3.mid', 1, 'Gnossienne No. 3', 'Satie', 52, 'satie', True, 1),
    ('DebussyC/debussy_Ste_Bergamesq_Clair.mid', 2, 'Clair de lune', 'Debussy', 60, 'whole', False, 2),
    ('DebussyC/debussy_reverie.mid', 2, 'Rêverie', 'Debussy', 68, 'whole', False, 2),
    ('DebussyC/debussy_bruyeres.mid', 2, 'Bruyères', 'Debussy', 58, 'whole', False, 1),
    ('DebussyC/debussy_Arabesque_1.mid', 2, 'Arabesque No. 1', 'Debussy', 72, 'whole', False, 2),
    ('DebussyC/L117-prel-4.mid', 2, 'Les sons et les parfums', 'Debussy', 48, 'whole', False, 2),
    ('FaureG/GF_pavane50.mid', 3, 'Pavane', 'Fauré', 54, ('track', 1), True, 1),
    ('FaureG/apres.mid', 3, 'Après un rêve', 'Fauré', 54, ('track', 1), True, 1),
    ('FaureG/faure_dolly_berceuse.mid', 3, 'Berceuse (Dolly)', 'Fauré', 60, ('track', 1), True, 1),
    ('FaureG/les_roses_d_ispahan.mid', 3, "Les roses d'Ispahan", 'Fauré', 58, ('track', 1), True, 1),
    ('SatieSarabandes/sarabande_1.mid', 5, 'Sarabande No. 1', 'Satie', 54, 'whole', False, 1),
    ('SatieSarabandes/sarabande_2.mid', 5, 'Sarabande No. 2', 'Satie', 54, 'whole', False, 1),
    ('SatieSarabandes/sarabande_3.mid', 5, 'Sarabande No. 3', 'Satie', 52, 'whole', False, 1),
    ('ScriabinA/scriabine-op16-no1.mid', 4, 'Prélude Op. 16 No. 1', 'Scriabin', 46, 'whole', False, 1),
    ('ScriabinA/scriabine-op16-no3.mid', 4, 'Prélude Op. 16 No. 3', 'Scriabin', 56, 'whole', False, 1),
    ('ScriabinA/scriabine-op16-no4.mid', 4, 'Prélude Op. 16 No. 4', 'Scriabin', 38, 'whole', False, 1),
    ('ScriabinA/scriabine-op16-no5.mid', 4, 'Prélude Op. 16 No. 5', 'Scriabin', 50, 'whole', False, 1),
    ('ScriabinA/Scriabin_prelude_op11no1.mid', 4, 'Prélude Op. 11 No. 1', 'Scriabin', 92, 'whole', False, 1),
]
MELODY_FLOOR = 71  # Satie split: right-hand notes from B4 up are melody

def bar_starts(meta, end):
    """Bar start positions (in quarter beats), honoring time-signature changes."""
    sigs = sorted(meta['timesig']) or [(0.0, 4, 4)]
    starts, pos, i = [], 0.0, 0
    while pos < end - 1e-6:
        while i + 1 < len(sigs) and sigs[i + 1][0] <= pos + 1e-6:
            i += 1
        num, den = sigs[i][1], sigs[i][2]
        starts.append(pos)
        pos += num * 4.0 / den
    starts.append(pos)
    return starts

def roles(tracks, split):
    notes = []
    if split == 'satie':
        rh, lh = tracks[1], tracks[2]
        by_onset = {}
        for a, d, n, v in rh:
            by_onset.setdefault(round(a, 3), []).append((a, d, n))
        for group in by_onset.values():
            low = [g for g in group if g[2] < MELODY_FLOOR]
            for a, d, n in group:
                notes.append((a, d, n, 1 if (n >= MELODY_FLOOR or len(low) < 2) else 0))
        for a, d, n, v in lh:
            notes.append((a, d, n, 2 if n < 48 else 0))
    elif split == 'whole':
        rh = tracks[1]
        top = {}
        for a, d, n, v in rh:
            k = round(a, 3)
            top[k] = max(top.get(k, 0), n)
        for t in tracks[1:]:
            for a, d, n, v in t:
                if n < 48: r = 2
                elif t is rh and n == top[round(a, 3)] and n >= 67: r = 1
                else: r = 0
                notes.append((a, d, n, r))
    else:
        mel = split[1]
        for i, t in enumerate(tracks):
            for a, d, n, v in t:
                notes.append((a, d, n, 1 if i == mel else (2 if n < 48 else 0)))
    return sorted(notes)

lines = ['// Generated by Lab/tools/make_repertoire.py from Lab/sources. Do not edit by hand.',
         '// Compositions in the public domain. MIDI engravings: the Mutopia Project (mutopiaproject.org),',
         '// public domain or CC BY-SA (credits in Lab/sources/README.md). Only the notes are used.', '',
         'extension SatieRepertoire {',
         '    // notes: base64 of little-endian Int16 quintuples: bar, start tick, length tick (96 per quarter beat),',
         '    // MIDI note, role (0 accompaniment, 1 melody, 2 bass)',
         '    static let rawPieces: [RawPiece] = [']
summary = []
for f, coll, title, composer, bpm, split, breathing, drop in PIECES:
    meta, tracks = parse(os.path.join(SRC, f))
    notes = roles(tracks, split)
    # Snap onsets to the nearest 1/24 beat (covers 16ths and triplets) and lengths to the nearest 1/8 beat,
    # so a sequencer's tiny timing offsets never reach the music
    notes = sorted((round(a * 24) / 24, max(0.125, round(d * 8) / 8), n, r) for a, d, n, r in notes)
    end = max(a + d for a, d, n, r in notes)
    starts = bar_starts(meta, end)
    keep = len(starts) - 1 - drop
    flat = []
    for a, d, n, r in notes:
        bar = max(0, next(i for i in range(len(starts) - 1) if a < starts[i + 1] - 1e-6) if a < starts[-1] else len(starts) - 2)
        if bar >= keep:
            continue
        flat += [bar, int(round((a - starts[bar]) * TPB)), max(1, int(round(d * TPB))), n, r]
    bar_ticks = [int(round((starts[i + 1] - starts[i]) * TPB)) for i in range(keep)]
    summary.append((title, keep, len(flat) // 5))
    lines.append(f'        RawPiece(title: "{title}", composer: "{composer}", collection: {coll}, bpm: {bpm}, '
                 f'breathing: {"true" if breathing else "false"},')
    lines.append(f'                 barTicks: [{", ".join(str(t) for t in bar_ticks)}],')
    flat = [min(32767, x) for x in flat]
    packed = base64.b64encode(struct.pack('<%dh' % len(flat), *flat)).decode()
    lines.append(f'                 notes: "{packed}"),')
lines += ['    ]', '}', '']
open(OUT, 'w').write('\n'.join(lines))
for t, b, n in summary: print(f'{t:28s} {b:4d} bars {n:5d} notes')
print('wrote', OUT)
